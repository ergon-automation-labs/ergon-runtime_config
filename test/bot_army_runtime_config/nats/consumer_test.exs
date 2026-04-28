defmodule BotArmyRuntimeConfig.NATS.ConsumerTest do
  use ExUnit.Case
  @moduletag :nats

  test "registers expected request/reply subjects" do
    subjects =
      BotArmyRuntimeConfig.NATS.Consumer.registered_subjects()
      |> Enum.map(& &1.subject)

    assert "runtime_config.get" in subjects
    assert "runtime_config.set" in subjects
    assert "runtime_config.list" in subjects
    assert "runtime_config.delete" in subjects
  end
end
