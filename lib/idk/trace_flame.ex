defmodule Idk.TraceFlame do
  @moduledoc false

  @timeout 30_000

  def profile(fun, modules, opts \\ []) when is_function(fun, 0) and is_list(modules) do
    modules = ensure_modules!(modules)
    interval_ms = Keyword.get(opts, :sample_interval, 1)
    owner = self()

    sampler =
      spawn_link(fn ->
        sampler_loop(owner, %{
          active: false,
          interval_ms: interval_ms,
          modules: MapSet.new(modules),
          pids: MapSet.new(),
          samples: %{},
          timer: nil
        })
      end)

    try do
      session = :trace.session_create(:idk, sampler, [])
      trigger = Keyword.get(opts, :trigger, :immediate)

      try do
        {result, trigger_info} = run_with_trigger(fun, session, sampler, trigger)
        stop_sampling(session, sampler)
        send(sampler, {:drain, session})

        receive do
          {:trace_flame, ^sampler, profile} ->
            profile =
              profile
              |> Map.put(:traced_modules, modules)
              |> Map.merge(trigger_info)

            {result, profile}
        after
          @timeout ->
            raise "timed out waiting for sampled flame data"
        end
      after
        :trace.session_destroy(session)
      end
    after
      Process.unlink(sampler)
      Process.exit(sampler, :kill)
    end
  end

  defp run_with_trigger(fun, session, sampler, :immediate) do
    start_sampling(session, sampler)

    try do
      {fun.(), %{trigger: :immediate}}
    after
      stop_sampling(session, sampler)
    end
  end

  defp run_with_trigger(fun, session, sampler, {:telemetry, start_event, stop_event}) do
    unless Code.ensure_loaded?(:telemetry) do
      raise "telemetry-triggered sampling requires the :telemetry application"
    end

    handler_id = "idk-trace-#{System.unique_integer([:positive])}"
    parent = self()
    handler = &__MODULE__.handle_telemetry_trigger/4
    config = {parent, session, sampler, start_event, stop_event}

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
      stop_sampling(session, sampler)
    end
  end

  def handle_telemetry_trigger(
        event,
        measurements,
        metadata,
        {parent, session, sampler, start_event, stop_event}
      ) do
    cond do
      event == start_event ->
        start_sampling(session, sampler)
        send(parent, {:trace_flame_telemetry, :start, event, measurements, metadata})

      event == stop_event ->
        send(parent, {:trace_flame_telemetry, :stop, event, measurements, metadata})
        stop_sampling(session, sampler)

      true ->
        :ok
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
      0 -> Enum.reverse(events)
    end
  end

  defp start_sampling(session, sampler) do
    :trace.process(session, self(), true, [:procs, :set_on_spawn, :monotonic_timestamp])
    send(sampler, {:start_sampling, self()})
  end

  defp stop_sampling(session, sampler) do
    :trace.process(session, :all, false, [:procs, :set_on_spawn])
    send(sampler, :stop_sampling)
  end

  defp ensure_modules!(modules) do
    Enum.map(modules, fn module ->
      case Code.ensure_loaded(module) do
        {:module, ^module} ->
          module

        {:error, reason} ->
          raise "could not load sampled module #{inspect(module)}: #{inspect(reason)}"
      end
    end)
  end

  defp sampler_loop(owner, state) do
    receive do
      {:start_sampling, pid} ->
        state = %{state | active: true, pids: MapSet.put(state.pids, pid)}
        sampler_loop(owner, state |> sample() |> schedule_sample())

      :stop_sampling ->
        sampler_loop(owner, cancel_sample(state))

      :sample_tick ->
        state = %{state | timer: nil}

        sampler_loop(
          owner,
          if(state.active, do: state |> sample() |> schedule_sample(), else: state)
        )

      {:trace_ts, _parent, :spawn, child, _mfa, _timestamp} ->
        sampler_loop(owner, %{state | pids: MapSet.put(state.pids, child)})

      {:trace_ts, pid, :exit, _reason, _timestamp} ->
        sampler_loop(owner, %{state | pids: MapSet.delete(state.pids, pid)})

      {:drain, session} ->
        reference = :trace.delivered(session, :all)
        drain_loop(owner, state, reference)

      _other ->
        sampler_loop(owner, state)
    end
  end

  defp schedule_sample(%{timer: nil} = state) do
    %{state | timer: Process.send_after(self(), :sample_tick, state.interval_ms)}
  end

  defp schedule_sample(state), do: state

  defp cancel_sample(%{timer: nil} = state), do: %{state | active: false}

  defp cancel_sample(state) do
    Process.cancel_timer(state.timer)
    %{state | active: false, timer: nil}
  end

  defp drain_loop(owner, state, reference) do
    receive do
      {:trace_ts, _parent, :spawn, child, _mfa, _timestamp} ->
        drain_loop(owner, %{state | pids: MapSet.put(state.pids, child)}, reference)

      {:trace_ts, pid, :exit, _reason, _timestamp} ->
        drain_loop(owner, %{state | pids: MapSet.delete(state.pids, pid)}, reference)

      {:trace_delivered, :all, ^reference} ->
        send(owner, {:trace_flame, self(), finish(state)})

      _other ->
        drain_loop(owner, state, reference)
    end
  end

  defp sample(state) do
    at = System.monotonic_time(:nanosecond)

    {pids, samples} =
      Enum.reduce(state.pids, {state.pids, state.samples}, fn pid, {pids, samples} ->
        case Process.info(pid, :current_stacktrace) do
          {:current_stacktrace, stacktrace} ->
            case relevant_stack(stacktrace, state.modules) do
              [] ->
                {pids, samples}

              stack ->
                sample = %{at: at, stack: stack}
                {pids, Map.update(samples, pid, [sample], &[sample | &1])}
            end

          nil ->
            {MapSet.delete(pids, pid), samples}
        end
      end)

    %{state | pids: pids, samples: samples}
  end

  defp relevant_stack(stacktrace, modules) do
    stack =
      stacktrace
      |> Enum.map(&format_frame/1)
      |> Enum.reverse()

    case Enum.find_index(stack, fn {module, _frame} -> MapSet.member?(modules, module) end) do
      nil -> []
      index -> stack |> Enum.drop(index) |> Enum.map(&elem(&1, 1))
    end
  end

  defp format_frame({module, function, arity, _location}) do
    {module, "#{inspect(module)}.#{function}/#{arity_value(arity)}"}
  end

  defp format_frame({module, function, arity}) do
    {module, "#{inspect(module)}.#{function}/#{arity_value(arity)}"}
  end

  defp arity_value(arity) when is_integer(arity), do: arity
  defp arity_value(args) when is_list(args), do: length(args)

  defp finish(state) do
    samples = Map.new(state.samples, fn {pid, entries} -> {pid, Enum.reverse(entries)} end)

    folded =
      Enum.reduce(samples, %{}, fn {_pid, entries}, folded ->
        Enum.reduce(entries, folded, fn %{stack: stack}, folded ->
          Map.update(folded, Enum.join(stack, ";"), 1, &(&1 + 1))
        end)
      end)

    %{
      folded: folded,
      sample_count:
        Enum.reduce(samples, 0, fn {_pid, entries}, count -> count + length(entries) end),
      sample_interval_ns: System.convert_time_unit(state.interval_ms, :millisecond, :nanosecond),
      samples: samples
    }
  end
end
