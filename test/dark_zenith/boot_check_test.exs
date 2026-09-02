defmodule DarkZenith.BootCheckTest do
  # Not async: one test overrides the rpmkeys path globally.
  use DarkZenith.DataCase, async: false

  import ExUnit.CaptureLog

  alias DarkZenith.BootCheck

  test "the full boot check passes on this toolchain" do
    assert :ok = BootCheck.run()
  end

  test "the rpmkeys version gate requires RPM 6" do
    assert :ok = BootCheck.check_rpmkeys_version()
  end

  test "fixture verification detects unusable tool combinations" do
    assert :ok = BootCheck.check_fixture_verification()
  end

  test "the EVR differential agrees with the RPM tooling" do
    assert :ok = BootCheck.check_evr_comparator()
  end

  test "a missing rpmkeys binary is reported" do
    override_env(:rpmkeys_path, "/nonexistent/rpmkeys")
    assert {:error, _} = BootCheck.check_rpmkeys_version()
  end

  test "an unwritable RPM_UPLOAD_TMPDIR fails fixture verification with a reason" do
    # A regular file where the directory should be: mkdir fails with ENOTDIR
    # regardless of the test user's privileges.
    blocker =
      Path.join(System.tmp_dir!(), "dz-bootcheck-blocker-#{System.unique_integer([:positive])}")

    File.write!(blocker, "")
    on_exit(fn -> File.rm(blocker) end)
    override_env(:rpm_upload_tmpdir, blocker)

    assert {:error, reason} = BootCheck.check_fixture_verification()
    assert reason =~ blocker
    assert reason =~ "not a directory"
  end

  describe "the boot child" do
    test "refuses to start when a required check fails" do
      override_env(:boot_checks_on_boot, true)
      override_env(:rpmkeys_path, "/nonexistent/rpmkeys")

      log =
        capture_log(fn ->
          assert {:error, {:boot_checks_failed, failures}} = BootCheck.start_link()
          assert Enum.any?(failures, &match?({"rpmkeys version", _}, &1))
        end)

      assert log =~ "boot check failed: rpmkeys version"
    end

    test "leaves no process behind when the checks pass" do
      override_env(:boot_checks_on_boot, true)
      capture_log(fn -> assert :ignore = BootCheck.start_link() end)
    end

    test "is a no-op when boot checks are disabled" do
      override_env(:boot_checks_on_boot, false)
      assert :ignore = BootCheck.start_link()
    end
  end

  # Overrides one application setting for the test, restoring it afterwards.
  defp override_env(key, value) do
    previous = Application.fetch_env(:dark_zenith, key)
    Application.put_env(:dark_zenith, key, value)

    on_exit(fn ->
      case previous do
        {:ok, prior} -> Application.put_env(:dark_zenith, key, prior)
        :error -> Application.delete_env(:dark_zenith, key)
      end
    end)
  end
end

defmodule DarkZenithWeb.HealthControllerTest do
  use DarkZenithWeb.ConnCase, async: true

  test "GET and HEAD /health return plain ok with no session work", %{conn: conn} do
    response = get(conn, "/health")
    assert response.status == 200
    assert response.resp_body == "ok"
    assert get_resp_header(response, "content-type") |> hd() =~ "text/plain"
    # No rate-limit headers: the probe bypasses the limiter.
    assert get_resp_header(response, "x-ratelimit-limit") == []

    head_response = head(build_conn(), "/health")
    assert head_response.status == 200
  end
end
