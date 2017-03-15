defmodule Expdf.Parser do

  defstruct [:xref, :objects]

  def parse(data) do
    case :binary.match(data, "%PDF-") do
      :nomatch ->
        {:error, "Invalid PDF data: missing %PDF header"}
      {pos, _} ->
        pdf_data = substring(data, pos)
        case get_xref_data(pdf_data) do
          {:error, reason} -> {:error, reason}
          {:ok, xref} ->
            case get_objects(pdf_data, %__MODULE__{xref: xref, objects: Keyword.new()}) do
              {:error, reason} -> {:error, reason}
              struct -> {:ok, %{struct | objects: Enum.reverse(struct.objects)}}
            end
        end
    end
  end

  defp get_objects(data, %__MODULE__{xref: xref, objects: objects} = struct) do
    res = xref.xref
    |> Enum.filter(fn {obj, offset} ->
      offset > 0
    end)
    |> Enum.sort(fn {obj1, _}, {obj2, _} ->
      [obj1_1, _] = String.split(obj1, "_")
      [obj2_1, _] = String.split(obj2, "_")
      {obj1_1, _} = Integer.parse(obj1_1)
      {obj2_1, _} = Integer.parse(obj2_1)
      obj1_1 < obj2_1
    end)
    |> Enum.reduce_while(struct, fn {obj, offset}, acc ->
      case get_indirect_object(data, obj, struct, offset, true) do
        {:error, reason} ->
          {:halt, {:error, reason}}
        {:ok, new_obj} ->
          {:cont, %{acc | objects: Keyword.put(acc.objects, String.to_atom(obj), new_obj)}}
      end
    end)
  end

  defp get_indirect_object(data, obj, struct, offset, decoding \\ true) do
    case String.split(obj, "_") do
      [obj1, obj2] ->
        obj_ref = "#{obj1} #{obj2} obj"
        offset_data = substring(data, offset)
        offset = offset + case Regex.run(~r/0/, offset_data, return: :index) do
          nil -> 0
          [{pos, len}] -> len - 1
        end
        is_nil_obj = case :binary.match(data, obj_ref) do
          {pos, _} -> pos != offset
          _ -> true
        end
        if is_nil_obj do
          {:ok, {"null", "null", offset}}
        else
          offset = offset + byte_size(obj_ref)
          obj_data = get_obj_data(data, struct, offset, [], 0, decoding)
          {:ok, Enum.take(obj_data, Enum.count(obj_data) - 1)}
        end
      _ -> {:error, "Invalid object reference #{obj}"}
    end
  end

  defp get_obj_data(data, struct, offset, obj_data, i, decoding) do
    {obj_type, obj_val, new_offset, _} = get_raw_object(data, offset)
    stream = case Enum.at(obj_data, i - 1) do
      nil -> nil
      {el_type, el_val, _, _} ->
        if decoding && obj_type == "stream" && el_type == "<<" do
          decode_stream(data, struct, el_val, obj_val)
        end
    end

    obj_data = [{obj_type, obj_val, new_offset, stream} | obj_data]
    if obj_type != "endobj" && offset != new_offset do
      get_obj_data(data, struct, new_offset, obj_data, i + 1, decoding)
    else
      obj_data |> Enum.reverse
    end
  end

  defp decode_stream(data, struct, s_dic, stream) do
    # get stream length and filters
    s_length = byte_size(stream)
    if s_length > 0 do
      {stream, filters, s_length} = s_dic
      |> Enum.with_index
      |> Enum.reduce({stream, [], s_length}, fn {{v_type, v_val, v_offset_, v_stream}, k}, {stream, filters, s_length} = acc ->
        if v_type == "/" do
          case Enum.at(s_dic, k + 1) do
            nil -> acc
            {obj_type, obj_val, _, _} = s_dic_obj ->
              cond do
                v_val == "Length" && obj_type == "numeric" ->
                  # get declared stream length
                  dec_length = int_val(obj_val)
                  if dec_length < s_length do
                    {binary_part(stream, 0, dec_length), filters, dec_length}
                  else
                    acc
                  end

                v_val == "Filter" ->
                  # resolve indirect object
                  {obj_type, obj_val, offset, s} = get_obj_val(data, struct, s_dic_obj)
                  cond do
                    obj_type == "/" ->
                      # single filter
                      {stream, [obj_val | filters], s_length}
                    obj_type == "[" ->
                      # array of filters
                      arr_filters = obj_val
                                    |> Enum.reduce([], fn {t, v, _, _}, a ->
                                      if t == "/", do: [v | a], else: a
                                    end)
                      {stream, filters ++ arr_filters, s_length}
                    true -> acc
                  end

                true -> acc
              end
          end
        else
          acc
        end
      end)

      filters = Enum.reverse(filters)
      # decode the stream
      {remaining_filters, stream} = Enum.reduce(filters, {[], stream}, fn f, {remaining_filters, stream} ->
        if Enum.member?(Expdf.Filter.available(), f) do
          {remaining_filters, Expdf.Filter.decode(f, stream)}
        else
          {[f | remaining_filters], stream}
        end
      end)
      [stream, Enum.reverse(remaining_filters)]
    else
      ["", []]
    end
  end

  defp get_obj_val(data, struct, {"objref", obj_val, obj_offset, obj_stream} = obj) do
    # reference to indirect object
    cond do
      Map.has_key?(struct.objects, obj_val) ->
        # this object has been already parsed
        Map.get(struct.objects, obj_val)

      Map.has_key?(struct.xref.xref, obj_val) ->
        # parse new object
        get_indirect_object(data, obj_val, struct, Map.get(struct.xref.xref, obj_val), false)

      true -> obj
    end
  end

  defp get_obj_val(_, _, obj) do
    obj
  end

  defp get_raw_object(data, start_offset) do
    obj_type = ""
    obj_val = ""
    # skip initial white space chars: \x00 null (NUL), \x09 horizontal tab (HT), \x0A line feed (LF), \x0C form feed (FF), \x0D carriage return (CR), \x20 space (SP)

    offset_data = substring(data, start_offset)
    offset = case Regex.run(~r/^[\x00\x09\x0a\x0c\x0d\x20]+/, offset_data, return: :index) do
      nil -> 0
      [{pos, len}] -> len
    end
    offset = offset + start_offset

    # get first char
    <<char>> <> _ = substring(data, offset)
    char = <<char>>
    # get object type
    res = cond do

      # \x25 PERCENT SIGN
      char == "%" ->
        # skip comment and search for next token
        offset_data = substring(data, offset)
        next = case Regex.run(~r/[\r\n]+/, offset_data, return: :index) do
          nil -> 0
          [{pos, len}] -> len
        end
        if next > 0 do
          offset + next
        else
          {obj_type, obj_val, offset}
        end

      # \x2F SOLIDUS
      char == "/" ->
        # name object
        obj_type = char
        offset = offset + 1
        offset_data = substring(data, offset) |> String.slice(0..255)
        {obj_val, offset} = case Regex.run(~r/^([^\x00\x09\x0a\x0c\x0d\x20\s\x28\x29\x3c\x3e\x5b\x5d\x7b\x7d\x2f\x25]+)/, offset_data) do
          nil -> {obj_val, offset}
          match ->
            {Enum.at(match, 1), offset + byte_size(Enum.at(match, 0))}
        end
        {obj_type, obj_val, offset}

      # \x28 LEFT PARENTHESIS
      # \x29 RIGHT PARENTHESIS
      Enum.member?(["(", ")"], char) ->
        # literal string object
        obj_type = char
        offset = offset + 1
        if char == "(" do
          str_pos = parse_parenthesis(data, offset, 1)
          obj_val = data
                    |> substring(offset)
                    |> binary_part(0, str_pos - offset - 1)
          {obj_type, obj_val, str_pos}
        else
          {obj_type, obj_val, offset}
        end

      # \x5B LEFT SQUARE BRACKET
      # \x5D RIGHT SQUARE BRACKET
      Enum.member?(["[", "]"], char) ->
        # array object
        obj_type = char
        offset = offset + 1
        if char == "[" do
          {obj_val, offset} = get_array_content(data, offset, [], "]")
          {obj_type, obj_val, offset}
        else
          {obj_type, obj_val, offset}
        end

      # \x3C LESS-THAN SIGN
      # \x3E GREATER-THAN SIGN
      Enum.member?(["<", ">"], char) ->
        if byte_size(data) > (offset + 1) && <<:binary.at(data, offset + 1)>> == char do
          # dictionary object
          obj_type = char <> char
          offset = offset + 2
          if char == "<" do
            {obj_val, offset} = get_array_content(data, offset, [], ">>")
            {obj_type, obj_val, offset}
          else
            {obj_type, obj_val, offset}
          end
        else
          # hexadecimal string object
          obj_type = char
          offset = offset + 1
          offset_data = substring(data, offset)
          matches = Regex.run(~r/^([0-9A-Fa-f\x09\x0a\x0c\x0d\x20]+)>/iU, offset_data)
          {obj_val, offset} = cond do
            char == "<" && matches ->
              # remove white space characters
              obj_val = String.replace(Enum.at(matches, 1), ~r/[\x09\x0a\x0c\x0d\x20]/, "")

              offset = offset + (Enum.at(matches, 0) |> byte_size)
              {obj_val, offset}

            {pos, _} = :binary.match(offset_data, ">") ->
              {obj_val, pos + 1}

            true -> {obj_val, offset}
          end
          {obj_type, obj_val, offset}
        end

      true ->
        offset_data = substring(data, offset)
        cond do
          # indirect object
          binary_part(offset_data, 0, 6) == "endobj" -> {"endobj", obj_val, offset + 6}

          # null object
          binary_part(offset_data, 0, 4) == "null" -> {"null", "null", offset + 4}

          # boolean true object
          binary_part(offset_data, 0, 4) == "true" -> {"boolean", "true", offset + 4}

          # boolean false object
          binary_part(offset_data, 0, 5) == "false" -> {"boolean", "false", offset + 5}

          # start stream object
          binary_part(offset_data, 0, 6) == "stream" ->
            offset = offset + 6
            {obj_val, offset} = case Regex.run(~r/^([\r]?[\n])/isU, substring(data, offset)) do
              nil -> {obj_val, offset}
              matches ->
                offset = offset + byte_size(List.first(matches))
                offset_data = substring(data, offset)
                case Regex.run(~r/(endstream)[\x09\x0a\x0c\x0d\x20]/isU, offset_data) do
                  nil -> {obj_val, offset}
                  matches ->
                    {pos, _} = :binary.match(offset_data, Enum.at(matches, 0))
                    obj_val = binary_part(offset_data, 0, pos)
                    {pos, _} = :binary.match(offset_data, Enum.at(matches, 1))
                    {obj_val, offset + pos}
                end
            end
            {"stream", obj_val, offset}

          # end stream object
          binary_part(offset_data, 0, 9) == "endstream" -> {"endstream", obj_val, offset + 9}

          matches = raw_object_reference(offset_data) ->
            # indirect object reference
            obj_val = "#{int_val(Enum.at(matches, 1))}_#{int_val(Enum.at(matches, 2))}"
            offset = offset + byte_size(Enum.at(matches, 0))
            {"objref", obj_val, offset}

          matches = raw_object_start(offset_data) ->
            # object start
            obj_val = "#{int_val(Enum.at(matches, 1))}_#{int_val(Enum.at(matches, 2))}"
            offset = offset + byte_size(Enum.at(matches, 0))
            {"obj", obj_val, offset}

          {:ok, len} = raw_numeric_object(offset_data) ->
            # numeric object
            {"numeric", binary_part(offset_data, 0, len), offset + len}

          true -> {obj_type, obj_val, offset}
        end
    end

    case res do
      {obj_type, obj_val, offset} -> {obj_type, obj_val, offset, nil}
      offset -> get_raw_object(data, offset)
    end
  end

  defp raw_numeric_object(data) do
    case Regex.run(~r/^[+-.0-9]+/, data, return: :index) do
      nil -> nil
      [{pos, len}] -> {:ok, len}
    end
  end

  defp raw_object_reference(data) do
    Regex.run(~r/^([0-9]+)[\s]+([0-9]+)[\s]+R/iU, binary_part(data, 0, 33))
  end

  defp raw_object_start(data) do
    Regex.run(~r/^([0-9]+)[\s]+([0-9]+)[\s]+obj/iU, binary_part(data, 0, 33))
  end

  defp parse_parenthesis(data, offset, open_bracket) when open_bracket <= 0 do
    offset
  end

  defp parse_parenthesis(data, offset, open_bracket) when open_bracket > 0 do
    if byte_size(data) <= offset do
      offset
    else
      ch = :binary.at(data, offset)
      {new_offset, new_open_bracket} = case <<ch>> do
        # REVERSE SOLIDUS (5Ch) (Backslash)
        # skip next character
        "\\" -> {offset + 1, open_bracket}
        "(" -> {offset, open_bracket + 1}
        ")" -> {offset, open_bracket - 1}
        _ -> {offset, open_bracket}
      end
      parse_parenthesis(data, new_offset + 1, new_open_bracket)
    end
  end

  def get_array_content(data, offset, obj_val, close_element) do
    element = get_raw_object(data, offset)
    {obj_type, val, new_offset, _} = element
    obj_val = [element | obj_val]
    if obj_type == close_element do
      {Enum.reverse(obj_val) |> Enum.drop(-1), new_offset}
    else
      get_array_content(data, new_offset, obj_val, close_element)
    end
  end

  defp get_xref_data(data, offset \\ 0, xref \\ %{xref: %{}, trailer: nil}) do
    offset_data = substring(data, offset)
    case get_start_xref(offset_data, offset) do
      {:error, reason} -> {:error, reason}
      {:ok, start_xref} ->
        # check xref position
        case :binary.match(substring(data, start_xref), "xref") do
          {0, _} ->
            # Cross-Reference
            decode_xref(data, start_xref, xref)
          _ ->
            # Cross-Reference Stream
            decode_xref_stream(data, start_xref, xref)
        end
    end
  end

  defp get_start_xref(data, offset) do
    cond do
      offset == 0 ->
        case Regex.scan(~r/[\r\n]startxref[\s]*[\r\n]+([0-9]+)[\s]*[\r\n]+%%EOF/i, data) |> List.last do
          [_, start_xref] -> {:ok, String.to_integer(start_xref)}
          _ -> {:error, "Unable to find startxref"}
        end
      :binary.match(data, "xref") != :nomatch -> {:ok, offset}
      Regex.scan(~r/([0-9]+[\s][0-9]+[\s]obj)/i, data) != [] -> {:ok, offset}
      true ->
        case Regex.scan(~r/[\r\n]startxref[\s]*[\r\n]+([0-9]+)[\s]*[\r\n]+%%EOF/i, data) do
          [] -> {:error, "Unable to find startxref"}
          matches -> matches
        end
    end
  end

  defp substring(data, pos) do
    len = byte_size(data) - pos
    binary_part(data, pos, len)
  end

  defp decode_xref(data, start_xref, xref) do
    start_xref = start_xref + 4 # is the length of the word 'xref'
    # skip initial white space chars: \x00 null (NUL), \x09 horizontal tab (HT), \x0A line feed (LF), \x0C form feed (FF), \x0D carriage return (CR), \x20 space (SP)
    start_xref_data = substring(data, start_xref)
    offset = case Regex.run(~r/[\x00\x09\x0a\x0c\x0d\x20]+/, start_xref_data, return: :index) do
      nil -> 0
      [{pos, len}] -> len
    end

    offset = offset + start_xref
    {obj_num, offset, xref} = get_obj_num(data, 0, offset, xref)
    get_xref(data, offset, xref)
  end

  defp get_obj_num(data, obj_num, offset, xref) do
    offset_data = substring(data, offset)
    case Regex.run(~r/([0-9]+)[\x20]([0-9]+)[\x20]?([nf]?)(\r\n|[\x20]?[\r\n])/, offset_data, return: :index) do
      nil -> {obj_num, offset, xref}
      matches ->
        {pos, len} = List.first(matches)
        if pos != 0 do
          {obj_num, offset, xref}
        else
          offset = offset + len
          {obj_num, xref} = cond do
            get_re_value(offset_data, matches, 3) == "n" ->
              index = "#{obj_num}_#{int_val(get_re_value(offset_data, matches, 2))}"
              new_xref = if !Map.has_key?(xref.xref, index), do: Map.put(xref.xref, index, int_val(get_re_value(offset_data, matches, 1))), else: xref.xref
              {obj_num + 1, %{xref | xref: new_xref}}
            get_re_value(offset_data, matches, 3) == "f" -> {obj_num + 1, xref}
            true ->
              # object number (index)
              {int_val(get_re_value(offset_data, matches, 1)), xref}
          end
          get_obj_num(data, obj_num, offset, xref)
        end
    end
  end

  defp get_xref(data, offset, xref) do
    offset_data = substring(data, offset)
    case Regex.run(~r/trailer[\s]*<<(.*)>>/isU, offset_data, return: :index) do
      nil -> {:error, "Unable to find trailer"}
      matches ->
        trailer_data = get_re_value(offset_data, matches, 1)
        trailer = if !Map.has_key?(xref, :trailer) || xref.trailer == nil do
          trailer = %{size: nil, root: nil, encrypt: nil, info: nil, id: []}
          trailer = case Regex.run(~r/Size[\s]+([0-9]+)/i, trailer_data) do
            nil -> trailer
            matches -> %{trailer | size: int_val(Enum.at(matches, 1))}
          end
          trailer = case Regex.run(~r/Root[\s]+([0-9]+)[\s]+([0-9]+)[\s]+R/i, trailer_data) do
            nil -> trailer
            matches ->
              [val1, val2] = Enum.map(1..2, fn i -> Enum.at(matches, i) |> int_val |> to_string end)
              %{trailer | root: "#{val1}_#{val2}"}
          end
          trailer = case Regex.run(~r/Encrypt[\s]+([0-9]+)[\s]+([0-9]+)[\s]+R/i, trailer_data) do
            nil -> trailer
            matches ->
              [val1, val2] = Enum.map(1..2, fn i -> Enum.at(matches, i) |> int_val |> to_string end)
              %{trailer | encrypt: "#{val1}_#{val2}"}
          end
          trailer = case Regex.run(~r/Info[\s]+([0-9]+)[\s]+([0-9]+)[\s]+R/i, trailer_data) do
            nil -> trailer
            matches ->
              [val1, val2] = Enum.map(1..2, fn i -> Enum.at(matches, i) |> int_val |> to_string end)
              %{trailer | info: "#{val1}_#{val2}"}
          end
          case Regex.run(~r/ID[\s]*[\[][\s]*[<]([^>]*)[>][\s]*[<]([^>]*)[>]/i, trailer_data) do
            nil -> trailer
            matches -> %{trailer | id: [Enum.at(matches, 1), Enum.at(matches, 2)]}
          end
        else
          xref.trailer
        end
        xref = %{xref | trailer: trailer}
        xref = case Regex.run(~r/Prev[\s]+([0-9]+)/i, trailer_data) do
          nil -> xref
          matches ->
            case get_xref_data(data, int_val(Enum.at(matches, 1)), xref) do
              {:ok, xref} -> xref
              {:error, reason} -> {:error, reason}
            end
        end
        {:ok, xref}
    end
  end

  defp decode_xref_stream(data, start_xref, xref) do
  end

  defp get_re_value(data, matches, index) do
    case Enum.at(matches, index) do
      nil -> nil
      {pos, len} -> binary_part(data, pos, len)
    end
  end

  defp int_val(value) do
    case Regex.run(~r/^[0-9]+/, value) do
      [int] -> String.to_integer(int)
      _ -> 0
    end
  end

end
