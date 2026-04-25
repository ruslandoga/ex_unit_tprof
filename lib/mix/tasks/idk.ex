defmodule Mix.Tasks.Idk do
  @moduledoc """
  Dispatches Idk profiling subcommands.

      mix idk test test/path_test.exs:42 --type call_memory
  """

  use Mix.Task

  @shortdoc "Profiles BEAM code paths when you do not know why they are slow"

  @impl Mix.Task
  def run(["test" | args]) do
    Mix.Task.run("idk.test", args)
  end

  def run([]) do
    Mix.raise("Expected an Idk subcommand, for example: mix idk test test/path_test.exs:42")
  end

  def run([unknown | _args]) do
    Mix.raise("Unknown Idk subcommand #{inspect(unknown)}. Expected: test")
  end
end
