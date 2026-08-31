defmodule DarkZenith.SigningTransitionsConstraintsTest do
  @moduledoc """
  The signing-transitions database checks (DESIGN.md: Signing Transitions):
  `phase_next_attempt_at` is required for scheduled preparing/activating/
  finalizing phases and null elsewhere, and the prepared candidate key
  fields are all-or-none around a replacement's key-swap commit.
  """

  use DarkZenith.DataCase, async: true

  alias DarkZenith.Repo
  alias DarkZenith.SigningTransitions.Transition

  import DarkZenith.AccountsFixtures

  @prepared %{
    prepared_gpg_key_private: "prepared-private-envelope",
    prepared_gpg_key_public: "prepared-public",
    prepared_primary_fingerprint: String.duplicate("A", 40),
    prepared_signing_fingerprint: String.duplicate("B", 40)
  }

  defp insert_transition(attrs) do
    Repo.insert!(
      struct!(
        %Transition{kind: "replace_gpg_key", user_id: user_fixture().id, phase_attempts: 0},
        attrs
      )
    )
  end

  describe "phase_next_attempt_at scheduling check" do
    test "scheduled phases require a next attempt time" do
      for status <- ["preparing", "activating", "finalizing"] do
        attrs = %{status: status, phase_next_attempt_at: nil}

        attrs =
          if status == "preparing", do: Map.merge(attrs, @prepared), else: attrs

        assert_raise Ecto.ConstraintError, ~r/signing_transitions_phase_scheduling/, fn ->
          insert_transition(attrs)
        end
      end
    end

    test "active, failed, and terminal states null the next attempt time" do
      now = DateTime.utc_now(:second)

      for attrs <- [
            %{status: "active"},
            %{status: "failed", resume_status: "active", last_error_code: "internal_error"},
            %{status: "completed", completed_at: now}
          ] do
        assert_raise Ecto.ConstraintError, ~r/signing_transitions/, fn ->
          insert_transition(Map.put(attrs, :phase_next_attempt_at, now))
        end
      end
    end

    test "conforming rows insert cleanly" do
      now = DateTime.utc_now(:second)

      insert_transition(Map.merge(@prepared, %{status: "preparing", phase_next_attempt_at: now}))
      insert_transition(%{status: "active"})
      insert_transition(%{kind: "enable_rpm_signing", status: "active"})
    end
  end

  describe "prepared candidate all-or-none check" do
    test "a pre-swap replacement requires every prepared field" do
      now = DateTime.utc_now(:second)

      # Missing entirely.
      assert_raise Ecto.ConstraintError, ~r/signing_transitions_prepared_candidate/, fn ->
        insert_transition(%{status: "preparing", phase_next_attempt_at: now})
      end

      # Partially present.
      assert_raise Ecto.ConstraintError, ~r/signing_transitions_prepared_candidate/, fn ->
        insert_transition(%{
          status: "preparing",
          phase_next_attempt_at: now,
          prepared_gpg_key_private: "envelope"
        })
      end

      # failed with resume_status preparing keeps the requirement.
      assert_raise Ecto.ConstraintError, ~r/signing_transitions_prepared_candidate/, fn ->
        insert_transition(%{
          status: "failed",
          resume_status: "preparing",
          last_error_code: "signing_unavailable"
        })
      end

      insert_transition(
        Map.merge(@prepared, %{
          status: "failed",
          resume_status: "preparing",
          last_error_code: "signing_unavailable"
        })
      )
    end

    test "every other phase or kind requires all prepared fields null" do
      now = DateTime.utc_now(:second)

      assert_raise Ecto.ConstraintError, ~r/signing_transitions_prepared_candidate/, fn ->
        insert_transition(
          Map.merge(@prepared, %{status: "activating", phase_next_attempt_at: now})
        )
      end

      assert_raise Ecto.ConstraintError, ~r/signing_transitions_prepared_candidate/, fn ->
        insert_transition(%{
          kind: "clear_metadata_signing",
          status: "preparing",
          phase_next_attempt_at: now,
          prepared_gpg_key_public: "public"
        })
      end

      # prepared_expires_at must also be null outside the pre-swap states.
      assert_raise Ecto.ConstraintError, ~r/signing_transitions_prepared_candidate/, fn ->
        insert_transition(%{status: "active", prepared_expires_at: now})
      end

      # It may be null pre-swap (a non-expiring candidate) or set.
      insert_transition(
        Map.merge(@prepared, %{
          status: "preparing",
          phase_next_attempt_at: now,
          prepared_expires_at: DateTime.add(now, 90, :day)
        })
      )
    end
  end
end
