defmodule DarkZenith.EndToEnd.CollaboratorInvitationTest do
  @moduledoc """
  The collaborator-invitation lifecycle for a private repository, driven
  only through public surfaces: the owner invites an address that has no
  account yet, the invitee receives the registration-link email, registers
  and confirms through the web UI, the pending invitation converts into a
  collaborator row without a duplicate notice, and the new collaborator
  reads and downloads the package with their own API key and browser
  session. Repeating an invitation is idempotent, and a cancelled
  invitation neither sends mail nor converts when that address registers.
  """

  use DarkZenithWeb.ConnCase, async: true

  import DarkZenith.AccountsFixtures
  import DarkZenith.RpmFixtures, only: [paladin_binary: 0]
  import Phoenix.LiveViewTest

  alias DarkZenith.FakeBucket

  @slug "paladin-invite"
  @name "Paladin (invited)"
  @filename "paladin-0.1.0-1.x86_64.rpm"

  setup do
    unique = System.unique_integer([:positive])

    %{
      bucket: FakeBucket.start!(),
      owner: user_fixture(),
      invitee: "invitee-#{unique}@example.com",
      declined: "declined-#{unique}@example.com",
      binary: paladin_binary()
    }
  end

  defp json(token) do
    conn = put_req_header(build_conn(), "content-type", "application/json")
    if token, do: put_req_header(conn, "authorization", "Bearer " <> token), else: conn
  end

  # What dnf sends for `username=token` / `password=<api-key>`.
  defp dnf(api_key) do
    put_req_header(build_conn(), "authorization", "Basic " <> Base.encode64("token:" <> api_key))
  end

  # Logs in with the fixture password and mints an API key, both through
  # the API.
  defp api_key_for(email, scopes) do
    login =
      post(json(nil), ~p"/api/v1/auth/login", %{
        "email" => email,
        "password" => valid_user_password()
      })

    assert %{"data" => %{"token" => session}} = json_response(login, 200)

    created = post(json(session), ~p"/api/v1/api_keys", %{"name" => "ci", "scopes" => scopes})
    assert %{"data" => %{"key" => "dzak_" <> _ = key}} = json_response(created, 201)
    key
  end

  defp transfer(method, url, opts) do
    {:ok, response} =
      Req.request(
        [method: method, url: url, plug: {Req.Test, DarkZenith.B2Stub}, retry: false] ++ opts
      )

    response
  end

  defp drain!(queue) do
    Oban.drain_queue(queue: queue, with_scheduled: true, with_safety: false)
  end

  # Every email the test-adapter mailer has delivered to this process so far.
  defp delivered_emails(acc \\ []) do
    receive do
      {:email, email} -> delivered_emails([email | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp emails_to(emails, address), do: Enum.filter(emails, &(&1.to == [{"", address}]))

  defp collaborator_rows(owner_key) do
    assert %{"data" => rows} =
             json_response(get(json(owner_key), ~p"/api/v1/repos/#{@slug}/collaborators"), 200)

    rows
  end

  # The owner's upload of the package, through the API and the presigned
  # transfer, processed and published.
  defp upload_paladin!(owner_key, binary) do
    declared =
      post(json(owner_key), ~p"/api/v1/repos/#{@slug}/package-uploads", %{
        "filename" => @filename,
        "size" => Integer.to_string(byte_size(binary))
      })

    assert %{"data" => %{"id" => intent_id}, "upload" => upload} = json_response(declared, 201)

    put = transfer(:put, upload["url"], headers: upload["headers"], body: binary)
    assert put.status == 200
    [staged_version] = put.headers["x-amz-version-id"]

    completed =
      post(json(owner_key), ~p"/api/v1/repos/#{@slug}/package-uploads/#{intent_id}/complete", %{
        "generation" => upload["generation"],
        "version_id" => staged_version
      })

    assert %{"data" => %{"status" => "queued"}} = json_response(completed, 202)
    assert %{success: 1, failure: 0} = drain!(:rpm_processing)
    assert %{success: 1, failure: 0} = drain!(:metadata)

    status = get(json(owner_key), ~p"/api/v1/repos/#{@slug}/package-uploads/#{intent_id}")

    assert %{"data" => %{"status" => "succeeded", "package" => package}} =
             json_response(status, 200)

    package
  end

  # Registration through the web form; the account starts unconfirmed.
  defp register!(email) do
    {:ok, lv, _html} = live(build_conn(), ~p"/users/register")

    {:ok, _lv, html} =
      lv
      |> form("#registration_form",
        user: %{"email" => email, "password" => valid_user_password()}
      )
      |> render_submit()
      |> follow_redirect(build_conn(), ~p"/users/log-in")

    assert html =~ "please access it to confirm your account"
  end

  test "an invited address gains access once it registers and confirms", ctx do
    owner_key = api_key_for(ctx.owner.email, ~w(repo:create repo:read repo:update package:upload))

    created =
      post(json(owner_key), ~p"/api/v1/repos", %{
        "slug" => @slug,
        "name" => @name,
        "is_public" => false
      })

    assert %{"data" => %{"is_public" => false}} = json_response(created, 201)
    package = upload_paladin!(owner_key, ctx.binary)

    # 1. Inviting an address with no account creates a pending invitation.
    invited =
      post(json(owner_key), ~p"/api/v1/repos/#{@slug}/collaborators", %{"email" => ctx.invitee})

    assert %{"data" => invitation} = json_response(invited, 201)
    assert invitation["type"] == "invitation"
    assert invitation["email"] == ctx.invitee
    assert invitation["invited_by_id"] == ctx.owner.id
    assert invitation["notification_status"] == "queued"
    assert invitation["notification_generation"] == "1"
    assert invitation["notification_sent_at"] == nil

    {:ok, expires_at, 0} = DateTime.from_iso8601(invitation["expires_at"])
    assert_in_delta DateTime.diff(expires_at, DateTime.utc_now()), 30 * 86_400, 60

    assert [%{"type" => "invitation", "id" => invitation_id}] = collaborator_rows(owner_key)
    assert invitation_id == invitation["id"]

    # 2. The invitee is emailed a registration link, and the row records it.
    assert %{failure: 0} = drain!(:mailers)
    assert [mail] = emails_to(delivered_emails(), ctx.invitee)
    assert mail.subject == "You've been invited to #{@name}"
    assert mail.text_body =~ "#{DarkZenithWeb.Endpoint.url()}/users/register"

    assert [%{"notification_status" => "sent", "notification_sent_at" => sent_at}] =
             collaborator_rows(owner_key)

    assert is_binary(sent_at)

    # 3. Inviting the same address again returns the existing invitation
    #    and sends nothing.
    again =
      post(json(owner_key), ~p"/api/v1/repos/#{@slug}/collaborators", %{"email" => ctx.invitee})

    assert %{"data" => %{"id" => ^invitation_id, "notification_status" => "sent"}} =
             json_response(again, 200)

    assert %{success: 0, failure: 0} = drain!(:mailers)

    # 4. The invitee registers: the invitation converts into a collaborator
    #    row that keeps the delivered notification, so no second notice
    #    goes out, only the account confirmation.
    register!(ctx.invitee)

    assert [collaborator] = collaborator_rows(owner_key)
    assert collaborator["type"] == "collaborator"
    assert collaborator["email"] == ctx.invitee
    assert is_binary(collaborator["user_id"])
    assert collaborator["notification_status"] == "sent"
    assert collaborator["notification_generation"] == "1"
    assert collaborator["notification_sent_at"] == sent_at

    assert %{failure: 0} = drain!(:mailers)
    assert [confirmation] = emails_to(delivered_emails(), ctx.invitee)
    assert confirmation.subject == "Confirmation instructions"
    [_, token] = Regex.run(~r{/users/confirm/([A-Za-z0-9_-]+)}, confirmation.text_body)

    # 5. Until confirmed, the account cannot log in.
    unconfirmed =
      post(json(nil), ~p"/api/v1/auth/login", %{
        "email" => ctx.invitee,
        "password" => valid_user_password()
      })

    assert %{"error" => %{"code" => "unauthenticated"}} = json_response(unconfirmed, 401)

    {:ok, lv, _html} = live(build_conn(), ~p"/users/confirm/#{token}")

    {:ok, confirmed} =
      lv
      |> form("#confirmation_form")
      |> render_submit()
      |> follow_redirect(build_conn(), ~p"/users/log-in")

    assert Phoenix.Flash.get(confirmed.assigns.flash, :info) =~ "User confirmed successfully"

    # 6. The new collaborator reads and downloads with their own key.
    collaborator_key = api_key_for(ctx.invitee, ~w(repo:read))

    assert %{"data" => %{"slug" => @slug}} =
             json_response(get(json(collaborator_key), ~p"/api/v1/repos/#{@slug}"), 200)

    assert response(get(dnf(collaborator_key), "/repos/#{@slug}/repodata/repomd.xml"), 200) =~
             "<revision>1</revision>"

    primary = get(dnf(collaborator_key), "/repos/#{@slug}/repodata/primary.xml.gz")
    assert :zlib.gunzip(response(primary, 200)) =~ "<name>paladin</name>"

    redirect = get(dnf(collaborator_key), package["download_path"])
    assert redirect.status == 302
    [location] = get_resp_header(redirect, "location")
    assert transfer(:get, location, decode_body: false).body == ctx.binary

    # 7. In the browser, the collaborator sees the repository and its
    #    package but none of the owner's management surface.
    session =
      post(build_conn(), ~p"/users/log-in", %{
        "user" => %{"email" => ctx.invitee, "password" => valid_user_password()}
      })

    assert redirected_to(session) == ~p"/"

    {:ok, page, html} = live(session, ~p"/repos/#{@slug}")
    assert html =~ @name
    assert has_element?(page, "#packages", "paladin")
    refute has_element?(page, "#upload-history")
    refute html =~ "/repos/#{@slug}/settings"

    # 8. A cancelled invitation sends nothing and never converts.
    declined =
      post(json(owner_key), ~p"/api/v1/repos/#{@slug}/collaborators", %{"email" => ctx.declined})

    assert %{"data" => %{"type" => "invitation", "id" => declined_id}} =
             json_response(declined, 201)

    cancelled =
      delete(json(owner_key), ~p"/api/v1/repos/#{@slug}/collaborators/invitations/#{declined_id}")

    assert response(cancelled, 204) == ""
    assert [%{"type" => "collaborator"}] = collaborator_rows(owner_key)

    assert %{failure: 0} = drain!(:mailers)
    assert emails_to(delivered_emails(), ctx.declined) == []

    register!(ctx.declined)
    assert [%{"type" => "collaborator", "email" => invitee}] = collaborator_rows(owner_key)
    assert invitee == ctx.invitee

    assert %{failure: 0} = drain!(:mailers)
    assert [%{subject: "Confirmation instructions"}] = emails_to(delivered_emails(), ctx.declined)
  end
end
