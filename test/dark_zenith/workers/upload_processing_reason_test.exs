defmodule DarkZenith.Workers.UploadProcessingReasonTest do
  @moduledoc """
  The sanitized reason recorded alongside `validation_failed`
  (DESIGN.md: Upload Failure Reasons).

  Integrity verification (step 2) runs before extraction (step 3), so a
  package only reaches the extractor once the verifier accepts it. These
  tests stub `rpmkeys` to report a clean digest, which is why the module is
  not async: `:rpmkeys_path` is application-global.
  """
  use DarkZenith.DataCase, async: false
  use Oban.Testing, repo: DarkZenith.Repo

  import DarkZenith.AccountsFixtures
  import DarkZenith.B2StubHelpers
  import DarkZenith.RepositoriesFixtures
  import DarkZenith.RpmFixtures

  alias DarkZenith.Rpm.Tags
  alias DarkZenith.Uploads
  alias DarkZenith.Uploads.Intent
  alias DarkZenith.Workers.UploadProcessing

  setup %{tmp_dir: tmp_dir} do
    stub = Path.join(tmp_dir, "rpmkeys")
    File.write!(stub, "#!/bin/sh\nprintf '    Header SHA256 digest: OK\\n'\nexit 0\n")
    File.chmod!(stub, 0o755)

    previous = Application.get_env(:dark_zenith, :rpmkeys_path)
    Application.put_env(:dark_zenith, :rpmkeys_path, stub)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:dark_zenith, :rpmkeys_path)
        value -> Application.put_env(:dark_zenith, :rpmkeys_path, value)
      end
    end)

    owner = user_fixture()
    %{owner: owner, repo: repository_fixture(owner)}
  end

  @tag :tmp_dir
  test "an extractor rejection records its reason beside validation_failed", ctx do
    # A well-formed package whose ARCH tag carries the wrong physical type:
    # it parses structurally, so it reaches step 3 and is rejected there.
    binary = v4_binary()
    offset = main_header_offset(binary)
    retagged = patch_entry(binary, offset, find_entry(binary, offset, Tags.arch()), type: 8)

    assert {:error, :malformed_header_value} = DarkZenith.Rpm.parse(retagged)

    intent = queued_intent!(ctx, retagged)
    assert :ok = perform_job(UploadProcessing, %{"intent_id" => intent.id})

    failed = Repo.get!(Intent, intent.id)
    assert failed.status == "failed"
    assert failed.last_error_code == "validation_failed"
    assert failed.last_error_detail == "malformed_header_value"
  end

  @tag :tmp_dir
  test "a clean package records no reason", ctx do
    intent = queued_intent!(ctx, v4_binary())
    assert :ok = perform_job(UploadProcessing, %{"intent_id" => intent.id})

    succeeded = Repo.get!(Intent, intent.id)
    assert succeeded.status == "succeeded"
    assert succeeded.last_error_code == nil
    assert succeeded.last_error_detail == nil
  end

  defp queued_intent!(ctx, binary) do
    {:ok, intent, _upload} =
      Uploads.create_intent(ctx.owner, ctx.repo, %{
        filename: "upload.rpm",
        size: byte_size(binary),
        mode: "api"
      })

    stub_pipeline(intent, binary)
    {:ok, queued} = Uploads.complete_intent(ctx.owner, intent, 1, "4_zstaged")
    queued
  end
end
