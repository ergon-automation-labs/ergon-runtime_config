defmodule BotArmyRuntimeConfig.Application do
  @moduledoc """
  Supervision tree for the Runtime Config Bot.

  Starts an ETS-backed `ConfigStore`, optional NATS consumer (skipped in `:test`), and pulse publisher.
  NATS connection is provided by `:bot_army_runtime`.
  """

  use Application

  @env Mix.env()

  @impl true
  def start(_type, _args) do
    children =
      []
      |> maybe_add_store()
      |> maybe_add_pulse()
      |> maybe_add_consumer()
      |> Enum.reverse()

    opts = [strategy: :one_for_one, name: BotArmyRuntimeConfig.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp maybe_add_store(children) do
    [{BotArmyRuntimeConfig.ConfigStore, []} | children]
  end

  defp maybe_add_pulse(children) do
    if @env == :test do
      children
    else
      [{BotArmyRuntimeConfig.PulsePublisher, []} | children]
    end
  end

  defp maybe_add_consumer(children) do
    if @env == :test do
      children
    else
      [{BotArmyRuntimeConfig.NATS.Consumer, []} | children]
    end
  end
end
