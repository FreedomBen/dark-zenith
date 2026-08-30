defmodule DarkZenith.Repositories.RepoFile do
  @moduledoc """
  Renders the `dark-zenith.repo` configuration for a repository (DESIGN.md:
  .repo File Endpoint). Shared by the serving endpoint and the web UI's setup
  instructions. Never embeds real credentials — private configurations use
  the `password=<api-key>` placeholder.
  """

  alias DarkZenith.Repositories.Repository

  @doc """
  Renders the .repo file contents. Options:

    * `:credentials` — `:auto` (placeholders for private repositories only,
      the default), `:with_placeholders` (force the authenticated variant,
      used by the public-repo authenticated setup instructions), or `:none`
  """
  def render(%Repository{} = repository, base_url, opts \\ []) do
    credentials_mode = Keyword.get(opts, :credentials, :auto)

    include_credentials? =
      case credentials_mode do
        :auto -> not repository.is_public
        :with_placeholders -> true
        :none -> false
      end

    credentials =
      if include_credentials?, do: ["username=token", "password=<api-key>"], else: []

    repo_gpgcheck = if repository.gpg_key_fingerprint, do: "1", else: "0"
    gpgcheck = if repository.rpm_signing_state == "enabled", do: "1", else: "0"

    gpgkey =
      if repository.gpg_key_fingerprint do
        ["gpgkey=#{base_url}/repos/#{repository.slug}/RPM-GPG-KEY"]
      else
        []
      end

    lines =
      [
        "[dark-zenith-#{repository.slug}]",
        "name=Dark Zenith - #{repository.name}",
        "baseurl=#{base_url}/repos/#{repository.slug}/"
      ] ++
        credentials ++
        [
          "enabled=1",
          "metadata_expire=6h",
          "repo_gpgcheck=#{repo_gpgcheck}",
          "gpgcheck=#{gpgcheck}"
        ] ++ gpgkey

    Enum.join(lines, "\n") <> "\n"
  end
end
