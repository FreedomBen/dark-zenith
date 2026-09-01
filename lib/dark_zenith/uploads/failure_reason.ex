defmodule DarkZenith.Uploads.FailureReason do
  @moduledoc """
  The closed vocabulary of sanitized upload failure reasons
  (DESIGN.md: Upload Failure Reasons).

  `last_error_code` is the coarse contract-stable outcome; a reason refines it
  so an uploader can tell which rejection produced a `validation_failed`. Every
  reason classifies the submitted file or the pipeline stage that rejected it —
  never tool output, stderr, filesystem paths, or storage detail.

  `sanitize/1` fails closed: a term outside the vocabulary yields `nil` rather
  than surfacing an unreviewed internal name.
  """

  # RPM structural rejections (DESIGN.md: Package Upload & Processing step 1).
  @structural %{
    bad_lead_magic: "The file does not begin with an RPM lead.",
    bad_header_magic: "An RPM header does not begin with the header magic.",
    unsupported_format: "The RPM format version is not supported; only v4 and v6 are accepted.",
    truncated: "The file ends before its headers are complete.",
    header_too_large: "The combined header regions exceed the 64 MiB limit.",
    too_many_entries: "A header declares more than 65 535 index entries.",
    empty_header: "A header declares no index entries.",
    duplicate_tag: "A header repeats the same physical tag number.",
    unknown_entry_type: "A header entry declares an unknown value type.",
    invalid_count: "A header entry declares an invalid value count.",
    misaligned_entry: "A header entry's data is not aligned for its type.",
    entry_out_of_bounds: "A header entry references data outside its data store.",
    overlapping_entries: "Two header entries reference overlapping data.",
    missing_region: "A header is missing its immutable region entry.",
    invalid_region: "A header's immutable region entry or trailer is invalid.",
    unsorted_tags: "A v6 header's tag numbers are not strictly increasing.",
    nonzero_padding: "A v6 header's unused data-store padding is not zero-filled.",
    weak_digests: "The package's integrity depends on MD5 or SHA-1 rather than SHA-256.",
    v6_bad_encoding: "A v6 package does not declare ENCODING = \"utf-8\".",
    v6_missing_mandatory_tag: "A v6 package is missing a tag the format marks mandatory.",
    v6_reserved_not_zero: "A v6 signature's RESERVED entry is not zero-filled.",
    v6_signature_forbidden_tag: "A v6 signature carries a tag the format forbids.",
    v6_signature_missing_reserved: "A v6 signature is missing its final RESERVED entry.",
    v6_weak_file_digest: "A v6 package's file-digest algorithm is weaker than SHA-256."
  }

  # RPM semantic rejections (DESIGN.md: Package Upload & Processing step 3).
  @semantic %{
    missing_required_field: "A required header field is absent or empty.",
    malformed_header_value: "A header tag has an unexpected physical type.",
    malformed_i18n: "The internationalized string table and its values disagree in count.",
    invalid_nevra:
      "The name, version, release, or architecture is empty, too long, or uses characters outside `[A-Za-z0-9._+~-]`.",
    invalid_string:
      "A string field is not valid UTF-8, or contains control or non-XML characters.",
    invalid_url: "The URL field is not an absolute HTTP or HTTPS URL.",
    string_too_long: "A string field exceeds its maximum length.",
    malformed_dependency:
      "A dependency list has mismatched arrays, or an invalid flag or version.",
    malformed_files:
      "The file arrays have mismatched lengths or an out-of-range directory index.",
    malformed_changelogs: "The changelog arrays have mismatched lengths.",
    malformed_sourcenevr:
      "The v6 SOURCENEVR value is not a well-formed name-[epoch:]version-release.",
    missing_sourcenevr: "A v6 binary package is missing its required SOURCENEVR tag.",
    too_many_dependencies: "A dependency list exceeds 65 536 entries.",
    too_many_files: "The package declares more than 262 144 files.",
    too_many_changelogs: "The package declares more than 4 096 changelog entries."
  }

  # Deterministic pipeline stages that classify themselves.
  @pipeline %{
    integrity_check_failed:
      "RPM verification reported a bad digest or signature, or reported no digest at all.",
    preview_metadata_mismatch: "Re-extracted metadata no longer matches the confirmed preview.",
    signing_key_not_configured:
      "This repository signs packages, but its owner has no signing key configured.",
    signed_output_verification_failed:
      "The signed package failed verification against the configured key.",
    storage_key_too_long: "The resulting storage key exceeds 1 024 bytes."
  }

  @messages Map.merge(@structural, Map.merge(@semantic, @pipeline))
  @names Map.new(@messages, fn {reason, _message} -> {Atom.to_string(reason), reason} end)

  @doc "Every reason name in the vocabulary."
  def names, do: Map.keys(@names)

  @doc """
  The reason name for a rejection term, or `nil` when it is outside the
  vocabulary. Unknown terms fail closed so nothing unreviewed is surfaced.
  """
  def sanitize(reason) when is_atom(reason) do
    if Map.has_key?(@messages, reason), do: Atom.to_string(reason), else: nil
  end

  def sanitize(_reason), do: nil

  @doc "The human-readable explanation for a reason name, or `nil` when unknown."
  def message(name) when is_binary(name) do
    case Map.fetch(@names, name) do
      {:ok, reason} -> Map.fetch!(@messages, reason)
      :error -> nil
    end
  end

  def message(_name), do: nil
end
