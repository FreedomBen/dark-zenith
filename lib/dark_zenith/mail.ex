defmodule DarkZenith.Mail do
  @moduledoc """
  Outbound email plumbing (DESIGN.md: Email Delivery).

  `MAIL_ADAPTER` aliases map to Swoosh adapters here; unknown aliases refuse
  boot. Every notification is dispatched through the `EmailDelivery` Oban
  worker, inserted in the same transaction as the state change that
  triggers it, so the action cannot commit without durably recording its
  notification work. Delivery is at-least-once under Background Retry
  Policy.
  """

  import Swoosh.Email

  @adapters %{
    "zepto" => Swoosh.Adapters.ZeptoMail,
    "smtp" => Swoosh.Adapters.SMTP,
    "local" => Swoosh.Adapters.Local
  }

  @doc "Maps a `MAIL_ADAPTER` alias to its Swoosh adapter, or raises."
  def adapter_for(alias_name) do
    case Map.fetch(@adapters, alias_name) do
      {:ok, adapter} ->
        adapter

      :error ->
        raise ArgumentError,
              "unknown MAIL_ADAPTER #{inspect(alias_name)}; supported: #{Enum.join(Map.keys(@adapters), ", ")}"
    end
  end

  @doc "The configured sender as a `{name, address}` tuple."
  def from do
    Application.get_env(:dark_zenith, :mail_from, {"Dark Zenith", "contact@example.com"})
  end

  @doc "Builds a plain-text notification email from the configured sender."
  def build(to, subject, text_body) do
    new()
    |> to(to)
    |> from(from())
    |> subject(subject)
    |> text_body(text_body)
  end

  @doc """
  Enqueues an email for Oban-backed delivery. Call inside the transaction
  that performs the triggering state change. Returns the built email.
  """
  def enqueue(%Swoosh.Email{} = email) do
    [{_name, to_address}] = email.to
    {from_name, from_address} = email.from

    %{
      "to" => to_address,
      "from_name" => from_name,
      "from_address" => from_address,
      "subject" => email.subject,
      "text_body" => email.text_body
    }
    |> DarkZenith.Workers.EmailDelivery.new()
    |> Oban.insert!()

    email
  end
end
