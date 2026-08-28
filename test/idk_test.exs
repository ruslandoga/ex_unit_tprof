defmodule IdkTest.SampleWorkload do
  def run do
    deadline = System.monotonic_time(:millisecond) + 20
    spin(deadline, 0)
  end

  defp spin(deadline, value) do
    if System.monotonic_time(:millisecond) < deadline do
      spin(deadline, value + 1)
    else
      value
    end
  end
end

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
        "idk.profile.stop",
        "--sample-interval",
        "2"
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
    assert opts.sample_interval == 2
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
      samples: %{
        self() => [
          %{at: 10, stack: ["A.f/1"]},
          %{at: 20, stack: ["A.f/1", "B.g/2"]}
        ]
      }
    }

    assert Idk.FlameWriter.folded(profile.folded) =~ "A.f/1;B.g/2 3"

    speedscope = Idk.FlameWriter.speedscope(profile.samples)
    assert speedscope =~ ~s("type":"sampled")
    assert speedscope =~ ~s("name":"A.f/1")

    decoded = :json.decode(speedscope)
    assert length(decoded["profiles"]) == 1
    assert length(hd(decoded["profiles"])["samples"]) == 2
    assert length(hd(decoded["profiles"])["weights"]) == 2

    svg = Idk.FlameWriter.svg(profile.folded)
    assert svg =~ "<svg"
    assert svg =~ "Idk trace flamegraph"
    assert svg =~ "<rect"
  end

  test "speedscope writes one valid profile per BEAM process" do
    other = spawn(fn -> :ok end)

    speedscope =
      Idk.FlameWriter.speedscope(%{
        self() => [%{at: 10, stack: ["A.work/0"]}],
        other => [%{at: 12, stack: ["B.work/0"]}]
      })
      |> :json.decode()

    assert length(speedscope["profiles"]) == 2
    assert Enum.all?(speedscope["profiles"], &(length(&1["samples"]) == 1))
  end

  test "trace flame can be gated by telemetry events" do
    {_result, profile} =
      Idk.TraceFlame.profile(
        fn ->
          :telemetry.execute([:idk, :profile, :start], %{system_time: 1}, %{})
          IdkTest.SampleWorkload.run()
          :telemetry.execute([:idk, :profile, :stop], %{duration: 2}, %{})
        end,
        [IdkTest.SampleWorkload],
        trigger: {:telemetry, [:idk, :profile, :start], [:idk, :profile, :stop]}
      )

    assert profile.trigger == :telemetry
    assert length(profile.telemetry_events) == 2
    assert profile.sample_count > 0
    assert Enum.any?(Map.keys(profile.folded), &String.contains?(&1, "IdkTest.SampleWorkload"))
  end

  test "trace flame cleans up its sampler when the profiled function raises" do
    links_before = Process.info(self(), :links)

    assert_raise RuntimeError, "profile target failed", fn ->
      Idk.TraceFlame.profile(
        fn -> raise "profile target failed" end,
        [IdkTest.SampleWorkload]
      )
    end

    assert Process.info(self(), :links) == links_before
  end

  test "emits telemetry around profile target work" do
    :telemetry.execute([:idk, :profile, :start], %{system_time: 1}, %{})
    assert Idk.parse_type("call_count") == {:ok, :call_count}
    :telemetry.execute([:idk, :profile, :stop], %{duration: 2}, %{})
  end

  test "runs a large Enum workload for profiler smoke tests" do
    assert Enum.map(1..100_000, &Function.identity/1) == Enum.to_list(1..100_000)
  end
end
