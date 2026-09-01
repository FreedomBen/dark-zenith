defmodule DarkZenithWeb.Api.V1.PackageUploadListingTest do
  @moduledoc """
  `GET /api/v1/repos/:slug/package-uploads` (DESIGN.md: API Contract
  Details; the repository-scoped listing exception under REST API) and the
  initiator-only masking of the id-addressed intent endpoints.
  """
  use DarkZenithWeb.ConnCase, async: true

  import DarkZenith.AccountsFixtures
  import DarkZenith.CollaboratorsFixtures
  import DarkZenith.RepositoriesFixtures
  import Ecto.Query, only: [from: 2]

  alias DarkZenith.Accounts
  alias DarkZenith.Uploads
  alias DarkZenith.Uploads.{Intent, Record, Records}

  @forbidden_fields ~w(upload staging_path staging_version_id lease_token preview_metadata user_id)

  setup %{conn: conn} do
    owner = user_fixture()
    admin = admin_fixture()
    repo = repository_fixture(owner, %{is_public: true})
    private = repository_fixture(owner, %{is_public: false})

    %{
      conn: put_req_header(conn, "content-type", "application/json"),
      owner: owner,
      admin: admin,
      repo: repo,
      private: private
    }
  end

  defp session_token_for(user) do
    {plaintext, _} = Accounts.create_session_token(user)
    plaintext
  end

  defp bearer(conn, token), do: put_req_header(conn, "authorization", "Bearer " <> token)

  defp api_key_for(user, scopes) do
    {:ok, {plaintext, _}} = Accounts.create_api_key(user, %{name: "k", scopes: scopes})
    plaintext
  end

  defp create!(user, repo, attrs \\ %{}) do
    {:ok, intent, _} =
      Uploads.create_intent(
        user,
        repo,
        Map.merge(%{filename: "pkg.rpm", size: 1000, mode: "api"}, attrs)
      )

    intent
  end

  defp list(conn, user, repo, query \\ "") do
    conn
    |> bearer(session_token_for(user))
    |> get("/api/v1/repos/#{repo.slug}/package-uploads#{query}")
  end

  describe "GET /api/v1/repos/:slug/package-uploads" do
    test "lists records in the documented shape and order", ctx do
      first = create!(ctx.owner, ctx.repo, %{filename: "first.rpm", size: 10})
      second = create!(ctx.admin, ctx.repo, %{filename: "second.rpm", size: 20})
      {:ok, _} = Uploads.cancel_intent(ctx.admin, second)

      base = DateTime.utc_now(:second)

      DarkZenith.Repo.update_all(from(r in Record, where: r.intent_id == ^first.id),
        set: [started_at: DateTime.add(base, -120, :second)]
      )

      DarkZenith.Repo.update_all(from(r in Record, where: r.intent_id == ^second.id),
        set: [started_at: DateTime.add(base, -60, :second)]
      )

      conn = list(ctx.conn, ctx.owner, ctx.repo)
      assert %{"data" => [newest, oldest], "pagination" => pagination} = json_response(conn, 200)
      assert pagination == %{"page" => 1, "per_page" => 50, "total" => "2", "total_pages" => "1"}

      assert newest["intent_id"] == second.id
      assert newest["outcome"] == "canceled"
      assert newest["live_status"] == nil
      assert newest["user_email"] == ctx.admin.email
      assert newest["original_filename"] == "second.rpm"
      assert newest["declared_size"] == "20"
      assert newest["final_size"] == nil
      assert newest["nevra"] == nil
      assert newest["error_code"] == nil
      assert newest["error_detail"] == nil
      assert newest["mode"] == "api"
      assert newest["repository_id"] == ctx.repo.id
      assert newest["repository_slug"] == ctx.repo.slug
      assert newest["package_id"] == second.package_id
      assert is_binary(newest["id"])
      assert newest["started_at"] =~ ~r/^\d{4}-\d{2}-\d{2}T/
      assert newest["finished_at"] =~ ~r/^\d{4}-\d{2}-\d{2}T/

      assert oldest["intent_id"] == first.id
      assert oldest["outcome"] == "in_flight"
      assert oldest["live_status"] == "awaiting_upload"
      assert oldest["finished_at"] == nil

      for row <- [newest, oldest], field <- @forbidden_fields do
        refute Map.has_key?(row, field), "#{field} must not appear in a listing row"
      end

      assert Map.keys(newest) |> Enum.sort() ==
               ~w(declared_size error_code error_detail final_size finished_at id intent_id
                  live_status mode nevra original_filename outcome package_id repository_id
                  repository_slug started_at user_email)
    end

    test "a failed row carries the sanitized code and reason", ctx do
      intent = create!(ctx.owner, ctx.repo)

      {:ok, _} =
        DarkZenith.Repo.transact(fn ->
          Uploads.terminalize!(intent, "failed", "validation_failed", "truncated")
          {:ok, :ok}
        end)

      assert %{"data" => [row]} = json_response(list(ctx.conn, ctx.owner, ctx.repo), 200)
      assert row["outcome"] == "failed"
      assert row["error_code"] == "validation_failed"
      assert row["error_detail"] == "truncated"
    end

    test "a stored reason outside the vocabulary is never echoed", ctx do
      intent = create!(ctx.owner, ctx.repo)
      {:ok, _} = Uploads.cancel_intent(ctx.owner, intent)

      DarkZenith.Repo.update_all(from(r in Record, where: r.intent_id == ^intent.id),
        set: [outcome: "failed", error_code: "validation_failed", error_detail: "rpmkeys: BAD"]
      )

      assert %{"data" => [row]} = json_response(list(ctx.conn, ctx.owner, ctx.repo), 200)
      assert row["error_detail"] == nil
      refute Jason.encode!(row) =~ "rpmkeys"
    end

    test "intent_id stays the stored snapshot after the intent is cleaned up", ctx do
      intent = create!(ctx.owner, ctx.repo)
      DarkZenith.Repo.delete_all(from(i in Intent, where: i.id == ^intent.id))

      assert %{"data" => [row]} = json_response(list(ctx.conn, ctx.owner, ctx.repo), 200)
      assert row["intent_id"] == intent.id
      assert row["outcome"] == "in_flight"
      assert row["live_status"] == nil

      # And the id answers 404 from the id-addressed endpoints.
      conn =
        ctx.conn
        |> bearer(session_token_for(ctx.owner))
        |> get(~p"/api/v1/repos/#{ctx.repo.slug}/package-uploads/#{intent.id}")

      assert %{"error" => %{"code" => "not_found"}} = json_response(conn, 404)
    end

    test "a terminal row reads live_status null while its intent is retained", ctx do
      intent = create!(ctx.owner, ctx.repo)
      {:ok, _} = Uploads.cancel_intent(ctx.owner, intent)
      assert DarkZenith.Repo.get(Intent, intent.id)

      assert %{"data" => [row]} = json_response(list(ctx.conn, ctx.owner, ctx.repo), 200)
      assert row["outcome"] == "canceled"
      assert row["live_status"] == nil
    end

    test "filters by an exact outcome subset", ctx do
      live = create!(ctx.owner, ctx.repo)
      done = create!(ctx.owner, ctx.repo)
      {:ok, _} = Uploads.cancel_intent(ctx.owner, done)

      assert %{"data" => [row]} =
               json_response(list(ctx.conn, ctx.owner, ctx.repo, "?outcome=in_flight"), 200)

      assert row["intent_id"] == live.id

      assert %{"data" => rows} =
               json_response(
                 list(ctx.conn, ctx.owner, ctx.repo, "?outcome=canceled,in_flight"),
                 200
               )

      assert length(rows) == 2

      assert %{"data" => [], "pagination" => %{"total" => "0", "total_pages" => "0"}} =
               json_response(list(ctx.conn, ctx.owner, ctx.repo, "?outcome=failed"), 200)
    end

    test "rejects unknown, blank, folded, trimmed, or repeated outcomes", ctx do
      for bad <- [
            "",
            "done",
            "Failed",
            "%20failed",
            "failed,%20canceled",
            "failed,failed",
            "in_flight,",
            ",canceled"
          ] do
        conn = list(ctx.conn, ctx.owner, ctx.repo, "?outcome=#{bad}")

        assert %{"error" => %{"code" => "validation_failed", "details" => %{"outcome" => _}}} =
                 json_response(conn, 422),
               inspect(bad)
      end

      repeated = list(ctx.conn, ctx.owner, ctx.repo, "?outcome=failed&outcome=canceled")
      assert %{"error" => %{"code" => "validation_failed"}} = json_response(repeated, 422)

      unknown = list(ctx.conn, ctx.owner, ctx.repo, "?status=failed")
      assert %{"error" => %{"code" => "validation_failed"}} = json_response(unknown, 422)
    end

    test "paginates with the standard parameters", ctx do
      for _ <- 1..3, do: create!(ctx.owner, ctx.repo)

      assert %{"data" => [_], "pagination" => pagination} =
               json_response(list(ctx.conn, ctx.owner, ctx.repo, "?page=2&per_page=2"), 200)

      assert pagination == %{"page" => 2, "per_page" => 2, "total" => "3", "total_pages" => "2"}

      assert %{"data" => []} =
               json_response(list(ctx.conn, ctx.owner, ctx.repo, "?page=9"), 200)

      assert %{"error" => %{"code" => "validation_failed"}} =
               json_response(list(ctx.conn, ctx.owner, ctx.repo, "?page=0"), 422)
    end

    test "a nonexistent repository is 404", ctx do
      conn =
        ctx.conn
        |> bearer(session_token_for(ctx.owner))
        |> get("/api/v1/repos/no-such-repo/package-uploads")

      assert %{"error" => %{"code" => "not_found"}} = json_response(conn, 404)
    end
  end

  describe "authorization boundary" do
    setup ctx do
      # One upload by the owner and one by an admin in each repository, so
      # a manager's listing shows rows from every initiator.
      for repo <- [ctx.repo, ctx.private] do
        create!(ctx.owner, repo, %{filename: "owner.rpm"})
        create!(ctx.admin, repo, %{filename: "admin.rpm"})
      end

      :ok
    end

    test "anonymous requests get 401 on a public and 404 on a private repository", ctx do
      assert %{"error" => %{"code" => "unauthenticated"}} =
               ctx.conn
               |> get("/api/v1/repos/#{ctx.repo.slug}/package-uploads")
               |> json_response(401)

      assert %{"error" => %{"code" => "not_found"}} =
               ctx.conn
               |> get("/api/v1/repos/#{ctx.private.slug}/package-uploads")
               |> json_response(404)
    end

    test "an unrelated user gets 403 on a public and 404 on a private repository", ctx do
      stranger = user_fixture()

      assert %{"error" => %{"code" => "forbidden"}} =
               json_response(list(ctx.conn, stranger, ctx.repo), 403)

      assert %{"error" => %{"code" => "not_found"}} =
               json_response(list(ctx.conn, stranger, ctx.private), 404)
    end

    test "a collaborator can read the repository but not its upload listing", ctx do
      collaborator = user_fixture()
      collaborator_row_fixture(ctx.private, collaborator)

      assert %{"error" => %{"code" => "forbidden"}} =
               json_response(list(ctx.conn, collaborator, ctx.private), 403)
    end

    test "the non-initiating owner sees the admin's upload with its email", ctx do
      assert %{"data" => rows} = json_response(list(ctx.conn, ctx.owner, ctx.private), 200)
      assert length(rows) == 2

      emails = rows |> Enum.map(& &1["user_email"]) |> Enum.sort()
      assert emails == Enum.sort([ctx.owner.email, ctx.admin.email])

      for row <- rows, field <- @forbidden_fields do
        refute Map.has_key?(row, field)
      end
    end

    test "a non-initiating admin and the initiating user both list every row", ctx do
      other_admin = admin_fixture()

      assert %{"data" => rows} = json_response(list(ctx.conn, other_admin, ctx.private), 200)
      assert length(rows) == 2

      assert %{"data" => rows} = json_response(list(ctx.conn, ctx.admin, ctx.private), 200)
      assert length(rows) == 2
    end

    test "scope follows the verb: repo:read lists, package:upload reads its own intent", ctx do
      [intent] =
        DarkZenith.Repo.all(
          from i in Intent, where: i.user_id == ^ctx.owner.id and i.repository_id == ^ctx.repo.id
        )

      read_key = api_key_for(ctx.owner, ["repo:read"])
      upload_key = api_key_for(ctx.owner, ["package:upload"])

      assert %{"data" => rows} =
               ctx.conn
               |> bearer(read_key)
               |> get("/api/v1/repos/#{ctx.repo.slug}/package-uploads")
               |> json_response(200)

      assert length(rows) == 2

      assert %{"error" => %{"code" => "forbidden"}} =
               ctx.conn
               |> bearer(upload_key)
               |> get("/api/v1/repos/#{ctx.repo.slug}/package-uploads")
               |> json_response(403)

      assert %{"data" => %{"id" => id}} =
               ctx.conn
               |> bearer(upload_key)
               |> get("/api/v1/repos/#{ctx.repo.slug}/package-uploads/#{intent.id}")
               |> json_response(200)

      assert id == intent.id

      assert %{"error" => %{"code" => "forbidden"}} =
               ctx.conn
               |> bearer(read_key)
               |> get("/api/v1/repos/#{ctx.repo.slug}/package-uploads/#{intent.id}")
               |> json_response(403)
    end

    test "the id-addressed endpoints mask another manager's intent as 404", ctx do
      [admins_intent] =
        DarkZenith.Repo.all(
          from i in Intent, where: i.user_id == ^ctx.admin.id and i.repository_id == ^ctx.repo.id
        )

      token = session_token_for(ctx.owner)
      path = "/api/v1/repos/#{ctx.repo.slug}/package-uploads/#{admins_intent.id}"

      assert %{"error" => %{"code" => "not_found"}} =
               ctx.conn |> bearer(token) |> get(path) |> json_response(404)

      assert %{"error" => %{"code" => "not_found"}} =
               ctx.conn |> bearer(token) |> post(path <> "/refresh") |> json_response(404)

      assert %{"error" => %{"code" => "not_found"}} =
               ctx.conn
               |> bearer(token)
               |> post(path <> "/complete", %{"generation" => 1, "version_id" => "4_zv"})
               |> json_response(404)

      assert %{"error" => %{"code" => "not_found"}} =
               ctx.conn |> bearer(token) |> delete(path) |> json_response(404)

      # Nothing changed: the listing still shows it in flight.
      assert DarkZenith.Repo.get!(Intent, admins_intent.id).status == "awaiting_upload"
      assert Records.get_by_intent(admins_intent.id).outcome == "in_flight"
    end
  end
end
