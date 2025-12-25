defmodule Mxc.CLI.Output do
  @moduledoc """
  Output formatting utilities for the CLI.
  """

  @doc """
  Renders data in the specified format.
  """
  def render(data, :json, _formatter) do
    data
    |> Jason.encode!(pretty: true)
    |> IO.puts()
  end

  def render(data, :table, formatter) do
    formatter.(data)
    |> IO.puts()
  end

  def render(data, _format, formatter) do
    render(data, :table, formatter)
  end

  @doc """
  Formats a table with headers and rows.
  """
  def table(headers, rows) do
    # Calculate column widths
    all_rows = [headers | rows]

    widths =
      all_rows
      |> Enum.zip_reduce([], fn col_values, acc ->
        max_width = col_values |> Enum.map(&to_string/1) |> Enum.map(&String.length/1) |> Enum.max()
        [max_width | acc]
      end)
      |> Enum.reverse()

    # Format header
    header_line = format_row(headers, widths)
    separator = widths |> Enum.map(&String.duplicate("-", &1)) |> Enum.join("-+-")

    # Format rows
    data_lines = Enum.map(rows, &format_row(&1, widths))

    [header_line, separator | data_lines]
    |> Enum.join("\n")
  end

  @doc """
  Prints a success message.
  """
  def success(message) do
    IO.puts(IO.ANSI.green() <> "✓ " <> message <> IO.ANSI.reset())
  end

  @doc """
  Prints an error message to stderr.
  """
  def error(message) do
    IO.puts(:stderr, IO.ANSI.red() <> "✗ " <> message <> IO.ANSI.reset())
  end

  @doc """
  Prints a warning message.
  """
  def warning(message) do
    IO.puts(IO.ANSI.yellow() <> "⚠ " <> message <> IO.ANSI.reset())
  end

  # Private

  defp format_row(values, widths) do
    values
    |> Enum.zip(widths)
    |> Enum.map(fn {value, width} ->
      String.pad_trailing(to_string(value), width)
    end)
    |> Enum.join(" | ")
  end
end
