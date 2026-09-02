defmodule DarkZenith.EndToEnd.LiveInstallCheckTest do
  @moduledoc """
  `deploy/live_install_check.sh`, the host-side check for a running
  instance, run against this application served over real HTTP by
  `DarkZenith.LiveListeners`: it logs in, creates a repository per flow
  through the REST API, uploads the fixture package through the presigned
  PUT, waits for processing and metadata, runs `deploy/dnf_client_check.sh`
  in a fresh Fedora container against each, and deletes what it created.

  Oban executes nothing on its own in test, so a task drains every queue
  while the script waits on the pipeline, the way the workers would run it.
  """

  # Not async: see `DarkZenith.LiveListeners`.
  use DarkZenith.DataCase, async: false

  import DarkZenith.AccountsFixtures

  alias DarkZenith.Accounts
  alias DarkZenith.Accounts.ApiKey
  alias DarkZenith.LiveListeners
  alias DarkZenith.Repositories

  @moduletag :container
  @moduletag timeout: :timer.minutes(5)

  @script Path.expand("../../deploy/live_install_check.sh", __DIR__)

  setup do
    LiveListeners.start!()
    %{owner: user_fixture()}
  end

  test "provisions, installs from, and removes public and private repositories", ctx do
    {output, status} = run_check(ctx.owner, ~w(public private))
    assert status == 0, output

    assert output =~ "==> log in as #{ctx.owner.email}\n"
    assert output =~ "==> create a repo:read API key for the private flow's client\n"
    assert output =~ "==> public: anonymous repomd.xml is 200\n"
    assert output =~ "==> private: anonymous repomd.xml is 401\n"
    assert output =~ "+ curl --fail --user token:<redacted> "
    assert output =~ "live install check passed: public private against #{base_url()}\n"

    # One container per flow installed and ran the package.
    assert length(Regex.scan(~r/^dnf_client_check: ok$/m, output)) == 2

    assert_cleaned_up(output)
  end

  @tag :rpmsign
  test "generates the account's first GPG key and verifies the signed flow", ctx do
    {output, status} = run_check(ctx.owner, ~w(signed))
    assert status == 0, output

    assert output =~ "==> generating the account's GPG key (ed25519)\n"
    assert output =~ "==> signed: the served .repo file turns verification on\n"
    assert output =~ "The key was successfully imported.\n"
    refute output =~ "skipped OpenPGP checks"
    assert output =~ "live install check passed: signed against #{base_url()}\n"

    # The generated key stays on the account, and it is what dnf imported.
    %{gpg_key_fingerprint: fingerprint} = Accounts.get_user!(ctx.owner.id)
    assert fingerprint =~ ~r/^[0-9A-F]{40}$/
    assert output =~ " Fingerprint: #{fingerprint}\n"

    assert_cleaned_up(output)
  end

  defp base_url, do: DarkZenithWeb.Endpoint.url()

  defp run_check(owner, flows) do
    draining(fn ->
      System.cmd(@script, [base_url() | flows],
        env: [{"DZ_CHECK_EMAIL", owner.email}, {"DZ_CHECK_PASSWORD", valid_user_password()}],
        stderr_to_stdout: true
      )
    end)
  end

  # Every repository the script announced is gone, and so is the client key.
  defp assert_cleaned_up(output) do
    slugs =
      for [_, slug] <- Regex.scan(~r/^==> \w+: create repository (\S+)$/m, output), do: slug

    assert slugs != []

    for slug <- slugs do
      assert output =~ "==> delete repository #{slug}\n"
      assert Repositories.get_repository_by_slug(slug) == nil
    end

    assert Repo.aggregate(ApiKey, :count) == 0
  end

  ## Queue draining

  # Runs `fun` while a task drains every Oban queue the way the workers
  # would, repeatedly, so the script's waits on processing and metadata end.
  defp draining(fun) do
    drainer = Task.async(&drain_loop/0)

    try do
      fun.()
    after
      send(drainer.pid, :stop)
      Task.await(drainer, :timer.minutes(1))
    end
  end

  defp drain_loop do
    receive do
      :stop -> :ok
    after
      250 ->
        for queue <- queues() do
          Oban.drain_queue(queue: queue, with_scheduled: true, with_safety: false)
        end

        drain_loop()
    end
  end

  defp queues do
    :dark_zenith |> Application.fetch_env!(Oban) |> Keyword.fetch!(:queues) |> Keyword.keys()
  end
end
