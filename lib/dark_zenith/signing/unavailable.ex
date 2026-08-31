defmodule DarkZenith.Signing.Unavailable do
  @moduledoc """
  Placeholder signing implementation used until the signing phase lands:
  every request reports the signing infrastructure as unavailable.
  """

  @behaviour DarkZenith.Signing

  @impl true
  def sign_repomd(_owner, _repomd_xml), do: {:error, :unavailable}

  @impl true
  def sign_rpm(_owner, _source_path, _workdir, _metadata), do: {:error, :unavailable}
end
