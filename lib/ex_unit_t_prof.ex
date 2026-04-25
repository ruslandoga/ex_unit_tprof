defmodule ExUnitTProf do
  @compile {:no_warn_undefined, {:tprof, :profile, 2}}
  @compile {:no_warn_undefined, {:tprof, :inspect, 3}}

  @moduledoc """
  Small helpers for profiling ExUnit runs with Erlang/OTP's experimental
  `:tprof` profiler.
  """

  @valid_types [:call_count, :call_time, :call_memory]

  @type profile_type :: :call_count | :call_time | :call_memory

  @doc """
  Returns true when `:tprof` is available in the current Erlang/OTP runtime.
  """
  def available? do
    Code.ensure_loaded?(:tprof)
  end

  @doc """
  Parses a profiling type accepted by `mix test.tprof`.
  """
  def parse_type("call_count"), do: {:ok, :call_count}
  def parse_type("call_time"), do: {:ok, :call_time}
  def parse_type("call_memory"), do: {:ok, :call_memory}
  def parse_type(type) when is_binary(type), do: {:error, {:invalid_type, type}}

  @doc """
  Profiles the supplied zero-arity function with `:tprof`.

  The return value is `{fun_result, raw_profile_data, inspected_profile_data}`.
  `raw_profile_data` is suitable for `:erlang.term_to_binary/1` persistence.
  """
  def profile(type, fun) when type in @valid_types and is_function(fun, 0) do
    unless available?() do
      raise "Erlang/OTP :tprof is not available; use Erlang/OTP 27 or newer"
    end

    options = %{
      type: type,
      report: :return
    }

    {result, profile_data} = :tprof.profile(fun, options)
    inspected = :tprof.inspect(profile_data, :total, {:measurement, :descending})

    {result, profile_data, inspected}
  end
end
