defmodule Expdf.Font do

  def decode_hexadecimal(hexa, add_braces \\ false) do
    Regex.split(~r/(<[a-z0-9]+>)/si, hexa, [trim: true, include_captures: true])
    |> Enum.reduce("", fn part, acc ->
      if Regex.match?(~r/^<.*>$/, part) && !String.contains?(part, "<?xml") do
        part = Regex.replace(~r/^([<>]+)/, part, "")
        part = Regex.replace(~r/([<>]+)$/, part, "")
        acc = if add_braces do
          acc <> "#{acc}("
        else
          acc
        end
        part = Base.encode16(part)
        acc <> if add_braces do
          Regex.replace(~r/\\/s, part, "\\\\") <> ")"
        else
          part
        end
      else
        acc <> part
      end
    end)
  end

  def decode_unicode(text) do
    if Regex.match?(~r/^\xFE\xFF/i, text) do
      # Strip U+FEFF byte order marker.
      decode = binary_part(text, 2, byte_size(text) - 2)
      len = byte_size(decode)
      -1..len - 1
      |> Enum.drop_every(2)
      |> Enum.reduce("", fn i, acc ->
        {val, _} = decode
        |> binary_part(i, 2)
        |> Base.encode16
        |> Integer.parse(16)
        acc <> uchr(val)
      end)
    else
      text
    end
  end

  def decode_octal(text) do
    Regex.split(~r/(\\\\\d{3})/s, text, [trim: true, include_captures: true])
    |> Enum.reduce("", fn part, acc ->
      if Regex.match?(~r/^\\\\\d{3}$/, part) do
        {k, _} = part
        |> String.trim("\\")
        |> Integer.parse(8)
        acc <> <<k>>
      else
        acc <> part
      end
    end)
  end

  def decode_entities(text) do
    Regex.split(~r/(#\d{2})/s, text, [trim: true, include_captures: true])
    |> Enum.reduce("", fn part, acc ->
      if Regex.match?(~r/^#\d{2}$/, part) do
        {k, _} = part
        |> String.trim("#")
        |> Integer.parse(16)
        acc <> <<k>>
      else
        acc <> part
      end
    end)
  end

  defp uchr(code) do
    HtmlEntities.decode("&##{code};")
  end

end
