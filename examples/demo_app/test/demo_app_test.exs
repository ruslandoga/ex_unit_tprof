defmodule DemoAppTest do
  use ExUnit.Case

  test "runs work across several processes" do
    assert DemoApp.Workload.run(20_000) > 0
  end

  test "emits telemetry around the interesting work" do
    :telemetry.execute([:demo_app, :workload, :start], %{system_time: System.system_time()}, %{})
    assert DemoApp.Workload.run(20_000) > 0
    :telemetry.execute([:demo_app, :workload, :stop], %{duration: 1}, %{})
  end
end
