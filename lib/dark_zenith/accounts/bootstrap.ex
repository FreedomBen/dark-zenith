defmodule DarkZenith.Accounts.Bootstrap do
  @moduledoc """
  First-boot admin bootstrap (DESIGN.md: Initial Setup).

  Since `REGISTRATION_ENABLED` defaults to false, the first admin account is
  created from `ADMIN_EMAIL`/`ADMIN_PASSWORD` on first boot, only while zero
  users exist. The creation transaction holds the shared admin-invariant
  advisory lock so a racing bootstrap or recovery promotion cannot create two
  admins.
  """

  require Logger

  alias DarkZenith.Accounts.User
  alias DarkZenith.Repo

  # Shared instance-wide advisory lock for bootstrap, admin-flag mutations,
  # admin user deletion, and recovery promotion (DESIGN.md: User Lifecycle).
  @admin_invariant_lock_key :erlang.crc32("dark_zenith:admin_invariant")

  @doc """
  Acquires the shared admin-invariant transaction-scoped advisory lock. Must be
  called inside a transaction.
  """
  def acquire_admin_invariant_lock! do
    Repo.query!("SELECT pg_advisory_xact_lock($1)", [@admin_invariant_lock_key])
    :ok
  end

  @doc """
  Creates the initial confirmed admin account when no users exist.

  Returns `{:ok, user}`, `{:error, :users_exist}`, or `{:error, changeset}`
  when the credentials fail the regular account validation rules.
  """
  def bootstrap_admin(email, password) do
    Repo.transact(fn ->
      acquire_admin_invariant_lock!()

      if Repo.aggregate(User, :count) == 0 do
        changeset =
          %User{}
          |> User.registration_changeset(%{email: email, password: password})
          |> Ecto.Changeset.put_change(:is_admin, true)
          |> Ecto.Changeset.put_change(:confirmed_at, DateTime.utc_now(:second))

        # Creating a user at an email holds the normalized-email lock
        # (DESIGN.md: User Lifecycle); with zero users no invitations can
        # exist, so there is nothing to convert.
        if changeset.valid? do
          DarkZenith.Accounts.EmailLock.acquire!(Ecto.Changeset.get_field(changeset, :email))
        end

        Repo.insert(changeset)
      else
        {:error, :users_exist}
      end
    end)
  end

  @doc """
  Boot entry point: bootstraps the admin from the given credentials (defaulting
  to the configured `ADMIN_EMAIL`/`ADMIN_PASSWORD`).

  Returns `{:ok, user}`, `:skipped` (no users exist but the credentials are
  absent or invalid — logged as a warning so the operator can restart with
  both variables set), or `:ignored` (users already exist; the variables are
  ignored after the first boot).
  """
  def maybe_bootstrap_admin(credentials \\ nil) do
    credentials = credentials || Application.get_env(:dark_zenith, :bootstrap_admin, [])
    email = credentials[:email]
    password = credentials[:password]

    result =
      if is_binary(email) and is_binary(password) do
        bootstrap_admin(email, password)
      else
        {:error, :missing_credentials}
      end

    case result do
      {:ok, user} ->
        Logger.info("bootstrap: created initial admin account #{user.email}")
        {:ok, user}

      {:error, :users_exist} ->
        :ignored

      {:error, :missing_credentials} ->
        if Repo.aggregate(User, :count) == 0 do
          Logger.warning(
            "bootstrap: no users exist but ADMIN_EMAIL/ADMIN_PASSWORD are not both set; " <>
              "no admin user was created. Restart with both variables set to bootstrap an admin."
          )

          :skipped
        else
          :ignored
        end

      {:error, %Ecto.Changeset{}} ->
        Logger.warning(
          "bootstrap: ADMIN_EMAIL or ADMIN_PASSWORD failed account validation; " <>
            "no admin user was created. Fix the values and restart to bootstrap an admin."
        )

        :skipped
    end
  end

  @doc """
  Supervision child that runs the boot-time bootstrap once. Disabled when the
  `:bootstrap_admin_on_boot` setting is false (tests call the functions
  directly).
  """
  def child_spec(_opts) do
    %{
      id: __MODULE__,
      restart: :temporary,
      start:
        {Task, :start_link,
         [
           fn ->
             if Application.get_env(:dark_zenith, :bootstrap_admin_on_boot, true) do
               maybe_bootstrap_admin()
             end
           end
         ]}
    }
  end
end
