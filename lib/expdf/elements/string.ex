defmodule Expdf.ElementString do
  alias Expdf.Font

  defstruct [:val]

  def parse(content, offset \\ 0) do
    case Regex.named_captures(~r/^\s*\((?P<name>.*)/s, content) do
      nil -> false
      %{"name" => name} ->
        # Find next ')' not escaped.
        cur_start_pos = start_pos(name, 0, 0)

        # Extract string.
        name = binary_part(name, 0, cur_start_pos)
        pos = case :binary.match(content, "(") do
          :nomatch -> 0
          {pos, _} -> pos
        end
        offset = offset + pos + cur_start_pos + 2 # 2 for '(' and ')'
        name = name
               |> String.replace("\\\\", "\\")
               |> String.replace("\\", " ")
               |> String.replace("\\/", "/")
               |> String.replace("\(", "(")
               |> String.replace("\)", ")")
               |> String.replace("\\n", "\n")
               |> String.replace("\\r", "\r")
               |> String.replace("\\t", "\t")
               # Decode string.
               |> Font.decode_octal()
               |> Font.decode_entities()
               |> Font.decode_hexadecimal(false)
               |> Font.decode_unicode()
        {%__MODULE__{val: name}, offset}
    end
  end

  defp start_pos(name, cur_start_pos, start_search_end) do
    name_offset = binary_part(name, start_search_end, byte_size(name) - start_search_end)
    case :binary.match(name_offset, ")") do
      :nomatch -> cur_start_pos
      {pos, _} ->
        cur_extract = binary_part(name, 0, pos)
        %{"escape" => escape} = Regex.named_captures(~r/(?P<escape>[\\]*)$/s, cur_extract)
        if rem(String.length(escape), 2) == 0, do: pos, else: start_pos(name, pos, pos + 1)
    end
  end

end
