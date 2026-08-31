defmodule DarkZenith.Workers.GpgExpiryScan do
  @moduledoc """
  Daily scan queuing GPG expiry reminder mail at the 30-, 7-, and 1-day
  thresholds (DESIGN.md: GPG Signing). Jobs are unique by
  `(user_id, fingerprint, threshold)` and each threshold is delivered once
  per key, tracked in `gpg_key_expiry_notified_days` and reset on
  replacement.
  """

  use Oban.Worker, queue: :mailers, max_attempts: 3

  import Ecto.Query

  alias DarkZenith.Accounts.User
  alias DarkZenith.Repo

  @thresholds [30, 7, 1]

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    now = DateTime.utc_now()

    users =
      Repo.all(
        from u in User,
          where: not is_nil(u.gpg_key_expires_at) and u.gpg_key_expires_at > ^now,
          select: %{
            id: u.id,
            fingerprint: u.gpg_key_fingerprint,
            expires_at: u.gpg_key_expires_at,
            notified: u.gpg_key_expiry_notified_days
          }
      )

    for user <- users,
        threshold <- @thresholds,
        DateTime.diff(user.expires_at, now, :day) <= threshold,
        threshold not in user.notified do
      %{user_id: user.id, fingerprint: user.fingerprint, threshold: threshold}
      |> DarkZenith.Workers.GpgExpiryMail.new()
      |> Oban.insert!()
    end

    :ok
  end
end

defmodule DarkZenith.Workers.GpgExpiryMail do
  @moduledoc """
  Delivers one GPG expiry reminder threshold, re-checking the current
  fingerprint, expiry, and notified set before sending; provider success
  records the threshold in `gpg_key_expiry_notified_days`.
  """

  use Oban.Worker,
    queue: :mailers,
    max_attempts: 20,
    unique: [period: :infinity, keys: [:user_id, :fingerprint, :threshold]]

  import Ecto.Query

  alias DarkZenith.Accounts.User
  alias DarkZenith.Mail
  alias DarkZenith.Repo
  alias DarkZenith.Workers.RetryPolicy

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    %{"user_id" => user_id, "fingerprint" => fingerprint, "threshold" => threshold} = args
    now = DateTime.utc_now()
    user = Repo.get(User, user_id)

    cond do
      is_nil(user) or user.gpg_key_fingerprint != fingerprint ->
        # The key was replaced or removed; this reminder is stale.
        :ok

      is_nil(user.gpg_key_expires_at) or threshold in user.gpg_key_expiry_notified_days ->
        :ok

      DateTime.diff(user.gpg_key_expires_at, now, :day) > threshold ->
        :ok

      true ->
        deliver(user, fingerprint, threshold)
    end
  end

  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}), do: RetryPolicy.backoff(attempt)

  defp deliver(user, fingerprint, threshold) do
    email =
      Mail.build(user.email, "Your GPG signing key expires soon", """

      ==============================

      Hi #{user.email},

      Your GPG signing key #{fingerprint} expires on
      #{Calendar.strftime(user.gpg_key_expires_at, "%Y-%m-%d")} — within #{threshold} days.

      Upload a replacement key before then, or signing for your
      repositories will fail closed.

      ==============================
      """)

    case DarkZenith.Mailer.deliver(email) do
      {:ok, _} ->
        {_count, _} =
          Repo.update_all(
            from(u in User,
              where:
                u.id == ^user.id and u.gpg_key_fingerprint == ^fingerprint and
                  not fragment(
                    "? @> to_jsonb(?::int)",
                    u.gpg_key_expiry_notified_days,
                    ^threshold
                  ),
              update: [
                set: [
                  gpg_key_expiry_notified_days:
                    fragment(
                      "? || to_jsonb(?::int)",
                      u.gpg_key_expiry_notified_days,
                      ^threshold
                    )
                ]
              ]
            ),
            []
          )

        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end
end
