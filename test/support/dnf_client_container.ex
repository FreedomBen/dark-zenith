defmodule DarkZenith.DnfClientContainer do
  @moduledoc """
  Runs `deploy/dnf_client_check.sh` — a real dnf5 adding a repository from
  its `dark-zenith.repo` link and installing a package from it — in a
  throwaway Fedora container with podman, for the `:container`-tagged
  end-to-end tests.

  The container uses host networking: under podman's default network a
  container cannot reach the host's own addresses, and both the `.repo`
  file's baseurl and the presigned download URLs carry them. The script is
  handed to bash as an argument rather than bind-mounted, so nothing in the
  working tree needs an SELinux relabel.
  """

  @image "registry.fedoraproject.org/fedora:44"
  @script Path.expand("../../deploy/dnf_client_check.sh", __DIR__)

  # Well above a healthy run (about a second) and below the tests' own
  # timeout, so a wedged dnf ends the container rather than the suite.
  @timeout_seconds 120

  @doc "The client image. `test/test_helper.exs` excludes `:container` until it is pulled."
  def image, do: @image

  @doc "Whether podman and the pulled image are available on this host."
  def available? do
    System.find_executable("podman") != nil and
      match?({_, 0}, System.cmd("podman", ["image", "exists", @image], stderr_to_stdout: true))
  end

  @doc """
  Runs the check in a fresh container with the script's arguments
  (`repo-file-url`, `package`, optional `verify-command`). `:env` passes
  the script's `DZ_CLIENT_*` settings in. Returns the combined output and
  the exit status.
  """
  @spec check([String.t()], keyword()) :: {String.t(), non_neg_integer()}
  def check(args, opts \\ []) do
    env = for {name, value} <- Keyword.get(opts, :env, []), do: "--env=#{name}=#{value}"

    podman =
      ["podman", "run", "--rm", "--network=host", "--pull=never"] ++
        env ++ [@image, "bash", "-c", File.read!(@script), "dnf_client_check.sh"] ++ args

    System.cmd(
      "timeout",
      ["--kill-after=10", Integer.to_string(@timeout_seconds)] ++ podman,
      stderr_to_stdout: true
    )
  end
end
