defprotocol Expdf.Element do
  @doc """
  Get content of element
  """
  def content(element)

end

defimpl Expdf.Element, for: Any do
  def content(%{val: val}), do: val
end

defmodule Expdf.ElementParser do
  @formats [
    "4": "%Y",
    "6": "%Y%m",
    "8": "%Y%m%d",
    "10": "%Y%m%d%H",
    "12": "%Y%m%d%H%M",
    "14": "%Y%m%d%H%M%S",
    "15": "%Y%m%d%H%M%S%Z",
    "17": "%Y%m%d%H%M%S%z",
    "18": "%Y%m%d%H%M%S%z",
    "19": "%Y%m%d%H%M%S%z",
  ]

  def parse(type, content, offset \\ 0) do
    parse_type(type, content, offset)
  end

  defp parse_type(:date, content, offset) do
    case Regex.named_captures(~r/^\s*\(D\:(?P<name>.*?)\)/s, content) do
      nil -> false
      %{"name" => match_name} ->
        name = String.replace(match_name, "'", "")
        if Regex.match?(~r/^\d{4}(\d{2}(\d{2}(\d{2}(\d{2}(\d{2}(Z(\d{2,4})?|[\+-]?\d{2}(\d{2})?)?)?)?)?)?)?$/, name) do
          pos = case :binary.match(name, "Z") do
            {pos, _} -> pos
            :nomatch -> false
          end
          name = cond do
            pos -> binary_part(name, 0, pos + 1)
            byte_size(name) == 18 && Regex.match?(~r/[^\+-]0000$/, name) -> binary_part(name, 0, byte_size(name) - 4)
            true -> name
          end
          format = @formats[name |> byte_size |> to_string |> String.to_atom]
          case Timex.parse(name, format, :strftime) do
            {:ok, date} ->
              pos = case :binary.match(content, "(D:") do
                :nomatch -> 0
                {pos, _} -> pos
              end
              offset = offset + pos + byte_size(match_name) + 4 # 1 for '(D:' and ')'
              [:date, date, offset]
            {:error, _} -> false
          end
        else
          if Regex.match?(~r/^\d{1,2}-\d{1,2}-\d{4},?\s+\d{2}:\d{2}:\d{2}[\+-]\d{4}$/, name) do
            name = String.replace(name, ",", "")
            format = "{M}-{D}-{YYYY} {h24}:{m}:{s}{Z}"
            case Timex.parse(name, format, :strftime) do
              {:ok, date} ->
                pos = case :binary.match(content, "(D:") do
                  :nomatch -> 0
                  {pos, _} -> pos
                end
                offset = offset + pos + byte_size(match_name) + 4 # 1 for '(D:' and ')'
                [:date, date, offset]
              {:error, _} -> false
            end
          else
            false
          end
        end
    end
  end

  defp parse_type(:string, content, offset) do
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
        [:string, name, offset]
    end
  end

  #def parse(content, document, position, only_values \\ false) do
  #end

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
