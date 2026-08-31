defmodule DarkZenithWeb.Api.V1.CollaboratorQuotaApiTest do
  # Not async: temporarily lowers the global max_repository_collaborators
  # setting to exercise the 409 mapping.
  use DarkZenithWeb.ConnCase, async: false

  import DarkZenith.AccountsFixtures
  import DarkZenith.CollaboratorsFixtures
  import DarkZenith.RepositoriesFixtures

  alias DarkZenith.Accounts
  alias DarkZenith.Collaborators

  test "an addition past the limit returns 409 conflict_collaborator_quota_exceeded", %{
    conn: conn
  } do
    previous = Application.get_env(:dark_zenith, :max_repository_collaborators)
    Application.put_env(:dark_zenith, :max_repository_collaborators, 1)
    on_exit(fn -> Application.put_env(:dark_zenith, :max_repository_collaborators, previous) end)

    owner = user_fixture()
    repo = repository_fixture(owner, %{is_public: false})
    {:ok, :created, _} = Collaborators.add_collaborator(owner, repo, unique_invited_email())

    {plaintext, _} = Accounts.create_session_token(owner)

    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer " <> plaintext)
      |> post(~p"/api/v1/repos/#{repo.slug}/collaborators", %{"email" => unique_invited_email()})

    assert %{"error" => %{"code" => "conflict_collaborator_quota_exceeded"}} =
             json_response(conn, 409)
  end
end
