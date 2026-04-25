defmodule ExUnitTProfTest do
  use ExUnit.Case

  test "parses supported tprof types" do
    assert ExUnitTProf.parse_type("call_count") == {:ok, :call_count}
    assert ExUnitTProf.parse_type("call_time") == {:ok, :call_time}
    assert ExUnitTProf.parse_type("call_memory") == {:ok, :call_memory}
  end

  test "rejects unsupported tprof types" do
    assert ExUnitTProf.parse_type("wall_time") == {:error, {:invalid_type, "wall_time"}}
  end

  test "test.tprof parser separates task options from mix test args" do
    {opts, test_args} =
      Mix.Tasks.Test.Tprof.parse!([
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
        "ExUnitTProf",
        "--trace-start-event",
        "ex_unit_tprof.profile.start",
        "--trace-stop-event",
        "ex_unit_tprof.profile.stop"
      ])

    assert opts.type == :call_memory
    assert opts.limit == 10
    assert opts.report == "tmp/report.txt"
    assert opts.artifact == "tmp/profile.etf"
    assert opts.flamegraph
    assert opts.flame_dir == "tmp/flame"
    assert opts.trace_modules == ["ExUnitTProf"]
    assert opts.trace_start_event == "ex_unit_tprof.profile.start"
    assert opts.trace_stop_event == "ex_unit_tprof.profile.stop"
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
      ExUnitTProf.Report.render(inspected,
        limit: 1,
        test_args: ["test/path_test.exs:42"]
      )

    assert report =~ "ExUnit tprof report"
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

    assert ExUnitTProf.FlameWriter.folded(profile.folded) =~ "A.f/1;B.g/2 3"

    speedscope = ExUnitTProf.FlameWriter.speedscope(profile.events)
    assert speedscope =~ ~s("type":"evented")
    assert speedscope =~ ~s("name":"A.f/1")

    svg = ExUnitTProf.FlameWriter.svg(profile.folded)
    assert svg =~ "<svg"
    assert svg =~ "ExUnit trace flamegraph"
    assert svg =~ "<rect"
  end

  test "trace flame can be gated by telemetry events" do
    {_result, profile} =
      ExUnitTProf.TraceFlame.profile(
        fn ->
          :telemetry.execute([:ex_unit_tprof, :profile, :start], %{system_time: 1}, %{})
          ExUnitTProf.parse_type("call_count")
          :telemetry.execute([:ex_unit_tprof, :profile, :stop], %{duration: 2}, %{})
        end,
        [ExUnitTProf],
        trigger:
          {:telemetry, [:ex_unit_tprof, :profile, :start], [:ex_unit_tprof, :profile, :stop]}
      )

    assert profile.trigger == :telemetry
    assert length(profile.telemetry_events) == 2
    assert profile.folded["ExUnitTProf.parse_type/1"] == 1
  end

  test "emits telemetry around profile target work" do
    :telemetry.execute([:ex_unit_tprof, :profile, :start], %{system_time: 1}, %{})
    assert ExUnitTProf.parse_type("call_count") == {:ok, :call_count}
    :telemetry.execute([:ex_unit_tprof, :profile, :stop], %{duration: 2}, %{})
  end
end
