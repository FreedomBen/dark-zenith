defmodule DarkZenith do
  @moduledoc """
  DarkZenith keeps the contexts that define your domain
  and business logic.

  Contexts are also responsible for managing your data, regardless
  if it comes from the database, an external API or others.
  """

  @doc """
  URL of the corresponding source for the running code (DESIGN.md: `SOURCE_URL`),
  rendered as the web UI footer's Source link to satisfy AGPL §13.
  """
  def source_url do
    Application.fetch_env!(:dark_zenith, :source_url)
  end
end
