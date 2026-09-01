defmodule DarkZenith.Uploads.FailureReasonTest do
  use ExUnit.Case, async: true

  alias DarkZenith.Uploads.FailureReason

  @rpm_sources [
    "lib/dark_zenith/rpm/parser.ex",
    "lib/dark_zenith/rpm/extractor.ex",
    "lib/dark_zenith/rpm/header.ex"
  ]

  describe "sanitize/1" do
    test "maps a known rejection atom to its name" do
      assert FailureReason.sanitize(:malformed_header_value) == "malformed_header_value"
      assert FailureReason.sanitize(:bad_lead_magic) == "bad_lead_magic"
    end

    test "fails closed on anything outside the vocabulary" do
      for term <- [
            :some_new_internal_error,
            :"rpmkeys: /tmp/x.rpm: BAD",
            "malformed_header_value",
            nil,
            {:error, :nested},
            %{}
          ] do
        assert FailureReason.sanitize(term) == nil
      end
    end
  end

  describe "message/1" do
    test "explains a known reason" do
      assert FailureReason.message("malformed_header_value") =~ "physical type"
    end

    test "returns nil for an unknown or non-binary value" do
      assert FailureReason.message("not_a_reason") == nil
      assert FailureReason.message(nil) == nil
      assert FailureReason.message(:malformed_header_value) == nil
    end

    test "every name has a non-empty message and no leaked detail" do
      for name <- FailureReason.names() do
        message = FailureReason.message(name)
        assert is_binary(message) and message != ""
        assert String.ends_with?(message, "."), "#{name} message should be a sentence"

        # A reason is a classification, never tool output or a path.
        refute message =~ ~r{stderr|/tmp/|rpmkeys:|rpmsign:|staging/|version_id}
      end
    end
  end

  # Drift guard: a new RPM rejection reason must join the vocabulary, or it
  # silently degrades to a bare validation_failed with no detail.
  test "every RPM rejection reason is in the vocabulary" do
    reasons =
      @rpm_sources
      |> Enum.flat_map(fn path ->
        ~r/\{:error, :([a-z0-9_]+)\}/
        |> Regex.scan(File.read!(path), capture: :all_but_first)
        |> List.flatten()
      end)
      |> Enum.uniq()

    assert length(reasons) > 20,
           "expected to find the RPM rejection atoms; got #{inspect(reasons)}"

    missing = Enum.reject(reasons, &(&1 in FailureReason.names()))

    assert missing == [],
           "New RPM rejection reasons need a DarkZenith.Uploads.FailureReason entry and a " <>
             "DESIGN.md Upload Failure Reasons row: #{inspect(missing)}"
  end

  test "the vocabulary and DESIGN.md agree" do
    spec = File.read!("docs/DESIGN.md")

    section =
      spec
      |> String.split("#### Upload Failure Reasons")
      |> Enum.at(1)
      |> String.split("\n### ")
      |> hd()

    for name <- FailureReason.names() do
      assert section =~ "`#{name}`",
             "#{name} is missing from the DESIGN.md Upload Failure Reasons section"
    end
  end
end
