defmodule Expdf.ElementArray do
  alias Expdf.ElementParser

  defstruct [:val]

  @derive [Expdf.Element]

  def parse(content, parser, offset \\ 0) do
    case Regex.named_captures(~r/^\s*\[(?P<array>.*)/is, content) do
      nil -> false
      %{"array" => array} ->
        matches = Regex.scan(~r/(.*?)(\[|\])/s, String.trim(content))
        |> Enum.map(fn match -> hd(match) end)
        sub = Enum.reduce_while(matches, {"", 0}, fn part, {sub, level} ->
          new_sub = "#{sub}#{part}"
          i = if String.match?(~r/\[/, part), do: 1, else: -1
          level = level + i
          if level <= 0, do: {:halt, new_sub}, else: {:cont, {new_sub, level}}
        end)

        # Removes 1 level [ and ].
        sub = String.trim(sub)
        sub = String.slice(sub, 1..String.length(sub) - 2)
        values = ElementParser.parse(sub, parser, 0, true)
        offset = case :binary.match(content, "[") do
          {pos, 1} -> offset + pos + 1
          :nomatch -> offset
        end

        # Find next ']' position
        offset = offset + String.length(sub) + 1
        {%__MODULE__{val: values}, offset}
    end
  end

end
