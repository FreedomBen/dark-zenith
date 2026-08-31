defmodule DarkZenithWeb.LiveRateLimit do
  @moduledoc """
  LiveView event rate limiting (DESIGN.md: Rate Limiting). Every
  user-initiated event consumes the applicable general bucket — per-user
  on authenticated sockets, per-IP otherwise — and the named specialized
  events also consume their corresponding hourly bucket. A rejected event's
  handler never runs; the socket receives a `rate_limited` payload and a
  flash without disconnecting. Heartbeats and internal messages never
  reach this hook.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView

  alias DarkZenith.ClientIp
  alias DarkZenith.RateLimit

  # view module => %{event => specialized bucket kind}
  @specialized %{
    DarkZenithWeb.RepositoryLive.Upload => %{"select_file" => :upload_intent},
    DarkZenithWeb.RepositoryLive.New => %{"save" => :repo_create},
    DarkZenithWeb.RepositoryLive.Settings => %{"add_collaborator" => :collaborator_add},
    DarkZenithWeb.UserLive.Settings => %{
      "create_api_key" => :api_key_create,
      "upload_gpg_key" => :gpg_key_mutation,
      "remove_gpg_key" => :gpg_key_mutation,
      "update_email" => :email_change
    }
  }

  # view module => %{event => path to the email param for the email bucket}
  @auth_attempts %{
    DarkZenithWeb.UserLive.Registration => %{"save" => ["user", "email"]},
    DarkZenithWeb.UserLive.ForgotPassword => %{"send_email" => ["user", "email"]},
    DarkZenithWeb.UserLive.ConfirmationInstructions => %{
      "send_instructions" => ["user", "email"]
    }
  }

  def on_mount(:default, _params, _session, socket) do
    identity = socket_identity(socket)

    {:cont,
     socket
     |> assign(:__rate_identity__, identity)
     |> attach_hook(:rate_limit, :handle_event, &limit_event/3)}
  end

  defp socket_identity(socket) do
    case socket.assigns[:current_scope] do
      %{user: %{id: id}} when not is_nil(id) ->
        {:user, id}

      _ ->
        ip =
          case get_connect_info(socket, :peer_data) do
            %{address: address} -> ClientIp.bucket_identity(address)
            _ -> :unknown_peer
          end

        {:ip, ip}
    end
  end

  defp limit_event(event, params, socket) do
    identity = socket.assigns[:__rate_identity__] || {:ip, :unknown_peer}
    buckets = buckets_for(socket.view, event, params, identity)

    {allowed?, governing} = RateLimit.hit(buckets)

    if allowed? do
      {:cont, socket}
    else
      retry_after = max(governing.reset - System.os_time(:second), 1)

      payload = %{
        limit: governing.limit,
        remaining: governing.remaining,
        reset: governing.reset,
        retry_after: retry_after
      }

      {:halt,
       socket
       |> push_event("rate_limited", payload)
       |> put_flash(:error, "Too many requests. Please retry in #{retry_after} seconds.")}
    end
  end

  defp buckets_for(view, event, params, identity) do
    case Map.fetch(Map.get(@auth_attempts, view, %{}), event) do
      {:ok, email_path} ->
        auth_attempt_buckets(email_path, params, identity)

      :error ->
        general =
          case identity do
            {:user, id} -> [{:general_auth, id}]
            {:ip, ip} -> [{:general_unauth, ip}]
          end

        specialized =
          case {identity, get_in(@specialized, [view, event])} do
            {{:user, id}, kind} when not is_nil(kind) -> [{kind, id}]
            _ -> []
          end

        general ++ specialized
    end
  end

  # Auth-attempt events replace the general bucket with IP + email buckets.
  defp auth_attempt_buckets(email_path, params, identity) do
    ip =
      case identity do
        {:ip, ip} -> ip
        {:user, _} -> :authenticated
      end

    email = email_path && get_in(params, email_path)

    email_bucket =
      with true <- is_binary(email),
           normalized = email |> String.trim() |> String.downcase(),
           true <- normalized =~ ~r/^[^@,;\s]+@[^@,;\s]+$/ do
        [{:auth_attempt_email, normalized}]
      else
        _ -> []
      end

    [{:auth_attempt_ip, ip} | email_bucket]
  end
end
