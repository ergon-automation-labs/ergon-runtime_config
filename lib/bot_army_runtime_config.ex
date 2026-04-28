defmodule BotArmyRuntimeConfig do
  @moduledoc """
  Tenant-scoped runtime configuration served over NATS.

  Values are stored in memory per bot instance (`BotArmyRuntimeConfig.ConfigStore`, backed by ETS).
  Operations use subjects such as `runtime_config.get`, `runtime_config.set`, `runtime_config.list`,
  and `runtime_config.delete`. Writes emit `events.runtime_config.changed`.
  """
end
