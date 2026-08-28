defmodule DemoApp.Workload do
  def run(size) do
    1..size
    |> Enum.chunk_every(1_000)
    |> Enum.map(&Task.async(fn -> aggregate(&1) end))
    |> Task.await_many()
    |> Enum.sum()
  end

  defp aggregate(values) do
    values
    |> Enum.map(&transform/1)
    |> Enum.filter(&(rem(&1, 3) == 0))
    |> Enum.sum()
  end

  defp transform(value) do
    value
    |> normalize()
    |> score()
  end

  defp normalize(value), do: rem(value * 17 + 11, 10_007)

  defp score(value) do
    Enum.reduce(1..1_000, value, fn factor, acc -> rem(acc * factor + value, 1_000_003) end)
  end
end
