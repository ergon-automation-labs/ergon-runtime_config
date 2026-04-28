defmodule BotArmyRuntimeConfig.ConfigStoreTest do
  use ExUnit.Case
  @moduletag :stores

  alias BotArmyRuntimeConfig.ConfigStore

  setup do
    tenant = "test-" <> Integer.to_string(System.unique_integer([:positive]))
    {:ok, tenant: tenant}
  end

  test "set, get, list, delete with prefix", %{tenant: t} do
    assert {:ok, %{value: true, updated_at: _}} = ConfigStore.set(t, "app.debug", true)
    assert {:ok, true, _} = ConfigStore.get(t, "app.debug")

    assert {:ok, _} = ConfigStore.set(t, "app.verbose", "yes")

    listed = ConfigStore.list(t, "app.")
    assert length(listed) == 2

    assert :ok = ConfigStore.delete(t, "app.debug")
    assert {:error, :not_found} = ConfigStore.get(t, "app.debug")
  end

  test "rejects non-JSON values", %{tenant: t} do
    bad = {:tuple, :bad}
    assert {:error, _} = ConfigStore.set(t, "x", bad)
  end
end
