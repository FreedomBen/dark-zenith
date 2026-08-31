defmodule DarkZenith.BootCheckTest do
  # Not async: one test overrides the rpmkeys path globally.
  use DarkZenith.DataCase, async: false

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
    previous = Application.get_env(:dark_zenith, :rpmkeys_path)
    Application.put_env(:dark_zenith, :rpmkeys_path, "/nonexistent/rpmkeys")

    on_exit(fn ->
      if previous do
        Application.put_env(:dark_zenith, :rpmkeys_path, previous)
      else
        Application.delete_env(:dark_zenith, :rpmkeys_path)
      end
    end)

    assert {:error, _} = BootCheck.check_rpmkeys_version()
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
