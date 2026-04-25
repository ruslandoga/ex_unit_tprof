defmodule ExUnitTProf.FlameWriter do
  @moduledoc false

  def write_all!(output_dir, profile) do
    File.mkdir_p!(output_dir)

    folded_path = Path.join(output_dir, "stacks.folded")
    speedscope_path = Path.join(output_dir, "speedscope.json")
    svg_path = Path.join(output_dir, "flamegraph.svg")

    File.write!(folded_path, folded(profile.folded))
    File.write!(speedscope_path, speedscope(profile.events))
    File.write!(svg_path, svg(profile.folded))

    %{
      folded: folded_path,
      speedscope: speedscope_path,
      svg: svg_path
    }
  end

  def folded(folded) do
    folded
    |> Enum.sort_by(fn {stack, _count} -> stack end)
    |> Enum.map_join("\n", fn {stack, count} -> "#{stack} #{count}" end)
    |> then(fn text -> text <> "\n" end)
  end

  def speedscope(events) do
    frames =
      events
      |> Enum.flat_map(fn
        {:open, _pid, frame, _at} -> [frame]
        {:close, _pid, frame, _at} -> [frame]
      end)
      |> Enum.uniq()

    frame_indexes = frames |> Enum.with_index() |> Map.new()
    start_time = events |> Enum.map(&elem(&1, 3)) |> Enum.min(fn -> 0 end)

    converted_events =
      Enum.map(events, fn
        {:open, _pid, frame, at} ->
          %{type: "O", frame: Map.fetch!(frame_indexes, frame), at: at - start_time}

        {:close, _pid, _frame, at} ->
          %{type: "C", at: at - start_time}
      end)

    data = %{
      "$schema": "https://www.speedscope.app/file-format-schema.json",
      shared: %{
        frames: Enum.map(frames, &%{name: &1})
      },
      profiles: [
        %{
          type: "evented",
          name: "mix test.tprof trace",
          unit: "microseconds",
          startValue: 0,
          endValue: duration(converted_events),
          events: converted_events
        }
      ],
      activeProfileIndex: 0
    }

    ExUnitTProf.FlameWriter.JasonLike.encode!(data) <> "\n"
  end

  def svg(folded) do
    width = 1200
    frame_height = 18
    root = build_tree(folded)
    max_depth = tree_depth(root)
    total = max(root.count, 1)
    height = max(90, 54 + (max_depth + 1) * frame_height)

    frames = render_children(root.children, 0, 40, width - 80, total, frame_height)

    """
    <svg xmlns="http://www.w3.org/2000/svg" width="#{width}" height="#{height}" viewBox="0 0 #{width} #{height}">
      <style>
        text { font-family: Menlo, Consolas, monospace; fill: #24292f; }
        rect { shape-rendering: crispEdges; stroke: #ffffff; stroke-width: .5; }
      </style>
      <rect width="100%" height="100%" fill="#ffffff" />
      <text x="12" y="24" font-size="16" font-weight="700">ExUnit trace flamegraph</text>
      #{frames}
    </svg>
    """
  end

  defp build_tree(folded) do
    Enum.reduce(folded, %{name: "root", count: 0, children: %{}}, fn {stack, count}, root ->
      frames = String.split(stack, ";", trim: true)

      root
      |> update_in([:count], &(&1 + count))
      |> put_stack(frames, count)
    end)
  end

  defp put_stack(node, [], _count), do: node

  defp put_stack(node, [frame | rest], count) do
    child = get_in(node, [:children, frame]) || %{name: frame, count: 0, children: %{}}

    child =
      child
      |> update_in([:count], &(&1 + count))
      |> put_stack(rest, count)

    put_in(node, [:children, frame], child)
  end

  defp tree_depth(%{children: children}) when map_size(children) == 0, do: 0

  defp tree_depth(%{children: children}) do
    1 + (children |> Map.values() |> Enum.map(&tree_depth/1) |> Enum.max())
  end

  defp render_children(children, depth, x, width, total, frame_height) do
    children
    |> Map.values()
    |> Enum.sort_by(& &1.name)
    |> Enum.reduce({"", x}, fn child, {svg, cursor} ->
      child_width = width * child.count / total
      current = render_frame(child, depth, cursor, child_width, frame_height)

      nested =
        render_children(child.children, depth + 1, cursor, child_width, child.count, frame_height)

      {svg <> current <> nested, cursor + child_width}
    end)
    |> elem(0)
  end

  defp render_frame(frame, depth, x, width, frame_height) do
    y = 44 + depth * frame_height
    text = truncate(frame.name, max(0, trunc(width / 7) - 2))

    """
    <g>
      <title>#{escape(frame.name)} #{frame.count}</title>
      <rect x="#{round_coord(x)}" y="#{y}" width="#{round_coord(width)}" height="#{frame_height - 2}" fill="#{color(depth)}" />
      <text x="#{round_coord(x + 3)}" y="#{y + 12}" font-size="11">#{escape(text)}</text>
    </g>
    """
  end

  defp duration([]), do: 0
  defp duration(events), do: events |> Enum.map(& &1.at) |> Enum.max()

  defp color(index) do
    Enum.at(["#d9480f", "#f08c00", "#2b8a3e", "#1971c2", "#862e9c"], rem(index, 5))
  end

  defp round_coord(value) when is_integer(value), do: value
  defp round_coord(value) when is_float(value), do: Float.round(value, 2)

  defp escape(value) do
    value
    |> to_string()
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end

  defp truncate(_value, limit) when limit <= 0, do: ""

  defp truncate(value, limit) do
    if String.length(value) > limit do
      String.slice(value, 0, max(limit - 2, 0)) <> ".."
    else
      value
    end
  end
end

defmodule ExUnitTProf.FlameWriter.JasonLike do
  @moduledoc false

  def encode!(value) when is_map(value) do
    entries =
      value
      |> Enum.map(fn {key, val} -> encode!(to_string(key)) <> ":" <> encode!(val) end)
      |> Enum.join(",")

    "{" <> entries <> "}"
  end

  def encode!(value) when is_list(value) do
    "[" <> Enum.map_join(value, ",", &encode!/1) <> "]"
  end

  def encode!(value) when is_binary(value) do
    escaped =
      value
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")
      |> String.replace("\n", "\\n")

    "\"" <> escaped <> "\""
  end

  def encode!(value) when is_integer(value), do: Integer.to_string(value)
  def encode!(value) when is_float(value), do: Float.to_string(value)
  def encode!(true), do: "true"
  def encode!(false), do: "false"
  def encode!(nil), do: "null"
end
