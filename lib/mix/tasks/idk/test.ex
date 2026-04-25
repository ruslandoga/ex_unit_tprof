defmodule Mix.Tasks.Idk.Test do
  @moduledoc """
  Profiles an ExUnit run with Erlang/OTP's experimental `:tprof`.

      mix idk test test/path_test.exs:42 --type call_memory

  The task forwards normal test file and line arguments to `mix test`, profiles
  the whole run, and writes:

    * `_build/test/idk/report.txt` - a readable combined-function report
    * `_build/test/idk/profile.etf` - raw `:tprof` data as an Erlang term binary

  Options:

    * `--type call_count|call_time|call_memory` - profiling mode, defaults to
      `call_count`
    * `--report PATH` - text report path
    * `--artifact PATH` - machine-readable raw profile artifact path
    * `--limit N` - maximum report rows, defaults to 50
    * `--flamegraph` - use an experimental `:erlang.trace/3` workflow instead
      of `:tprof` and write folded stacks, Speedscope JSON, and an SVG preview
    * `--flame-dir PATH` - trace flame output directory
    * `--trace-module Module` - module to trace in flamegraph mode; can be
      passed multiple times
    * `--trace-start-event EVENT` - telemetry event that starts tracing
    * `--trace-stop-event EVENT` - telemetry event that stops tracing

  Limitations:

    * This is whole-run profiling. Setup, factories, formatters, and ExUnit
      internals are included in the measurements.
    * Profiling adds overhead and can perturb timings, scheduling, allocation,
      and process behavior.
    * `:tprof` is experimental in Erlang/OTP 27.
  """

  use Mix.Task

  @shortdoc "Profiles mix test with Erlang/OTP :tprof"
  @requirements ["app.config", "app.start"]
  @default_type :call_count

  @impl Mix.Task
  def run(args) do
    {opts, test_args} = parse!(args)

    if opts.flamegraph do
      run_trace_flame(opts, test_args)
    else
      run_tprof(opts, test_args)
    end
  end

  defp run_tprof(opts, test_args) do
    unless Idk.available?() do
      Mix.raise("Erlang/OTP :tprof is not available; use Erlang/OTP 27 or newer")
    end

    Mix.shell().info("Profiling `mix test #{Enum.join(test_args, " ")}` with :tprof #{opts.type}")

    {result, raw_profile, inspected_profile} =
      Idk.profile(opts.type, fn ->
        Mix.Task.reenable("test")
        Mix.Task.run("test", test_args)
      end)

    write_report!(opts.report, inspected_profile, opts.limit, test_args)
    write_artifact!(opts.artifact, raw_profile)

    Mix.shell().info("Wrote tprof report to #{opts.report}")
    Mix.shell().info("Wrote raw tprof artifact to #{opts.artifact}")

    result
  end

  defp run_trace_flame(opts, test_args) do
    Mix.shell().info("Tracing `mix test #{Enum.join(test_args, " ")}` for flamegraph artifacts")

    modules = trace_modules(opts)
    trigger = trace_trigger(opts)

    {result, profile} =
      Idk.TraceFlame.profile(
        fn ->
          Mix.Task.reenable("test")
          Mix.Task.run("test", test_args)
        end,
        modules,
        trigger: trigger
      )

    paths = Idk.FlameWriter.write_all!(opts.flame_dir, profile)

    Mix.shell().info("Wrote folded stacks to #{paths.folded}")
    Mix.shell().info("Wrote Speedscope profile to #{paths.speedscope}")
    Mix.shell().info("Wrote SVG preview to #{paths.svg}")
    Mix.shell().info("Trace modules: #{Enum.map_join(modules, ", ", &inspect/1)}")
    Mix.shell().info("Matched #{profile.matched_functions} functions")
    print_trigger_info(profile)

    result
  end

  def parse!(args) do
    {parsed, test_args} = consume_options(args, [], [])

    type = parse_type!(Keyword.get(parsed, :type, Atom.to_string(@default_type)))
    output_dir = Path.join(Mix.Project.build_path(), "idk")

    opts = %{
      type: type,
      report: Keyword.get(parsed, :report, Path.join(output_dir, "report.txt")),
      artifact: Keyword.get(parsed, :artifact, Path.join(output_dir, "profile.etf")),
      limit: Keyword.get(parsed, :limit, 50),
      flamegraph: Keyword.get(parsed, :flamegraph, false),
      flame_dir: Keyword.get(parsed, :flame_dir, Path.join(output_dir, "flame")),
      trace_modules: Keyword.get_values(parsed, :trace_module),
      trace_start_event: Keyword.get(parsed, :trace_start_event),
      trace_stop_event: Keyword.get(parsed, :trace_stop_event)
    }

    if opts.limit < 1 do
      Mix.raise("--limit must be greater than 0")
    end

    {opts, test_args}
  end

  defp consume_options([], parsed, test_args) do
    {Enum.reverse(parsed), Enum.reverse(test_args)}
  end

  defp consume_options(["--" | rest], parsed, test_args) do
    {Enum.reverse(parsed), Enum.reverse(test_args) ++ rest}
  end

  defp consume_options(["--type"], _parsed, _test_args), do: Mix.raise("--type requires a value")

  defp consume_options(["--report"], _parsed, _test_args),
    do: Mix.raise("--report requires a value")

  defp consume_options(["--artifact"], _parsed, _test_args),
    do: Mix.raise("--artifact requires a value")

  defp consume_options(["--limit"], _parsed, _test_args),
    do: Mix.raise("--limit requires a value")

  defp consume_options(["--flame-dir"], _parsed, _test_args),
    do: Mix.raise("--flame-dir requires a value")

  defp consume_options(["--trace-module"], _parsed, _test_args),
    do: Mix.raise("--trace-module requires a value")

  defp consume_options(["--trace-start-event"], _parsed, _test_args),
    do: Mix.raise("--trace-start-event requires a value")

  defp consume_options(["--trace-stop-event"], _parsed, _test_args),
    do: Mix.raise("--trace-stop-event requires a value")

  defp consume_options(["--flamegraph" | rest], parsed, test_args) do
    consume_options(rest, [{:flamegraph, true} | parsed], test_args)
  end

  defp consume_options(["--flame-dir", value | rest], parsed, test_args) do
    consume_options(rest, [{:flame_dir, value} | parsed], test_args)
  end

  defp consume_options(["--flame-dir=" <> value | rest], parsed, test_args) do
    consume_options(rest, [{:flame_dir, value} | parsed], test_args)
  end

  defp consume_options(["--trace-module", value | rest], parsed, test_args) do
    consume_options(rest, [{:trace_module, value} | parsed], test_args)
  end

  defp consume_options(["--trace-module=" <> value | rest], parsed, test_args) do
    consume_options(rest, [{:trace_module, value} | parsed], test_args)
  end

  defp consume_options(["--trace-start-event", value | rest], parsed, test_args) do
    consume_options(rest, [{:trace_start_event, value} | parsed], test_args)
  end

  defp consume_options(["--trace-start-event=" <> value | rest], parsed, test_args) do
    consume_options(rest, [{:trace_start_event, value} | parsed], test_args)
  end

  defp consume_options(["--trace-stop-event", value | rest], parsed, test_args) do
    consume_options(rest, [{:trace_stop_event, value} | parsed], test_args)
  end

  defp consume_options(["--trace-stop-event=" <> value | rest], parsed, test_args) do
    consume_options(rest, [{:trace_stop_event, value} | parsed], test_args)
  end

  defp consume_options(["--type", value | rest], parsed, test_args) do
    consume_options(rest, [{:type, value} | parsed], test_args)
  end

  defp consume_options(["--report", value | rest], parsed, test_args) do
    consume_options(rest, [{:report, value} | parsed], test_args)
  end

  defp consume_options(["--artifact", value | rest], parsed, test_args) do
    consume_options(rest, [{:artifact, value} | parsed], test_args)
  end

  defp consume_options(["--limit", value | rest], parsed, test_args) do
    case Integer.parse(value) do
      {limit, ""} -> consume_options(rest, [{:limit, limit} | parsed], test_args)
      _ -> Mix.raise("--limit must be an integer")
    end
  end

  defp consume_options(["--type=" <> value | rest], parsed, test_args) do
    consume_options(rest, [{:type, value} | parsed], test_args)
  end

  defp consume_options(["--report=" <> value | rest], parsed, test_args) do
    consume_options(rest, [{:report, value} | parsed], test_args)
  end

  defp consume_options(["--artifact=" <> value | rest], parsed, test_args) do
    consume_options(rest, [{:artifact, value} | parsed], test_args)
  end

  defp consume_options(["--limit=" <> value | rest], parsed, test_args) do
    consume_options(["--limit", value | rest], parsed, test_args)
  end

  defp consume_options([arg | rest], parsed, test_args) do
    consume_options(rest, parsed, [arg | test_args])
  end

  defp parse_type!(type) do
    case Idk.parse_type(type) do
      {:ok, type} ->
        type

      {:error, _} ->
        Mix.raise("--type must be one of: call_count, call_time, call_memory")
    end
  end

  defp write_report!(path, inspected_profile, limit, test_args) do
    File.mkdir_p!(Path.dirname(path))

    File.write!(
      path,
      Idk.Report.render(inspected_profile, limit: limit, test_args: test_args) <> "\n"
    )
  end

  defp write_artifact!(path, raw_profile) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, :erlang.term_to_binary(raw_profile))
  end

  defp trace_modules(%{trace_modules: []}) do
    prefix = Mix.Project.config()[:app] |> Atom.to_string() |> Macro.camelize()

    :code.all_loaded()
    |> Enum.map(&elem(&1, 0))
    |> Enum.filter(
      &(module_prefix(&1) == prefix or String.starts_with?(module_prefix(&1), prefix <> "."))
    )
  end

  defp trace_modules(%{trace_modules: modules}) do
    Enum.map(modules, fn module ->
      module
      |> String.trim_leading("Elixir.")
      |> String.split(".")
      |> Module.concat()
    end)
  end

  defp module_prefix(module) do
    module
    |> Atom.to_string()
    |> String.trim_leading("Elixir.")
  end

  defp trace_trigger(%{trace_start_event: nil, trace_stop_event: nil}), do: :immediate

  defp trace_trigger(%{trace_start_event: start_event, trace_stop_event: stop_event})
       when is_binary(start_event) and is_binary(stop_event) do
    {:telemetry, parse_event!(start_event), parse_event!(stop_event)}
  end

  defp trace_trigger(_opts) do
    Mix.raise("--trace-start-event and --trace-stop-event must be provided together")
  end

  defp parse_event!(event) do
    event
    |> String.split([",", "."], trim: true)
    |> Enum.map(fn segment ->
      segment
      |> String.trim()
      |> String.to_atom()
    end)
  end

  defp print_trigger_info(%{trigger: :telemetry} = profile) do
    Mix.shell().info(
      "Telemetry trigger: #{format_event(profile.telemetry_start_event)} -> #{format_event(profile.telemetry_stop_event)}"
    )

    Mix.shell().info("Telemetry trigger events seen: #{length(profile.telemetry_events)}")
  end

  defp print_trigger_info(_profile), do: :ok

  defp format_event(event), do: Enum.join(event, ".")
end
