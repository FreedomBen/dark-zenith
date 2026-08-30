defmodule DarkZenith.Release do
  @moduledoc """
  Tasks run from the compiled release via `bin/dark_zenith eval`, without Mix
  (DESIGN.md: Initial Setup).
  """

  import Ecto.Query

  alias DarkZenith.Accounts.{Bootstrap, User}
  alias DarkZenith.Audit
  alias DarkZenith.Repo

  @app :dark_zenith

  @doc """
  Recovery promotion for an installation that has users but no administrator:

      bin/dark_zenith eval 'DarkZenith.Release.promote_admin("user@example.com")'

  Normalizes and validates the email, then — under the shared admin-invariant
  advisory lock — rechecks that zero admins exist, requires one existing
  confirmed user at that email, sets only that user's `is_admin` flag, and
  writes a system-authored `admin.recovery_promote` audit event in the same
  transaction. Refuses to act if an admin already exists, the user is missing,
  or the user is unconfirmed; never creates an account or accepts a password.
  """
  def promote_admin(email) when is_binary(email) do
    normalized = email |> String.trim() |> String.downcase()

    if valid_email?(normalized) do
      Repo.transact(fn ->
        Bootstrap.acquire_admin_invariant_lock!()

        admin_count = Repo.aggregate(from(u in User, where: u.is_admin), :count)

        cond do
          admin_count > 0 ->
            {:error, :admin_exists}

          true ->
            case Repo.get_by(User, email: normalized) do
              nil ->
                {:error, :user_not_found}

              %User{confirmed_at: nil} ->
                {:error, :user_unconfirmed}

              %User{} = user ->
                user = user |> Ecto.Changeset.change(is_admin: true) |> Repo.update!()

                Audit.record!("admin.recovery_promote",
                  target: {:user, user.id},
                  metadata: %{"email" => user.email}
                )

                {:ok, user}
            end
        end
      end)
    else
      {:error, :invalid_email}
    end
  end

  @doc "Runs pending migrations (release deployments)."
  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  @doc "Rolls the given repo back to the given migration version."
  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  defp valid_email?(email) do
    String.match?(email, ~r/^[^@,;\s]+@[^@,;\s]+$/) and String.length(email) <= 160
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    Application.load(@app)
  end
end
