defmodule DarkZenith.Accounts do
  @moduledoc """
  The Accounts context.
  """

  import Ecto.Query, warn: false
  alias DarkZenith.Repo

  alias DarkZenith.Accounts.{ApiKey, SessionToken, User, UserToken, UserNotifier}
  alias DarkZenith.Crypto

  @doc """
  Whether new account registration is open (DESIGN.md: `REGISTRATION_ENABLED`,
  default `false`). While disabled, registration routes return the standard
  HTML 404 response and no registration links are rendered.
  """
  def registration_enabled? do
    Application.get_env(:dark_zenith, :registration_enabled, false)
  end

  ## Database getters

  @doc """
  Gets a user by email.

  ## Examples

      iex> get_user_by_email("foo@example.com")
      %User{}

      iex> get_user_by_email("unknown@example.com")
      nil

  """
  def get_user_by_email(email) when is_binary(email) do
    Repo.get_by(User, email: email)
  end

  @doc """
  Authenticates a user by email and password.

  Returns `{:error, :invalid_credentials}` for an unknown email, a wrong
  password, or an unconfirmed account, without distinguishing between them
  (DESIGN.md: User Lifecycle — unconfirmed users receive the standard
  invalid-credentials response on the web and API login paths alike).
  """
  def authenticate_user(email, password)
      when is_binary(email) and is_binary(password) do
    user = Repo.get_by(User, email: email)

    cond do
      not User.valid_password?(user, password) -> {:error, :invalid_credentials}
      is_nil(user.confirmed_at) -> {:error, :invalid_credentials}
      true -> {:ok, user}
    end
  end

  @doc """
  Gets a single user.

  Raises `Ecto.NoResultsError` if the User does not exist.

  ## Examples

      iex> get_user!(123)
      %User{}

      iex> get_user!(456)
      ** (Ecto.NoResultsError)

  """
  def get_user!(id), do: Repo.get!(User, id)

  ## User registration

  @doc """
  Registers a user.

  ## Examples

      iex> register_user(%{field: value})
      {:ok, %User{}}

      iex> register_user(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def register_user(attrs) do
    %User{}
    |> User.registration_changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking registration changes.
  """
  def change_user_registration(%User{} = user, attrs \\ %{}) do
    User.registration_changeset(user, attrs, hash_password: false, validate_unique: false)
  end

  ## Confirmation

  @doc ~S"""
  Delivers the confirmation email instructions to the given user.

  ## Examples

      iex> deliver_user_confirmation_instructions(user, &url(~p"/users/confirm/#{&1}"))
      {:ok, %{to: ..., body: ...}}

      iex> deliver_user_confirmation_instructions(confirmed_user, &url(~p"/users/confirm/#{&1}"))
      {:error, :already_confirmed}

  """
  def deliver_user_confirmation_instructions(%User{} = user, confirmation_url_fun)
      when is_function(confirmation_url_fun, 1) do
    if user.confirmed_at do
      {:error, :already_confirmed}
    else
      {encoded_token, user_token} = UserToken.build_email_token(user, "confirm")
      Repo.insert!(user_token)
      UserNotifier.deliver_confirmation_instructions(user, confirmation_url_fun.(encoded_token))
    end
  end

  @doc """
  Confirms a user by the given token.

  If the token matches, the user account is marked as confirmed and every
  outstanding token for the user is deleted.
  """
  def confirm_user(token) do
    with {:ok, query} <- UserToken.verify_email_token_query(token, "confirm"),
         %User{} = user <- Repo.one(query),
         {:ok, {user, _expired_tokens}} <-
           user |> User.confirm_changeset() |> update_user_and_delete_all_tokens() do
      {:ok, user}
    else
      _ -> {:error, :invalid_token}
    end
  end

  ## Password reset

  @doc ~S"""
  Delivers the reset password email to the given user.

  ## Examples

      iex> deliver_user_reset_password_instructions(user, &url(~p"/users/reset-password/#{&1}"))
      {:ok, %{to: ..., body: ...}}

  """
  def deliver_user_reset_password_instructions(%User{} = user, reset_password_url_fun)
      when is_function(reset_password_url_fun, 1) do
    {encoded_token, user_token} = UserToken.build_email_token(user, "reset_password")
    Repo.insert!(user_token)
    UserNotifier.deliver_reset_password_instructions(user, reset_password_url_fun.(encoded_token))
  end

  @doc """
  Gets the user by reset password token, while the token is valid.
  """
  def get_user_by_reset_password_token(token) do
    with {:ok, query} <- UserToken.verify_email_token_query(token, "reset_password"),
         %User{} = user <- Repo.one(query) do
      user
    else
      _ -> nil
    end
  end

  @doc """
  Resets the user password.

  Returns a tuple with the updated user and the list of expired tokens; every
  token for the user — web sessions included — is deleted.
  """
  def reset_user_password(user, attrs) do
    user
    |> User.password_changeset(attrs)
    |> update_user_and_delete_all_tokens()
  end

  ## Settings

  @doc """
  Returns an `%Ecto.Changeset{}` for changing the user email.

  See `DarkZenith.Accounts.User.email_changeset/3` for a list of supported options.

  ## Examples

      iex> change_user_email(user)
      %Ecto.Changeset{data: %User{}}

  """
  def change_user_email(user, attrs \\ %{}, opts \\ []) do
    User.email_changeset(user, attrs, opts)
  end

  @doc """
  Emulates that the email will change without actually changing it in the
  database. Requires the user's current password.

  ## Examples

      iex> apply_user_email(user, "valid password", %{email: ...})
      {:ok, %User{}}

      iex> apply_user_email(user, "invalid password", %{email: ...})
      {:error, %Ecto.Changeset{}}

  """
  def apply_user_email(user, password, attrs) do
    user
    |> User.email_changeset(attrs)
    |> User.validate_current_password(password)
    |> Ecto.Changeset.apply_action(:update)
  end

  @doc """
  Updates the user email using the given token.

  If the token matches, the user email is updated and the token is deleted.
  """
  def update_user_email(user, token) do
    context = "change:#{user.email}"

    Repo.transact(fn ->
      with {:ok, query} <- UserToken.verify_change_email_token_query(token, context),
           %UserToken{sent_to: email} <- Repo.one(query),
           {:ok, user} <- Repo.update(User.email_changeset(user, %{email: email})),
           {_count, _result} <-
             Repo.delete_all(from(UserToken, where: [user_id: ^user.id, context: ^context])) do
        {:ok, user}
      else
        _ -> {:error, :transaction_aborted}
      end
    end)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for changing the user password.

  See `DarkZenith.Accounts.User.password_changeset/3` for a list of supported options.

  ## Examples

      iex> change_user_password(user)
      %Ecto.Changeset{data: %User{}}

  """
  def change_user_password(user, attrs \\ %{}, opts \\ []) do
    User.password_changeset(user, attrs, opts)
  end

  @doc """
  Updates the user password. Requires the user's current password.

  Returns a tuple with the updated user, as well as a list of expired tokens.

  ## Examples

      iex> update_user_password(user, "valid password", %{password: ...})
      {:ok, {%User{}, [...]}}

      iex> update_user_password(user, "invalid password", %{password: "too short"})
      {:error, %Ecto.Changeset{}}

  """
  def update_user_password(user, password, attrs) do
    user
    |> User.password_changeset(attrs)
    |> User.validate_current_password(password)
    |> update_user_and_delete_all_tokens()
  end

  ## Session

  @doc """
  Generates a session token.
  """
  def generate_user_session_token(user) do
    {token, user_token} = UserToken.build_session_token(user)
    Repo.insert!(user_token)
    token
  end

  @doc """
  Gets the user with the given signed token.

  If the token is valid `{user, token_inserted_at}` is returned, otherwise `nil` is returned.
  """
  def get_user_by_session_token(token) do
    {:ok, query} = UserToken.verify_session_token_query(token)
    Repo.one(query)
  end

  @doc ~S"""
  Delivers the update email instructions to the given user.

  ## Examples

      iex> deliver_user_update_email_instructions(user, current_email, &url(~p"/users/settings/confirm-email/#{&1}"))
      {:ok, %{to: ..., body: ...}}

  """
  def deliver_user_update_email_instructions(%User{} = user, current_email, update_email_url_fun)
      when is_function(update_email_url_fun, 1) do
    {encoded_token, user_token} = UserToken.build_email_token(user, "change:#{current_email}")

    Repo.insert!(user_token)
    UserNotifier.deliver_update_email_instructions(user, update_email_url_fun.(encoded_token))
  end

  @doc """
  Deletes the signed token with the given context.
  """
  def delete_user_session_token(token) do
    Repo.delete_all(from(UserToken, where: [token: ^token, context: "session"]))
    :ok
  end

  ## API session tokens (dzst_)

  @doc """
  Creates a short-lived API session token for the user (DESIGN.md: Session
  Tokens). Returns `{plaintext, token}`; the plaintext is shown only once.
  """
  def create_session_token(user) do
    {plaintext, token} = SessionToken.build(user)
    {plaintext, Repo.insert!(token)}
  end

  @doc """
  Gets the user owning a valid, unexpired API session token, or nil.
  """
  def get_user_by_api_session_token(plaintext) when is_binary(plaintext) do
    token_hash = Crypto.token_hash(plaintext)
    now = DateTime.utc_now(:second)

    Repo.one(
      from token in SessionToken,
        join: user in assoc(token, :user),
        where: token.token_hash == ^token_hash and token.expires_at > ^now,
        select: user
    )
  end

  @doc """
  Deletes the API session token matching the presented plaintext.
  Returns `:ok` when a token was deleted, `:error` otherwise.
  """
  def delete_session_token(plaintext) when is_binary(plaintext) do
    token_hash = Crypto.token_hash(plaintext)

    case Repo.delete_all(from(t in SessionToken, where: t.token_hash == ^token_hash)) do
      {1, _} -> :ok
      {0, _} -> :error
    end
  end

  @doc """
  Deletes every expired API session token (hourly cleanup job).
  """
  def delete_expired_session_tokens do
    now = DateTime.utc_now(:second)
    Repo.delete_all(from(t in SessionToken, where: t.expires_at <= ^now))
  end

  ## Admin flag management

  @doc """
  Grants or revokes `is_admin` on another user (DESIGN.md: User Lifecycle).

  Runs under the shared admin-invariant advisory lock: the transaction reloads
  the acting user and target, requires the actor still to be a confirmed
  admin, rejects a self-target, and proves that at least one confirmed admin
  remains after the mutation. The change is audited in the same transaction.
  """
  def set_admin_flag(%User{} = actor, target_id, value) when is_boolean(value) do
    Repo.transact(fn ->
      DarkZenith.Accounts.Bootstrap.acquire_admin_invariant_lock!()

      reloaded_actor = Repo.get(User, actor.id)

      cond do
        is_nil(reloaded_actor) or not reloaded_actor.is_admin or
            is_nil(reloaded_actor.confirmed_at) ->
          {:error, :not_admin}

        actor.id == target_id ->
          {:error, :cannot_target_self}

        true ->
          case Repo.get(User, target_id) do
            nil ->
              {:error, :user_not_found}

            %User{} = target ->
              if value == false and not another_confirmed_admin_remains?(target.id) do
                {:error, :last_admin}
              else
                target = target |> Ecto.Changeset.change(is_admin: value) |> Repo.update!()

                DarkZenith.Audit.record!(
                  if(value, do: "admin.grant_admin", else: "admin.revoke_admin"),
                  actor: reloaded_actor,
                  target: {:user, target.id},
                  metadata: %{"email" => target.email}
                )

                {:ok, target}
              end
          end
      end
    end)
  end

  defp another_confirmed_admin_remains?(excluded_user_id) do
    Repo.exists?(
      from u in User,
        where: u.is_admin and not is_nil(u.confirmed_at) and u.id != ^excluded_user_id
    )
  end

  ## API keys (dzak_)

  @doc """
  Creates a scoped API key (DESIGN.md: API Keys).

  Returns `{:ok, {plaintext, api_key}}` — the plaintext is shown only once —
  `{:error, changeset}` for validation failures, or `{:error, :quota_exceeded}`
  when the new row would exceed `MAX_USER_API_KEYS`. The transaction locks the
  user row so concurrent creates and deletes serialize; every stored row counts
  toward the quota, expired rows included, and admins are not exempt.
  """
  def create_api_key(%User{} = user, attrs) do
    changeset = ApiKey.create_changeset(%ApiKey{user_id: user.id}, attrs)

    if changeset.valid? do
      {plaintext, key_hash} = Crypto.generate_token("dzak_")

      changeset =
        changeset
        |> Ecto.Changeset.put_change(:key_hash, key_hash)
        |> Ecto.Changeset.put_change(:key_prefix, String.slice(plaintext, 0, 12))

      Repo.transact(fn ->
        lock_user_row!(user.id)
        count = Repo.aggregate(from(k in ApiKey, where: k.user_id == ^user.id), :count)

        if count + 1 > max_user_api_keys() do
          {:error, :quota_exceeded}
        else
          with {:ok, api_key} <- Repo.insert(changeset) do
            {:ok, {plaintext, api_key}}
          end
        end
      end)
    else
      {:error, %{changeset | action: :insert}}
    end
  end

  @doc """
  Authenticates an API key credential. Expired keys are rejected exactly like
  unknown ones. Returns `{:ok, {user, api_key}}` or `{:error, :invalid}`.
  """
  def fetch_api_key_user(plaintext) when is_binary(plaintext) do
    key_hash = Crypto.token_hash(plaintext)

    result =
      Repo.one(
        from key in ApiKey,
          join: user in assoc(key, :user),
          where: key.key_hash == ^key_hash,
          select: {user, key}
      )

    case result do
      {user, %ApiKey{} = key} ->
        if ApiKey.expired?(key), do: {:error, :invalid}, else: {:ok, {user, key}}

      nil ->
        {:error, :invalid}
    end
  end

  @doc """
  Lists the user's API keys, expired rows included, newest first with id as
  the deterministic tie-breaker (DESIGN.md: API Contract Details ordering).
  """
  def list_api_keys(%User{} = user) do
    Repo.all(
      from key in ApiKey,
        where: key.user_id == ^user.id,
        order_by: [desc: key.inserted_at, asc: key.id]
    )
  end

  @doc """
  Deletes one of the user's API keys by id. Locks the user row so deletion
  serializes with quota-checked creation. Returns `:ok` or `:error` when the
  key does not exist or belongs to another user.
  """
  def delete_api_key(%User{} = user, id) do
    {:ok, result} =
      Repo.transact(fn ->
        lock_user_row!(user.id)

        case Repo.delete_all(from(k in ApiKey, where: k.id == ^id and k.user_id == ^user.id)) do
          {1, _} -> {:ok, :ok}
          {0, _} -> {:ok, :error}
        end
      end)

    result
  end

  @doc """
  Deletes every API key belonging to the user (the password-reset page's
  one-click revoke-all action).
  """
  def revoke_all_api_keys(%User{} = user) do
    {:ok, result} =
      Repo.transact(fn ->
        lock_user_row!(user.id)
        {:ok, Repo.delete_all(from(k in ApiKey, where: k.user_id == ^user.id))}
      end)

    result
  end

  defp max_user_api_keys do
    Application.get_env(:dark_zenith, :max_user_api_keys, 100)
  end

  defp lock_user_row!(user_id) do
    Repo.one!(from(u in User, where: u.id == ^user_id, lock: "FOR UPDATE", select: u.id))
  end

  ## Token helper

  # Used by password change/reset and confirmation. Deletes the user's web
  # session/email tokens and their API session tokens in the same operation
  # (DESIGN.md: Session Tokens — API keys deliberately survive).
  defp update_user_and_delete_all_tokens(changeset) do
    Repo.transact(fn ->
      with {:ok, user} <- Repo.update(changeset) do
        tokens_to_expire = Repo.all_by(UserToken, user_id: user.id)

        Repo.delete_all(from(t in UserToken, where: t.id in ^Enum.map(tokens_to_expire, & &1.id)))
        Repo.delete_all(from(t in SessionToken, where: t.user_id == ^user.id))

        {:ok, {user, tokens_to_expire}}
      end
    end)
  end
end
