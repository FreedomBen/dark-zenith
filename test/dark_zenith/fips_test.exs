defmodule DarkZenith.FipsModeTest do
  @moduledoc """
  FIPS-mode test profile (DESIGN.md: GPG Signing; RPM Parsing), enabled by
  `test_helper.exs` only when the host kernel is in FIPS mode.

  An otherwise allowlisted signing algorithm that the deployment's crypto
  policy disables must be rejected as unusable with the fail-closed
  `validation_failed` outcome (422) — Dark Zenith never weakens the policy
  — and the weak-digest parser rejections hold unchanged under this
  profile.
  """

  # Not async: may swap the rpm-compat implementation for the real one.
  use ExUnit.Case, async: false

  @moduletag :fips

  import DarkZenith.RpmFixtures

  alias DarkZenith.Gpg
  alias DarkZenith.Rpm.Parser

  setup do
    # With the native tools present, run the real per-key compatibility
    # test instead of the test-env stub, so the crypto policy governs the
    # full validation pipeline.
    if System.find_executable("rpmsign") && System.find_executable("rpmkeys") do
      previous = Application.get_env(:dark_zenith, :gpg_rpm_compat_impl)
      Application.put_env(:dark_zenith, :gpg_rpm_compat_impl, DarkZenith.Gpg.RpmCompat)
      on_exit(fn -> Application.put_env(:dark_zenith, :gpg_rpm_compat_impl, previous) end)
    end

    :ok
  end

  test "each allowlisted algorithm is usable or fails closed as validation_failed" do
    for algorithm <- Gpg.generation_algorithms() do
      case Gpg.generate_key_pair(algorithm, "Dark Zenith FIPS Test <fips@example.invalid>") do
        {:ok, %{public: public, private: private}} ->
          case Gpg.validate_key_pair(public, private) do
            {:ok, _info} ->
              :ok

            {:error, :validation_failed} ->
              # The policy admits generation but rejects usable signing:
              # still the documented fail-closed 422.
              :ok

            other ->
              flunk("unexpected validation outcome for #{algorithm}: #{inspect(other)}")
          end

        {:error, :validation_failed} ->
          # The crypto policy disables the algorithm outright: fail closed.
          :ok

        other ->
          flunk("expected fail-closed validation_failed for #{algorithm}: #{inspect(other)}")
      end
    end
  end

  test "weak-digest v4 variants stay rejected under the FIPS profile" do
    binary = v4_binary()

    # SHA256HEADER retagged away leaves a weak-only package.
    without_header_digest = patch_entry(binary, 96, find_entry(binary, 96, 273), tag: 998)
    assert {:error, :weak_digests} = Parser.parse(without_header_digest)

    # PAYLOADDIGESTALGO value 8 (SHA-256) downgraded to 2 (SHA-1).
    main = main_header_offset(binary)
    {nindex, _} = header_counts(binary, main)
    index = find_entry(binary, main, 5093)

    <<_tag::32, _type::32, offset::32, _count::32>> =
      binary_part(binary, main + 16 + index * 16, 16)

    weak_algo = patch(binary, main + 16 + nindex * 16 + offset, <<2::32>>)
    assert {:error, :weak_digests} = Parser.parse(weak_algo)
  end
end
