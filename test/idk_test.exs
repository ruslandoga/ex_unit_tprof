defmodule IdkTest do
  use ExUnit.Case

  test "parses supported tprof types" do
    assert Idk.parse_type("call_count") == {:ok, :call_count}
    assert Idk.parse_type("call_time") == {:ok, :call_time}
    assert Idk.parse_type("call_memory") == {:ok, :call_memory}
  end

  test "rejects unsupported tprof types" do
    assert Idk.parse_type("wall_time") == {:error, {:invalid_type, "wall_time"}}
  end

  test "idk test parser separates task options from mix test args" do
    {opts, test_args} =
      Mix.Tasks.Idk.Test.parse!([
        "test/path_test.exs:42",
        "--seed",
        "123",
        "--type",
        "call_memory",
        "--limit",
        "10",
        "--report",
        "tmp/report.txt",
        "--artifact",
        "tmp/profile.etf",
        "--flamegraph",
        "--flame-dir",
        "tmp/flame",
        "--trace-module",
        "Idk",
        "--trace-start-event",
        "idk.profile.start",
        "--trace-stop-event",
        "idk.profile.stop"
      ])

    assert opts.type == :call_memory
    assert opts.limit == 10
    assert opts.report == "tmp/report.txt"
    assert opts.artifact == "tmp/profile.etf"
    assert opts.flamegraph
    assert opts.flame_dir == "tmp/flame"
    assert opts.trace_modules == ["Idk"]
    assert opts.trace_start_event == "idk.profile.start"
    assert opts.trace_stop_event == "idk.profile.stop"
    assert test_args == ["test/path_test.exs:42", "--seed", "123"]
  end

  test "report renders combined tprof rows" do
    inspected = %{
      all:
        {:call_memory, 12,
         [
           {Enum, {:map, 2}, 3, 9, 3, 75.0},
           {List, {:flatten, 1}, 1, 3, 3, 25.0}
         ]}
    }

    report =
      Idk.Report.render(inspected,
        limit: 1,
        test_args: ["test/path_test.exs:42"]
      )

    assert report =~ "Idk tprof report"
    assert report =~ "Profile type: call_memory"
    assert report =~ "Test args: test/path_test.exs:42"
    assert report =~ "Total allocated words: 12"
    assert report =~ "Rows shown: 1 of 2"
    assert report =~ "Enum.map/2"
    refute report =~ "List.flatten/1"
    assert report =~ ":tprof` is experimental"
  end

  test "flame writer renders folded stacks and speedscope json" do
    profile = %{
      folded: %{
        "A.f/1;B.g/2" => 3,
        "A.f/1" => 1
      },
      events: [
        {:open, self(), "A.f/1", 10},
        {:open, self(), "B.g/2", 20},
        {:close, self(), "A.f/1", 30},
        {:close, self(), "root/0", 40}
      ]
    }

    assert Idk.FlameWriter.folded(profile.folded) =~ "A.f/1;B.g/2 3"

    speedscope = Idk.FlameWriter.speedscope(profile.events)
    assert speedscope =~ ~s("type":"evented")
    assert speedscope =~ ~s("name":"A.f/1")

    svg = Idk.FlameWriter.svg(profile.folded)
    assert svg =~ "<svg"
    assert svg =~ "Idk trace flamegraph"
    assert svg =~ "<rect"
  end

  test "trace flame can be gated by telemetry events" do
    {_result, profile} =
      Idk.TraceFlame.profile(
        fn ->
          :telemetry.execute([:idk, :profile, :start], %{system_time: 1}, %{})
          Idk.parse_type("call_count")
          :telemetry.execute([:idk, :profile, :stop], %{duration: 2}, %{})
        end,
        [Idk],
        trigger: {:telemetry, [:idk, :profile, :start], [:idk, :profile, :stop]}
      )

    assert profile.trigger == :telemetry
    assert length(profile.telemetry_events) == 2
    assert profile.folded["Idk.parse_type/1"] == 1
  end

  test "emits telemetry around profile target work" do
    :telemetry.execute([:idk, :profile, :start], %{system_time: 1}, %{})
    assert Idk.parse_type("call_count") == {:ok, :call_count}
    :telemetry.execute([:idk, :profile, :stop], %{duration: 2}, %{})
  end
end
