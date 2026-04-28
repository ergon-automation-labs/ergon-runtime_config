defmodule BotArmyRuntimeConfig.ConfigStore do
  @moduledoc """
  In-memory tenant-scoped configuration backed by a public ETS `:set` table.

  Reads are direct ETS lookups. Mutations go through this `GenServer` for a single writer
  and simple invariants (size limits, JSON-encodable values).
  """

  use GenServer

  @table :bot_army_runtime_config_kv
  @max_key_bytes 512
  @max_value_bytes 256_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    if :ets.whereis(@table) == :undefined do
      _ =
        :ets.new(@table, [
          :named_table,
          :public,
          :set,
          {:read_concurrency, true},
          {:write_concurrency, true}
        ])
    end

    {:ok, %{}}
  end

  @spec get(String.t(), String.t()) ::
          {:ok, term(), DateTime.t()} | {:error, :not_found}
  def get(tenant_id, key)
      when is_binary(tenant_id) and is_binary(key) do
    case :ets.lookup(@table, {tenant_id, key}) do
      [] ->
        {:error, :not_found}

      [{_, %{value: value, updated_at: at}}] when is_struct(at, DateTime) ->
        {:ok, value, at}
    end
  end

  @spec set(String.t(), String.t(), term()) ::
          {:ok, %{value: term(), updated_at: DateTime.t()}}
          | {:error, term()}
  def set(tenant_id, key, value)
      when is_binary(tenant_id) and is_binary(key) do
    GenServer.call(__MODULE__, {:set, tenant_id, key, value}, 10_000)
  end

  @spec delete(String.t(), String.t()) :: :ok | {:error, :not_found}
  def delete(tenant_id, key) when is_binary(tenant_id) and is_binary(key) do
    GenServer.call(__MODULE__, {:delete, tenant_id, key}, 10_000)
  end

  @spec list(String.t(), String.t()) :: [
          %{key: String.t(), value: term(), updated_at: DateTime.t()}
        ]
  def list(tenant_id, prefix \\ "")
      when is_binary(tenant_id) and is_binary(prefix) do
    :ets.foldl(
      fn
        {{^tenant_id, k}, %{value: v, updated_at: at}}, acc ->
          if prefix == "" or String.starts_with?(k, prefix) do
            [%{key: k, value: v, updated_at: at} | acc]
          else
            acc
          end

        _, acc ->
          acc
      end,
      [],
      @table
    )
    |> Enum.sort_by(& &1.key)
  end

  @impl true
  def handle_call({:set, tenant_id, key, value}, _from, state) do
    reply =
      with :ok <- validate_key(key),
           :ok <- validate_value(value) do
        updated_at = DateTime.utc_now()
        meta = %{value: value, updated_at: updated_at}
        :ets.insert(@table, {{tenant_id, key}, meta})
        {:ok, meta}
      end

    {:reply, reply, state}
  end

  def handle_call({:delete, tenant_id, key}, _from, state) do
    reply =
      case :ets.lookup(@table, {tenant_id, key}) do
        [] ->
          {:error, :not_found}

        [_] ->
          :ets.delete(@table, {tenant_id, key})
          :ok
      end

    {:reply, reply, state}
  end

  defp validate_key(key) do
    cond do
      byte_size(key) > @max_key_bytes ->
        {:error, :key_too_long}

      key == "" ->
        {:error, :invalid_key}

      true ->
        :ok
    end
  end

  defp validate_value(value) do
    encoded = Jason.encode!(value)

    if byte_size(encoded) > @max_value_bytes do
      {:error, :value_too_large}
    else
      :ok
    end
  rescue
    e in Protocol.UndefinedError ->
      {:error, {:not_json_encodable, e.description}}

    e in Jason.EncodeError ->
      {:error, {:invalid_value, e.message}}
  end
end
