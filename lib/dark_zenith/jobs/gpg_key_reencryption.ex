defmodule DarkZenith.Jobs.GpgKeyReencryption do
  @moduledoc """
  `SECRET_KEY_BASE` rotation scan (DESIGN.md: GPG private key encryption).

  Enqueued at each boot while `PREVIOUS_SECRET_KEY_BASE` is configured: it
  paginates stored `gpg_key_private` envelopes (transition prepared
  candidates join with the transition machinery), enqueuing one
  re-encryption job per ciphertext. Each per-row job snapshots the
  ciphertext, classifies it — a `v2` envelope decrypting with the current
  base is a successful no-op; anything else that decrypts is rewritten as
  `v2` under the current base — and applies a compare-and-swap on
  `(user_id, gpg_key_private)`, so a concurrently replaced or removed key
  is a successful no-op rather than restored stale material.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 3,
    unique: [period: :infinity, states: [:available, :scheduled, :executing]]

  import Ecto.Query

  alias DarkZenith.Accounts.User
  alias DarkZenith.Repo

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    user_ids =
      Repo.all(from u in User, where: not is_nil(u.gpg_key_private), select: u.id)

    for user_id <- user_ids do
      %{user_id: user_id}
      |> DarkZenith.Jobs.GpgKeyReencryptionRow.new()
      |> Oban.insert!()
    end

    :ok
  end

  @doc "Boot child: enqueues the scan while the previous base is configured."
  def child_spec(_opts) do
    %{
      id: __MODULE__,
      restart: :temporary,
      start:
        {Task, :start_link,
         [
           fn ->
             if Application.get_env(:dark_zenith, :previous_secret_key_base) do
               Oban.insert!(new(%{}))
             end
           end
         ]}
    }
  end
end

defmodule DarkZenith.Jobs.GpgKeyReencryptionRow do
  @moduledoc "Re-encrypts one user's GPG private-key envelope (see the scan)."

  use Oban.Worker,
    queue: :default,
    max_attempts: 20,
    unique: [period: :infinity, keys: [:user_id]]

  import Ecto.Query

  alias DarkZenith.Accounts.User
  alias DarkZenith.Crypto.GpgKeyEnvelope
  alias DarkZenith.Repo
  alias DarkZenith.Workers.RetryPolicy

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"user_id" => user_id}}) do
    case Repo.one(from u in User, where: u.id == ^user_id, select: u.gpg_key_private) do
      nil ->
        :ok

      nil_envelope when is_nil(nil_envelope) ->
        :ok

      <<2, _rest::binary>> = envelope ->
        current = Application.fetch_env!(:dark_zenith, :secret_key_base)

        case GpgKeyEnvelope.decrypt_with_secret(envelope, user_id, current) do
          {:ok, _plaintext} -> :ok
          _needs_rewrite -> rewrite(user_id, envelope)
        end

      envelope when is_binary(envelope) ->
        rewrite(user_id, envelope)
    end
  end

  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}), do: RetryPolicy.backoff(attempt)

  defp rewrite(user_id, envelope) do
    case GpgKeyEnvelope.decrypt(envelope, user_id) do
      {:ok, plaintext} ->
        rewritten = GpgKeyEnvelope.encrypt(plaintext, user_id)

        {_count, _} =
          Repo.update_all(
            from(u in User, where: u.id == ^user_id and u.gpg_key_private == ^envelope),
            set: [gpg_key_private: rewritten]
          )

        # Zero rows means the key moved or was removed concurrently: a
        # successful no-op.
        :ok

      {:error, _reason} ->
        # Undecryptable with either base: stranded material requiring admin
        # intervention; retries will not help.
        {:cancel, :undecryptable_envelope}
    end
  end
end
