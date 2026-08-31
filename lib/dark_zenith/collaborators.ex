defmodule DarkZenith.Collaborators do
  @moduledoc """
  Repository collaborators and pending invitations (DESIGN.md: Repository
  Collaborators; Collaborator Invitations).

  Adding by email is idempotent: a registered address gets a collaborator row,
  an unregistered one a pending invitation, and existing rows are returned
  instead of duplicated, re-queuing notifications only in the documented
  states. Every transaction that creates or refreshes an invitation holds the
  normalized-email advisory lock so the user-versus-invitation decision stays
  atomic with registration and email changes.
  """

  import Ecto.Changeset
  import Ecto.Query, warn: false

  alias DarkZenith.Accounts
  alias DarkZenith.Accounts.{EmailLock, User}
  alias DarkZenith.Audit
  alias DarkZenith.Authorization
  alias DarkZenith.Collaborators.{Collaborator, Invitation}
  alias DarkZenith.Repo
  alias DarkZenith.Repositories.Repository
  alias DarkZenith.Workers.{CollaboratorMailer, InvitationMailer}

  ## Listing

  @doc """
  Returns collaborator and invitation rows for the repository, sorted by
  normalized email ascending, then type (collaborator before invitation),
  then id ascending. Collaborators have `:user` preloaded; expired
  invitations are included until cleanup or conversion deletes them.
  """
  def list_rows(%Repository{} = repository) do
    collaborators =
      Repo.all(
        from c in Collaborator, where: c.repository_id == ^repository.id, preload: [:user]
      )

    invitations = Repo.all(from i in Invitation, where: i.repository_id == ^repository.id)

    Enum.sort_by(collaborators ++ invitations, fn
      %Collaborator{} = c -> {c.user.email, 0, c.id}
      %Invitation{} = i -> {i.email, 1, i.id}
    end)
  end

  ## Adding

  @doc """
  Adds a collaborator by email to a private repository (owner/admin only).

  Returns `{:ok, :created | :existing, row}` where the row is a
  `%Collaborator{}` or `%Invitation{}`, `{:error, changeset}` for invalid or
  owner-addressed emails, `{:error, :public_repository}` for additions on a
  public repository, `{:error, :quota_exceeded}` past
  `MAX_REPOSITORY_COLLABORATORS`, or `{:error, :forbidden}`.
  """
  def add_collaborator(%User{} = actor, %Repository{} = repository, email_input) do
    with :ok <- authorize(actor, repository),
         :ok <- ensure_private(repository),
         {:ok, email} <- validate_email(email_input) do
      result =
        Repo.transact(fn ->
          EmailLock.acquire!(email)

          owner = Repo.get!(User, repository.user_id)

          cond do
            owner.email == email ->
              {:error, owner_email_changeset(email)}

            user = Repo.get_by(User, email: email) ->
              add_registered(actor, repository, user)

            invitation = Repo.get_by(Invitation, repository_id: repository.id, email: email) ->
              revisit_invitation(actor, repository, invitation)

            true ->
              create_invitation(actor, repository, email)
          end
        end)

      case result do
        {:ok, {status, row}} -> {:ok, status, row}
        {:error, _} = error -> error
      end
    end
  end

  # Registered address: create or idempotently return the collaborator row,
  # re-queuing only a failed direct-link delivery.
  defp add_registered(actor, repository, user) do
    case Repo.get_by(Collaborator, repository_id: repository.id, user_id: user.id) do
      nil ->
        with :ok <- check_quota(repository) do
          collaborator =
            Repo.insert!(%Collaborator{
              repository_id: repository.id,
              user_id: user.id,
              notification_status: "queued",
              notification_generation: 1
            })

          enqueue_collaborator_mail(collaborator)

          Audit.record!("collaborator.add",
            actor: actor,
            target: {:collaborator, collaborator.id},
            metadata: %{"slug" => repository.slug, "email" => user.email}
          )

          {:ok, {:created, collaborator}}
        end

      %Collaborator{notification_status: "failed"} = existing ->
        requeued =
          existing
          |> change(
            notification_status: "queued",
            notification_generation: existing.notification_generation + 1,
            notification_sent_at: nil
          )
          |> Repo.update!()

        enqueue_collaborator_mail(requeued)
        {:ok, {:existing, requeued}}

      %Collaborator{} = existing ->
        {:ok, {:existing, existing}}
    end
  end

  # Existing invitation: expired rows are always refreshed; unexpired ones
  # re-queue only from failed, or from suppressed once registration is
  # enabled.
  defp revisit_invitation(actor, repository, invitation) do
    now = DateTime.utc_now(:second)

    cond do
      Invitation.expired?(invitation, now) ->
        {:ok, {:existing, refresh_invitation(actor, repository, invitation, now)}}

      invitation.notification_status == "failed" ->
        {:ok, {:existing, requeue_invitation(invitation)}}

      invitation.notification_status == "suppressed" and Accounts.registration_enabled?() ->
        {:ok, {:existing, requeue_invitation(invitation)}}

      true ->
        {:ok, {:existing, invitation}}
    end
  end

  defp create_invitation(actor, repository, email) do
    with :ok <- check_quota(repository) do
      deliverable? = Accounts.registration_enabled?()

      invitation =
        Repo.insert!(%Invitation{
          repository_id: repository.id,
          email: email,
          invited_by_id: actor.id,
          expires_at: new_expiry(DateTime.utc_now(:second)),
          notification_status: if(deliverable?, do: "queued", else: "suppressed"),
          notification_generation: if(deliverable?, do: 1, else: 0)
        })

      if deliverable?, do: enqueue_invitation_mail(invitation)

      Audit.record!("invitation.create",
        actor: actor,
        target: {:invitation, invitation.id},
        metadata: %{
          "slug" => repository.slug,
          "email" => email,
          "notification_status" => invitation.notification_status
        }
      )

      {:ok, {:created, invitation}}
    end
  end

  # Expiry refresh always increments the delivery generation and either
  # queues or suppresses the replacement notification.
  defp refresh_invitation(actor, repository, invitation, now) do
    deliverable? = Accounts.registration_enabled?()

    refreshed =
      invitation
      |> change(
        expires_at: new_expiry(now),
        notification_status: if(deliverable?, do: "queued", else: "suppressed"),
        notification_generation: invitation.notification_generation + 1,
        notification_sent_at: nil
      )
      |> Repo.update!()

    if deliverable?, do: enqueue_invitation_mail(refreshed)

    Audit.record!("invitation.expiry_refresh",
      actor: actor,
      target: {:invitation, invitation.id},
      metadata: %{
        "slug" => repository.slug,
        "email" => invitation.email,
        "notification_status" => refreshed.notification_status
      }
    )

    refreshed
  end

  defp requeue_invitation(invitation) do
    requeued =
      invitation
      |> change(
        notification_status: "queued",
        notification_generation: invitation.notification_generation + 1,
        notification_sent_at: nil
      )
      |> Repo.update!()

    enqueue_invitation_mail(requeued)
    requeued
  end

  ## Conversion

  @doc """
  Converts pending invitations addressed to the user's normalized email into
  collaborator rows and deletes the invitation rows (DESIGN.md: Collaborator
  Invitations).

  Must run inside the account-creation or email-change-confirmation
  transaction while the caller holds the normalized-email advisory lock.
  Expired invitations are skipped and deleted; an invitation on a repository
  the user owns, or where the user already holds a collaborator row, is
  deleted without further effect. A `sent` invitation carries its delivery
  state to the collaborator; any other state queues a fresh direct-link
  generation. Conversion is never quota-checked.
  """
  def convert_invitations_for_user(%User{} = user) do
    now = DateTime.utc_now(:second)

    invitations =
      Repo.all(from i in Invitation, where: i.email == ^user.email, preload: [:repository])

    Enum.each(invitations, fn invitation ->
      outcome = convert_one(user, invitation, now)
      Repo.delete!(invitation)

      unless outcome == :expired do
        Audit.record!("invitation.convert",
          actor: user,
          target: {:invitation, invitation.id},
          metadata: %{
            "slug" => invitation.repository.slug,
            "email" => invitation.email,
            "outcome" => to_string(outcome)
          }
        )
      end
    end)

    :ok
  end

  defp convert_one(user, invitation, now) do
    cond do
      Invitation.expired?(invitation, now) ->
        :expired

      invitation.repository.user_id == user.id ->
        :owner

      Repo.get_by(Collaborator,
        repository_id: invitation.repository_id,
        user_id: user.id
      ) ->
        :already_collaborator

      invitation.notification_status == "sent" ->
        Repo.insert!(%Collaborator{
          repository_id: invitation.repository_id,
          user_id: user.id,
          notification_status: "sent",
          notification_generation: invitation.notification_generation,
          notification_sent_at: invitation.notification_sent_at
        })

        :converted

      true ->
        collaborator =
          Repo.insert!(%Collaborator{
            repository_id: invitation.repository_id,
            user_id: user.id,
            notification_status: "queued",
            notification_generation: invitation.notification_generation + 1
          })

        enqueue_collaborator_mail(collaborator)
        :converted
    end
  end

  ## Removal and cancellation

  @doc """
  Removes a collaborator row by id, scoped to the repository (owner/admin
  only; available regardless of repository visibility).
  """
  def remove_collaborator(%User{} = actor, %Repository{} = repository, id) do
    with :ok <- authorize(actor, repository),
         {:ok, uuid} <- cast_uuid(id) do
      {:ok, result} =
        Repo.transact(fn ->
          row =
            Repo.one(
              from c in Collaborator,
                where: c.id == ^uuid and c.repository_id == ^repository.id,
                preload: [:user]
            )

          case row do
            nil ->
              {:ok, {:error, :not_found}}

            collaborator ->
              Repo.delete!(collaborator)

              Audit.record!("collaborator.remove",
                actor: actor,
                target: {:collaborator, collaborator.id},
                metadata: %{"slug" => repository.slug, "email" => collaborator.user.email}
              )

              {:ok, :ok}
          end
        end)

      result
    end
  end

  @doc """
  Cancels a pending invitation by id, scoped to the repository (owner/admin
  only; available regardless of repository visibility). Deleting the row
  fences any stale mail job.
  """
  def cancel_invitation(%User{} = actor, %Repository{} = repository, id) do
    with :ok <- authorize(actor, repository),
         {:ok, uuid} <- cast_uuid(id) do
      {:ok, result} =
        Repo.transact(fn ->
          row =
            Repo.one(
              from i in Invitation,
                where: i.id == ^uuid and i.repository_id == ^repository.id
            )

          case row do
            nil ->
              {:ok, {:error, :not_found}}

            invitation ->
              Repo.delete!(invitation)

              Audit.record!("invitation.cancel",
                actor: actor,
                target: {:invitation, invitation.id},
                metadata: %{"slug" => repository.slug, "email" => invitation.email}
              )

              {:ok, :ok}
          end
        end)

      result
    end
  end

  ## Cleanup

  @doc """
  Deletes expired invitation rows (hourly cleanup job). Invitations without
  an expiry are never deleted.
  """
  def delete_expired_invitations do
    now = DateTime.utc_now(:second)

    Repo.delete_all(
      from i in Invitation, where: not is_nil(i.expires_at) and i.expires_at <= ^now
    )
  end

  ## Helpers

  defp authorize(actor, repository) do
    if Authorization.can_manage?(actor, repository), do: :ok, else: {:error, :forbidden}
  end

  defp ensure_private(%Repository{is_public: true}), do: {:error, :public_repository}
  defp ensure_private(%Repository{}), do: :ok

  # New collaborator or invitation rows are quota-checked under the locked
  # repository row so concurrent adds serialize; idempotent returns, expiry
  # refreshes, removals, cancellations, and conversion are exempt.
  defp check_quota(%Repository{id: repository_id}) do
    Repo.one!(
      from(r in Repository, where: r.id == ^repository_id, lock: "FOR UPDATE", select: r.id)
    )

    max = max_repository_collaborators()

    if max > 0 do
      collaborators =
        Repo.aggregate(from(c in Collaborator, where: c.repository_id == ^repository_id), :count)

      invitations =
        Repo.aggregate(from(i in Invitation, where: i.repository_id == ^repository_id), :count)

      if collaborators + invitations + 1 > max, do: {:error, :quota_exceeded}, else: :ok
    else
      :ok
    end
  end

  defp new_expiry(now) do
    case invitation_expiry_days() do
      0 -> nil
      days -> DateTime.add(now, days, :day)
    end
  end

  defp enqueue_collaborator_mail(%Collaborator{} = collaborator) do
    %{
      collaborator_id: collaborator.id,
      notification_generation: collaborator.notification_generation
    }
    |> CollaboratorMailer.new()
    |> Oban.insert!()
  end

  defp enqueue_invitation_mail(%Invitation{} = invitation) do
    %{invitation_id: invitation.id, notification_generation: invitation.notification_generation}
    |> InvitationMailer.new()
    |> Oban.insert!()
  end

  # Same normalization and validation rules as `phx.gen.auth` account emails
  # (DESIGN.md: API Contract Details).
  defp validate_email(input) do
    changeset =
      {%{}, %{email: :string}}
      |> cast(%{email: input}, [:email])
      |> update_change(:email, &(&1 |> String.trim() |> String.downcase()))
      |> validate_required([:email])
      |> validate_format(:email, ~r/^[^@,;\s]+@[^@,;\s]+$/,
        message: "must have the @ sign and no spaces"
      )
      |> validate_length(:email, max: 160)

    if changeset.valid? do
      {:ok, get_change(changeset, :email)}
    else
      {:error, %{changeset | action: :validate}}
    end
  end

  defp owner_email_changeset(email) do
    {%{}, %{email: :string}}
    |> cast(%{email: email}, [:email])
    |> add_error(:email, "cannot invite the repository owner")
    |> Map.put(:action, :validate)
  end

  defp cast_uuid(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :not_found}
    end
  end

  defp max_repository_collaborators do
    Application.get_env(:dark_zenith, :max_repository_collaborators, 1000)
  end

  defp invitation_expiry_days do
    Application.get_env(:dark_zenith, :invitation_expiry_days, 30)
  end
end
