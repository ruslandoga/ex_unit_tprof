defmodule Idk.TraceFlame do
  @moduledoc false

  @timeout 30_000

  def profile(fun, modules, opts \\ []) when is_function(fun, 0) and is_list(modules) do
    owner = self()
    tracer = spawn_link(fn -> tracer_loop(owner, %{}) end)

    matched = enable_patterns(modules)
    trigger = Keyword.get(opts, :trigger, :immediate)

    try do
      {result, trigger_info} = run_with_trigger(fun, tracer, trigger)
      disable_patterns(modules)
      send(tracer, {:stop, self()})

      receive do
        {:trace_flame, ^tracer, profile} ->
          profile =
            profile
            |> Map.put(:matched_functions, matched)
            |> Map.merge(trigger_info)

          {result, profile}
      after
        @timeout ->
          raise "timed out waiting for trace flame data"
      end
    after
      :erlang.trace(self(), false, [:call, :return_to, :procs, :set_on_spawn])
      disable_patterns(modules)
    end
  end

  defp run_with_trigger(fun, tracer, :immediate) do
    enable_process_trace(tracer)

    try do
      {fun.(), %{trigger: :immediate}}
    after
      disable_process_trace()
    end
  end

  defp run_with_trigger(fun, tracer, {:telemetry, start_event, stop_event}) do
    unless Code.ensure_loaded?(:telemetry) do
      raise "telemetry-triggered tracing requires the :telemetry application"
    end

    handler_id = "idk-trace-#{System.unique_integer([:positive])}"
    parent = self()

    handler = &__MODULE__.handle_telemetry_trigger/4
    config = {parent, tracer, start_event, stop_event}

    :ok =
      apply(:telemetry, :attach_many, [handler_id, [start_event, stop_event], handler, config])

    try do
      result = fun.()

      {
        result,
        %{
          trigger: :telemetry,
          telemetry_start_event: start_event,
          telemetry_stop_event: stop_event,
          telemetry_events: collect_telemetry_events([])
        }
      }
    after
      apply(:telemetry, :detach, [handler_id])
      disable_process_trace()
    end
  end

  defp collect_telemetry_events(events) do
    receive do
      {:trace_flame_telemetry, phase, event, measurements, metadata} ->
        collect_telemetry_events([
          %{
            phase: phase,
            event: event,
            measurements: measurements,
            metadata: metadata
          }
          | events
        ])
    after
      0 ->
        Enum.reverse(events)
    end
  end

  def handle_telemetry_trigger(
        event,
        measurements,
        metadata,
        {parent, tracer, start_event, stop_event}
      ) do
    cond do
      event == start_event ->
        enable_process_trace(tracer)
        send(parent, {:trace_flame_telemetry, :start, event, measurements, metadata})

      event == stop_event ->
        send(parent, {:trace_flame_telemetry, :stop, event, measurements, metadata})
        disable_process_trace()

      true ->
        :ok
    end
  end

  defp enable_process_trace(tracer) do
    :erlang.trace(self(), true, [
      :call,
      :return_to,
      :procs,
      :set_on_spawn,
      :timestamp,
      {:tracer, tracer}
    ])
  end

  defp disable_process_trace do
    :erlang.trace(self(), false, [:call, :return_to, :procs, :set_on_spawn])
  end

  defp enable_patterns(modules) do
    Enum.reduce(modules, 0, fn module, acc ->
      acc + :erlang.trace_pattern({module, :_, :_}, true, [:local])
    end)
  end

  defp disable_patterns(modules) do
    Enum.each(modules, fn module ->
      :erlang.trace_pattern({module, :_, :_}, false, [:local])
    end)
  end

  defp tracer_loop(owner, state) do
    receive do
      {:trace_ts, pid, :call, mfa, timestamp} ->
        tracer_loop(owner, call(state, pid, mfa, timestamp))

      {:trace_ts, pid, :return_to, mfa, timestamp} ->
        tracer_loop(owner, return_to(state, pid, mfa, timestamp))

      {:stop, caller} ->
        send(owner, {:trace_flame, self(), finish(state)})
        send(caller, {:trace_flame_stopped, self()})

      _other ->
        tracer_loop(owner, state)
    end
  end

  defp call(state, pid, mfa, timestamp) do
    frame = format_mfa(mfa)
    stack = Map.get(state, {:stack, pid}, [])
    new_stack = [frame | stack]
    folded_key = new_stack |> Enum.reverse() |> Enum.join(";")
    started_at = monotonic_us(timestamp)

    state
    |> Map.put({:stack, pid}, new_stack)
    |> Map.update(
      :folded,
      %{folded_key => 1},
      &Map.update(&1, folded_key, 1, fn count -> count + 1 end)
    )
    |> Map.update(
      :events,
      [{:open, pid, frame, started_at}],
      &[{:open, pid, frame, started_at} | &1]
    )
  end

  defp return_to(state, pid, mfa, timestamp) do
    case Map.get(state, {:stack, pid}, []) do
      [] ->
        state

      [_frame | rest] ->
        at = monotonic_us(timestamp)

        state
        |> Map.put({:stack, pid}, rest)
        |> Map.update(
          :events,
          [{:close, pid, format_mfa(mfa), at}],
          &[{:close, pid, format_mfa(mfa), at} | &1]
        )
    end
  end

  defp finish(state) do
    %{
      folded: Map.get(state, :folded, %{}),
      events: state |> Map.get(:events, []) |> Enum.reverse()
    }
  end

  defp format_mfa({module, function, args}) when is_list(args) do
    "#{inspect(module)}.#{function}/#{length(args)}"
  end

  defp format_mfa({module, function, arity}) do
    "#{inspect(module)}.#{function}/#{arity}"
  end

  defp monotonic_us({mega, sec, micro}) do
    (mega * 1_000_000 + sec) * 1_000_000 + micro
  end
end
