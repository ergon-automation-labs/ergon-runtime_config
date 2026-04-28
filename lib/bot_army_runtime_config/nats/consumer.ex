defmodule BotArmyRuntimeConfig.NATS.Consumer do
  @moduledoc """
  NATS request/reply for tenant-scoped runtime config. Publishes `events.runtime_config.changed` on writes.
  """

  use GenServer
  require Logger

  alias BotArmyRuntimeConfig.ConfigStore
  alias BotArmyRuntime.NATS.Connection
  alias BotArmyRuntime.Tenant

  @registry_heartbeat_ms 20_000
  @version Mix.Project.config()[:version]

  @subjects [
    %{
      subject: "runtime_config.get",
      type: :request_reply,
      description: "Get a config value for a tenant/key"
    },
    %{
      subject: "runtime_config.set",
      type: :request_reply,
      description: "Set a JSON-encodable value"
    },
    %{
      subject: "runtime_config.list",
      type: :request_reply,
      description: "List keys (optional key prefix)"
    },
    %{
      subject: "runtime_config.delete",
      type: :request_reply,
      description: "Delete a config key"
    }
  ]

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc false
  def registered_subjects, do: @subjects

  @impl true
  def init(opts) do
    tenant_id = Keyword.get(opts, :tenant_id)

    case GenServer.call(Connection, :get_connection, 5000) do
      {:ok, conn} ->
        subscriptions =
          for %{subject: subject} <- @subjects do
            {Gnat.sub(conn, self(), subject), subject}
          end

        Logger.info("[NATS.Consumer] Subscribed to runtime_config subjects")
        BotArmyRuntime.Registry.register("runtime_config", @subjects, @version)
        Process.send_after(self(), :registry_heartbeat, @registry_heartbeat_ms)

        {:ok,
         %{
           conn: conn,
           subscriptions: subscriptions,
           tenant_id: tenant_id,
           registry_registered?: true
         }}

      {:error, reason} ->
        Logger.error("[NATS.Consumer] NATS connection failed: #{inspect(reason)}")
        {:stop, :nats_connection_failed}
    end
  end

  @impl true
  def handle_info({:msg, msg}, state) do
    BotArmyRuntime.Tracing.with_consumer_span(msg.topic, Map.get(msg, :headers, []), fn ->
      case decode_message(msg.body) do
        {:ok, payload} ->
          route_message(msg.topic, payload, msg.reply_to, state)

        {:error, reason} ->
          Logger.warning("[NATS.Consumer] Decode failed: #{inspect(reason)}")

          if msg.reply_to do
            send_reply(msg.reply_to, %{"ok" => false, "error" => "decode_failed"})
          end
      end
    end)

    {:noreply, state}
  end

  def handle_info(:registry_heartbeat, state) do
    if Map.get(state, :registry_registered?) do
      BotArmyRuntime.Registry.register("runtime_config", @subjects, @version)
      Process.send_after(self(), :registry_heartbeat, @registry_heartbeat_ms)
    end

    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp route_message("runtime_config.get", payload, reply_to, _state) do
    tenant = tenant_id(payload)
    key = Map.get(payload, "key")

    cond do
      not is_binary(key) or key == "" ->
        send_reply(reply_to, %{"ok" => false, "error" => "key required"})

      true ->
        case ConfigStore.get(tenant, key) do
          {:ok, value, at} ->
            send_reply(reply_to, %{
              "ok" => true,
              "tenant_id" => tenant,
              "key" => key,
              "value" => value,
              "updated_at" => DateTime.to_iso8601(at)
            })

          {:error, :not_found} ->
            send_reply(reply_to, %{"ok" => false, "error" => "not_found"})
        end
    end
  end

  defp route_message("runtime_config.set", payload, reply_to, _state) do
    tenant = tenant_id(payload)
    key = Map.get(payload, "key")

    cond do
      not is_binary(key) or key == "" ->
        send_reply(reply_to, %{"ok" => false, "error" => "key required"})

      not Map.has_key?(payload, "value") ->
        send_reply(reply_to, %{"ok" => false, "error" => "value required"})

      true ->
        value = Map.get(payload, "value")

        case ConfigStore.set(tenant, key, value) do
          {:ok, %{value: stored, updated_at: at}} ->
            publish_changed(tenant, key, "set", stored)

            send_reply(reply_to, %{
              "ok" => true,
              "tenant_id" => tenant,
              "key" => key,
              "value" => stored,
              "updated_at" => DateTime.to_iso8601(at)
            })

          {:error, reason} ->
            send_reply(reply_to, %{"ok" => false, "error" => format_error(reason)})
        end
    end
  end

  defp route_message("runtime_config.list", payload, reply_to, _state) do
    tenant = tenant_id(payload)
    prefix = Map.get(payload, "prefix", "")
    prefix = if is_binary(prefix), do: prefix, else: ""

    rows = ConfigStore.list(tenant, prefix)

    items =
      Enum.map(rows, fn %{key: k, value: v, updated_at: at} ->
        %{
          "key" => k,
          "value" => v,
          "updated_at" => DateTime.to_iso8601(at)
        }
      end)

    send_reply(reply_to, %{
      "ok" => true,
      "tenant_id" => tenant,
      "items" => items,
      "count" => length(items)
    })
  end

  defp route_message("runtime_config.delete", payload, reply_to, _state) do
    tenant = tenant_id(payload)
    key = Map.get(payload, "key")

    cond do
      not is_binary(key) or key == "" ->
        send_reply(reply_to, %{"ok" => false, "error" => "key required"})

      true ->
        case ConfigStore.delete(tenant, key) do
          :ok ->
            publish_changed(tenant, key, "delete", nil)
            send_reply(reply_to, %{"ok" => true, "tenant_id" => tenant, "key" => key})

          {:error, :not_found} ->
            send_reply(reply_to, %{"ok" => false, "error" => "not_found"})
        end
    end
  end

  defp route_message(topic, _payload, _reply_to, _state) do
    Logger.debug("[NATS.Consumer] Unhandled topic: #{topic}")
    :ok
  end

  defp tenant_id(payload) when is_map(payload) do
    case Map.get(payload, "tenant_id") do
      tid when is_binary(tid) and tid != "" -> tid
      _ -> System.get_env("BOT_ARMY_TENANT_ID") || Tenant.default_tenant_id()
    end
  end

  defp format_error(:key_too_long), do: "key_too_long"
  defp format_error(:invalid_key), do: "invalid_key"
  defp format_error(:value_too_large), do: "value_too_large"
  defp format_error({:not_json_encodable, d}), do: "not_json_encodable: #{d}"
  defp format_error({:invalid_value, m}), do: "invalid_value: #{m}"
  defp format_error(other), do: inspect(other)

  defp publish_changed(tenant_id, key, action, value_or_nil) do
    payload =
      %{
        "tenant_id" => tenant_id,
        "key" => key,
        "action" => action,
        "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
      }
      |> maybe_put_value(action, value_or_nil)

    case BotArmyRuntime.NATS.Publisher.publish("events.runtime_config.changed", payload) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning("[NATS.Consumer] Failed to publish change event: #{inspect(reason)}")
        :error
    end
  end

  defp maybe_put_value(payload, "delete", _), do: payload

  defp maybe_put_value(payload, _action, value) do
    Map.put(payload, "value", value)
  end

  defp decode_message(body) do
    case BotArmyCore.NATS.Decoder.decode(body) do
      {:ok, %{"payload" => payload}} ->
        {:ok, payload}

      {:ok, payload} when is_map(payload) ->
        {:ok, payload}

      {:error, _reason} ->
        case Jason.decode(body) do
          {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
          error -> error
        end
    end
  end

  defp send_reply(nil, _payload), do: :ok

  defp send_reply(reply_to, payload) when is_binary(reply_to) do
    case BotArmyRuntime.NATS.Publisher.publish(reply_to, payload) do
      :ok ->
        :ok

      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning("[NATS.Consumer] Reply failed: #{inspect(reason)}")
    end
  end
end
