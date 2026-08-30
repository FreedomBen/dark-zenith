defmodule DarkZenith.Repo do
  use Ecto.Repo,
    otp_app: :dark_zenith,
    adapter: Ecto.Adapters.Postgres
end
