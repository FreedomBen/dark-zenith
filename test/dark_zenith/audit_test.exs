defmodule DarkZenith.AuditTest do
  use DarkZenith.DataCase, async: true

  import DarkZenith.AccountsFixtures

  alias DarkZenith.Audit
  alias DarkZenith.Audit.Event

  describe "record!/2" do
    test "records an actor event with an email snapshot" do
      user = user_fixture()

      event =
        Audit.record!("auth.login", actor: user, target: {:user, user.id}, ip: "203.0.113.9")

      assert event.actor_id == user.id
      assert event.actor_email == user.email
      assert event.action == "auth.login"
      assert event.target_type == "user"
      assert event.target_id == user.id
      assert event.ip == "203.0.113.9"
      assert event.metadata == %{}
      assert event.inserted_at
    end

    test "records a system event without actor or ip" do
      event = Audit.record!("admin.recovery_promote", target: {:user, Ecto.UUID.generate()})

      assert event.actor_id == nil
      assert event.actor_email == nil
      assert event.ip == nil
    end

    test "defaults ip from the process-scoped audit context" do
      Audit.put_client_ip("198.51.100.7")

      event = Audit.record!("auth.login", actor: user_fixture())
      assert event.ip == "198.51.100.7"

      # An explicit ip always wins over the context.
      explicit = Audit.record!("auth.login", actor: user_fixture(), ip: "203.0.113.9")
      assert explicit.ip == "203.0.113.9"

      # An explicit nil records a system event even with context set.
      system = Audit.record!("package.upload", ip: nil)
      assert system.ip == nil
    end

    test "records slug targets with a nil target_id and the slug in metadata" do
      event =
        Audit.record!("admin.slug_release",
          actor: user_fixture(),
          target: :slug,
          metadata: %{"slug" => "stable"}
        )

      assert event.target_type == "slug"
      assert event.target_id == nil
      assert event.metadata == %{"slug" => "stable"}
    end

    test "records events without a target" do
      event = Audit.record!("auth.login_failed", ip: "203.0.113.9", metadata: %{"email" => "x@y"})

      assert event.target_type == nil
      assert event.target_id == nil
    end

    test "rejects unknown target types" do
      assert_raise Ecto.ConstraintError, ~r/audit_events_target_type/, fn ->
        Audit.record!("weird.event", target: {:starship, Ecto.UUID.generate()})
      end
    end

    test "rejects a slug target carrying a target_id" do
      assert_raise Ecto.ConstraintError, ~r/audit_events_slug_target_id_null/, fn ->
        Audit.record!("admin.slug_release", target: {:slug, Ecto.UUID.generate()})
      end
    end
  end

  describe "actor account deletion" do
    test "clears actor_id via ON DELETE SET NULL while keeping the email snapshot" do
      user = user_fixture()
      event = Audit.record!("repository.create", actor: user, target: {:user, user.id})

      Repo.delete!(user)

      reloaded = Repo.get!(Event, event.id)
      assert reloaded.actor_id == nil
      assert reloaded.actor_email == user.email
    end
  end

  describe "list_events/1" do
    test "returns events newest first" do
      user = user_fixture()
      _first = Audit.record!("auth.login", actor: user)
      second = Audit.record!("auth.logout", actor: user)

      assert [%Event{id: id} | _] = Audit.list_events(limit: 10)
      assert id == second.id
    end
  end
end
