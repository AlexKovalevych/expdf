defmodule Expdf.ElementStruct do
  alias Expdf.{
    ElementParser,
    Header
  }

  defstruct [:val]

  @derive [Expdf.Element]

  def parse(content, parser, offset \\ 0) do
    case Regex.named_captures(~r/^\s*<<(?P<struct>.*)/is, content) do
      nil -> false
      %{"struct" => struct} ->
        matches = Regex.scan(~r/(.*?)(<<|>>)/s, String.trim(content))
                  |> Enum.map(fn match -> hd(match) end)
        sub = Enum.reduce_while(matches, {"", 0}, fn part, {sub, level} ->
          new_sub = "#{sub}#{part}"
          i = if String.match?(~r/<</, part), do: 1, else: -1
          level = level + i
          if level <= 0, do: {:halt, new_sub}, else: {:cont, {new_sub, level}}
        end)

        {pos, _} = :binary.match(content, "<<")
        offset = offset + pos + byte_size(String.trim_trailing(sub))

        # Removes '<<' and '>>'.
        sub = String.trim(String.replace(~r/^\s*<<(.*)>>\s*$/s, "\\1", sub))
        elements = ElementParser.parse(sub, parser, 0)
        {%Header{elements: elements}, offset}
    end
  end
end
