defmodule ExUnitTProf.Report do
  @moduledoc false

  @headers %{
    call_count: "CALLS",
    call_time: "TIME",
    call_memory: "WORDS"
  }

  @doc """
  Renders the combined `:tprof.inspect/3` result returned by `ExUnitTProf.profile/2`.
  """
  def render(inspected, opts \\ []) do
    {type, total, rows} = normalize(inspected)
    limit = Keyword.get(opts, :limit, 50)
    test_args = Keyword.get(opts, :test_args, [])

    selected_rows = Enum.take(rows, limit)

    [
      "ExUnit tprof report",
      "====================",
      "",
      "Profile type: #{type}",
      "Test args: #{format_args(test_args)}",
      "Total #{measurement_name(type)}: #{total}",
      "Rows shown: #{length(selected_rows)} of #{length(rows)}",
      "",
      table(type, selected_rows),
      "",
      "Notes:",
      "- This is whole-run profiling around `mix test`; setup, factories, formatters, and ExUnit internals are included.",
      "- Profiling adds overhead and can perturb timings, scheduling, allocation, and process behavior.",
      "- `:tprof` is experimental in Erlang/OTP 27, so output shape and semantics may change.",
      "- For `call_time` and `call_memory`, `:tprof` traces the profiled process and spawned children by default; long-lived existing processes may be underrepresented."
    ]
    |> Enum.join("\n")
  end

  defp normalize(%{all: profile}), do: normalize(profile)
  defp normalize({type, total, rows}), do: {type, total, rows}

  defp table(_type, []) do
    "No tprof rows were collected."
  end

  defp table(type, rows) do
    measurement = Map.fetch!(@headers, type)

    header =
      pad("FUNCTION", 54) <>
        pad("CALLS", 12, :left) <>
        pad(measurement, 14, :left) <>
        pad("PER CALL", 14, :left) <>
        pad("%", 8, :left)

    separator = String.duplicate("-", String.length(header))

    body =
      Enum.map(rows, fn {module, {function, arity}, calls, value, per_call, percent} ->
        function_name = "#{inspect(module)}.#{function}/#{arity}"

        pad(function_name, 54) <>
          pad(format_number(calls), 12, :left) <>
          pad(format_number(value), 14, :left) <>
          pad(format_number(per_call), 14, :left) <>
          pad(format_number(percent), 8, :left)
      end)

    Enum.join([header, separator | body], "\n")
  end

  defp measurement_name(:call_count), do: "calls"
  defp measurement_name(:call_time), do: "time"
  defp measurement_name(:call_memory), do: "allocated words"

  defp format_args([]), do: "(entire test suite)"
  defp format_args(args), do: Enum.join(args, " ")

  defp format_number(value) when is_integer(value), do: Integer.to_string(value)

  defp format_number(value) when is_float(value) do
    :io_lib.format("~.2f", [value]) |> IO.iodata_to_binary()
  end

  defp pad(value, width, side \\ :right) do
    value = to_string(value)

    if String.length(value) > width do
      String.slice(value, 0, width - 3) <> "..."
    else
      padding = String.duplicate(" ", width - String.length(value))

      case side do
        :right -> value <> padding
        :left -> padding <> value
      end
    end
  end
end
