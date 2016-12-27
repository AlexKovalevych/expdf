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
            struct = get_objects(pdf_data, %__MODULE__{xref: xref, objects: nil})
            {:ok, struct}
        end
    end
  end

  defp get_objects(data, %__MODULE__{xref: xref, objects: objects} = struct) do
    struct
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
            IO.inspect(2)
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
            get_xref_data(data, int_val(Enum.at(matches, 1)), xref)
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
