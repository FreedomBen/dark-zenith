defmodule DarkZenith.Repo.Migrations.AddSigningTransitionsPhaseAndCandidateChecks do
  use Ecto.Migration

  def change do
    # Scheduled preparing/activating/finalizing phases carry a next-attempt
    # time; active item work, failure, and terminal states null it
    # (DESIGN.md: Signing Transitions database checks).
    create constraint(:signing_transitions, :signing_transitions_phase_scheduling,
             check: """
             CASE
               WHEN status IN ('preparing', 'activating', 'finalizing') THEN
                 phase_next_attempt_at IS NOT NULL
               ELSE phase_next_attempt_at IS NULL
             END
             """
           )

    # All-or-none prepared candidate key material: required before a
    # replacement's key-swap commit (preparing, or failed with
    # resume_status = 'preparing'), all null in every other phase/kind.
    # prepared_expires_at may be null pre-swap (a non-expiring candidate)
    # but must be null outside those states.
    create constraint(:signing_transitions, :signing_transitions_prepared_candidate,
             check: """
             CASE
               WHEN kind = 'replace_gpg_key' AND
                    (status = 'preparing' OR
                     (status = 'failed' AND resume_status = 'preparing')) THEN
                 prepared_gpg_key_private IS NOT NULL AND
                 prepared_gpg_key_public IS NOT NULL AND
                 prepared_primary_fingerprint IS NOT NULL AND
                 prepared_signing_fingerprint IS NOT NULL
               ELSE
                 prepared_gpg_key_private IS NULL AND
                 prepared_gpg_key_public IS NULL AND
                 prepared_primary_fingerprint IS NULL AND
                 prepared_signing_fingerprint IS NULL AND
                 prepared_expires_at IS NULL
             END
             """
           )
  end
end
