defmodule Expdf.Element do
  alias Expdf.Header
  alias Expdf.Font

  @date_formats [
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

  #def content(:font_TrueType, header, content) do
  #end

  def content(nil), do: ""

  def content({:string, content}), do: content

  def content({:name, content}), do: content

  def content({:date, content}), do: content

  def details({:object, header}, deep \\ true) do
    Header.get_details(header, deep)
  end

  def details({_, value}, _) do
    to_string(value)
  end

  def parse_all(content, offset, only_values? \\ false) when is_binary(content) do
    #do {
        #$old_position = $position;

        #if (!$only_values) {
            #if (!preg_match('/^\s*(?P<name>\/[A-Z0-9\._]+)(?P<value>.*)/si', substr($content, $position), $match)) {
                #break;
            #} else {
                #$name     = ltrim($match['name'], '/');
                #$value    = $match['value'];
                #$position = strpos($content, $value, $position + strlen($match['name']));
            #}
        #} else {
            #$name  = count($values);
            #$value = substr($content, $position);
        #}

        #if ($element = ElementName::parse($value, $document, $position)) {
            #$values[$name] = $element;
        #} elseif ($element = ElementXRef::parse($value, $document, $position)) {
            #$values[$name] = $element;
        #} elseif ($element = ElementNumeric::parse($value, $document, $position)) {
            #$values[$name] = $element;
        #} elseif ($element = ElementStruct::parse($value, $document, $position)) {
            #$values[$name] = $element;
        #} elseif ($element = ElementBoolean::parse($value, $document, $position)) {
            #$values[$name] = $element;
        #} elseif ($element = ElementNull::parse($value, $document, $position)) {
            #$values[$name] = $element;
        #} elseif ($element = ElementDate::parse($value, $document, $position)) {
            #$values[$name] = $element;
        #} elseif ($element = ElementString::parse($value, $document, $position)) {
            #$values[$name] = $element;
        #} elseif ($element = ElementHexa::parse($value, $document, $position)) {
            #$values[$name] = $element;
        #} elseif ($element = ElementArray::parse($value, $document, $position)) {
            #$values[$name] = $element;
        #} else {
            #$position = $old_position;
            #break;
        #}
    #} while ($position < strlen($content));

    #return $values;
  end

  def parse(type, content, offset \\ 0) when is_atom(type) do
    parse_type(type, content, offset)
  end

  defp parse_array(:array, content, offset) do
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
        values = parse_all(sub, 0, true)
        offset = case :binary.match(content, "[") do
          {pos, 1} -> offset + pos + 1
          :nomatch -> offset
        end

        # Find next ']' position
        offset = offset + String.length(sub) + 1
        {:array, values}
    end
  end

  defp parse_type(:struct, content, offset) do
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
        elements = parse_all(sub, 0)
        {:header, %Header{elements: elements}}
    end
  end

  defp parse_type(:name, content, offset) do
    case Regex.named_captures(~r/^\s*\/(?P<name>[A-Z0-9\-\+,#\.]+)/is, content) do
      nil -> false
      %{"name" => name} ->
        {pos, _} = :binary.match(content, name)
        offset = offset + pos + byte_size(name)
        {:name, Font.decode_entities(name)}
    end
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
          format = @date_formats[name |> byte_size |> to_string |> String.to_atom]
          case Timex.parse(name, format, :strftime) do
            {:ok, date} ->
              pos = case :binary.match(content, "(D:") do
                :nomatch -> 0
                {pos, _} -> pos
              end
              offset = offset + pos + byte_size(match_name) + 4 # 1 for '(D:' and ')'
              {:date, date}
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
                {:date, date}
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
        {:string, name}
    end
  end

  defp parse_type(:xref, content, offset) do
    case Regex.named_captures(~r/^\s*(?P<id>[0-9]+\s+[0-9]+\s+R)/s, content) do
      nil -> false
      %{"id" => id} ->
        {pos, _} = :binary.match(content, id)
        offset = offset + pos + byte_size(id)
        {:xref, :binary.replace(String.trim_trailing(id, " R"), " ", "_")}
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
