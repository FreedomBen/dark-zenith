# The :rpmsign-tagged integration test needs the rpm-sign tool installed.
exclude = if System.find_executable("rpmsign"), do: [], else: [:rpmsign]
ExUnit.start(exclude: exclude)
Ecto.Adapters.SQL.Sandbox.mode(DarkZenith.Repo, :manual)
