defmodule Expdf.Filter do
  use Bitwise, only_operators: true

  @available_filters ["ASCIIHexDecode", "ASCII85Decode", "LZWDecode", "FlateDecode", "RunLengthDecode"]

  def available do
    @available_filters
  end

  defp ascii_hex_eod(data, false) do
    if rem(byte_size(data), 2) == 0, do: {:ok, data}, else: {:error, "ascii_hex_decode: invalid code"}
  end

  defp ascii_hex_eod(data, true) do
    # EOD shall behave as if a 0 (zero) followed the last digit
    len = byte_size(data)
    if rem(len, 2) != 0 do
      {:ok, "#{binary_part(data, 0, len - 1)}0#{binary_part(data, len - 1, 1)}"}
    else
      {:ok, data}
    end
  end

  defp ascii_check_invalid_chars(data) do
    case Regex.match?(~r/[^a-fA-F\d]/, data) do
      false -> {:ok, data}
      true -> {:error, "ascii_hex_decode: invalid code"}
    end
  end

  defp run_length_decode(data, length, i, decoded) do
    byte = binary_part(data, i, 1) |> :binary.decode_unsigned
    cond do
      i == length - 1 ->
        {:halt, decoded}
      byte == 128 ->
        # a length value of 128 denote EOD
        {:halt, decoded}
      byte < 128 ->
        # if the length byte is in the range 0 to 127
        # the following length + 1 (1 to 128) bytes shall be copied literally during decompression
        {:cont, run_length_decode(data, length, i + byte + 2, decoded <> binary_part(data, i + 1, byte + 1))}
      true ->
        # if length is in the range 129 to 255,
        # the following single byte shall be copied 257 - length (2 to 128) times during decompression
        {:cont, run_length_decode(data, length, i + 2, String.duplicate(binary_part(data, i + 1, 1), 257 - byte))}
    end
  end

  defp lzw_decode(_, data_length, _, _, _, _, decoded) when data_length <= 0 do
    decoded
  end

  defp lzw_decode(data, data_length, dictionary, bitlen, dix, prev_index, decoded) do
    case binary_part(data, 0, bitlen) |> Integer.parse(10) do
      {index, _} ->
        case index do
          257 -> decoded
          _ ->
            bitstring = binary_part(data, 0, bitlen)
            # update number of bits
            data_length = data_length - bitlen
            cond do
              index == 256 ->
                # clear table marker
                dictionary = 0..255 |> Enum.map(fn i -> <<i>> end)
                lzw_decode(bitstring, data_length, dictionary, 9, 258, 256, decoded)
              prev_index == 256 ->
                lzw_decode(bitstring, data_length, dictionary, bitlen, dix, index, decoded <> Enum.at(dictionary, index))
              true ->
                {decoded, dic_val, prev_index} = if index < dix do
                  # index exist on dictionary
                  dic_val = Enum.at(dictionary, prev_index) <> String.at(Enum.at(dictionary, index), 0)
                  {decoded <> Enum.at(dictionary, index), dic_val, index}
                else
                  # index do not exist on dictionary
                  dic_val = Enum.at(dictionary, prev_index) <> String.at(Enum.at(dictionary, prev_index), 0)
                  {decoded <> dic_val, dic_val, prev_index}
                end

                # update dictionary
                dictionary = List.update_at(dictionary, dix, dic_val)
                dix = dix + 1

                # change bit length by case
                bitlen = case dix do
                  2047 -> 12
                  1023 -> 11
                  511 -> 10
                  _ -> bitlen
                end

                lzw_decode(bitstring, data_length, dictionary, bitlen, dix, prev_index, decoded)
            end
        end
      :error -> {:error, "lzw_decode: invalid code"}
    end

  end

  def decode(filter, data) do
    case filter do
      "ASCIIHexDecode" ->
        # all white-space characters shall be ignored
        data = Regex.replace(~r/[\s]/, data, "")
        # check for EOD character: GREATER-THAN SIGN (3Eh)
        {data, eod} = case :binary.match(data, ">") do
          nil -> {data, false}
          [{pos, _}] ->
            # remove EOD and extra data (if any)
            {binary_part(data, 0, pos), true}
        end

        with {:ok, data} <- ascii_hex_eod(data, eod),
             {:ok, data} <- ascii_check_invalid_chars(data) do
              # get one byte of binary data for each pair of ASCII hexadecimal digits
              Hexate.encode(data)
        else
          {:error, reason} -> {:error, reason}
        end

      "ASCII85Decode" ->
        # initialize string to return
        decoded = ""

        # all white-space characters shall be ignored
        data = Regex.replace(~r/[\s]/, data, "")

        # remove start sequence 2-character sequence <~ (3Ch)(7Eh)
        data = case :binary.match(data, "<~") do
          # remove EOD and extra data (if any)
          {_, _} -> binary_part(data, 2, byte_size(data) - 2)
          _ -> data
        end

        # check for EOD: 2-character sequence ~> (7Eh)(3Eh)
        data = case :binary.match(data, "~>") do
          {pos, _} ->
            # remove EOD and extra data (if any)
            data = binary_part(data, 0, pos);
            _ -> data
        end

        # data length
        data_length = byte_size(data)

        # check for invalid characters
        case Regex.match?(~r/[^\x21-\x75,\x74]/, data) do
          true -> {:error, "ascii_85_decoded: invalid code"}
          false ->
            # z sequence
            z_seq = <<0, 0, 0, 0>>
            # position inside a group of 4 bytes (0-3)
            pow_85 = [85 * 85 * 85 * 85, 85 * 85 * 85, 85 * 85, 85, 1]
            last_pos = data_length - 1
            res = 0..data_length
                  |> Enum.reduce_while({0, 0, decoded}, fn i, {tuple, group_pos, decoded} ->
                    # get char value
                    char = binary_part(data, i, 1) |> :binary.decode_unsigned
                    case char == 122 do
                      true ->
                        if group_pos == 0 do
                          {:cont, {tuple, group_pos, decoded <> z_seq}}
                        else
                          {:halt, {:error, "ascii_85_decoded: invalid code"}}
                        end
                      false ->
                        # the value represented by a group of 5 characters should never be greater than 2^32 - 1
                        tuple = tuple + ((char - 33) * Enum.at(pow_85, group_pos))
                        if group_pos == 4 do
                          decoded = decoded <> <<tuple >>> 24>> <> <<tuple >>> 16>> <> <<tuple >>> 8>> <> <<tuple>>
                          {:cont, {0, 0, decoded}}
                        else
                          {:cont, {tuple, group_pos + 1, decoded}}
                        end
                    end
                  end)
            case res do
              {:error, reason} -> {:error, reason}
              {tuple, group_pos, decoded} ->
                tuple = if group_pos > 1, do: tuple + Enum.at(pow_85, group_pos - 1), else: tuple
                # last tuple (if any)
                case group_pos do
                  4 -> decoded <> <<tuple >>> 24>> <> <<tuple >>> 16>> <> <<tuple >>> 8>>
                  3 -> decoded <> <<tuple >>> 24>> <> <<tuple >>> 16>>
                  2 -> decoded <> <<tuple >>> 24>>
                  _ -> {:error, "ascii_85_decoded: invalid code"}
                end
            end
        end

      "LZWDecode" ->
        # data length
        data_length = byte_size(data)
        dictionary = 0..255 |> Enum.map(fn i -> <<i>> end)
        lzw_decode(data, byte_size(data), dictionary, 9, 258, 0, "")

      "FlateDecode" ->
        z = :zlib.open()
        :zlib.inflateInit(z)
        uncompressed = :zlib.inflate(z, data)
        :zlib.close(z)
        case uncompressed do
          [] -> {:error, "flate_filter_decode: invalid code"}
          _ -> :erlang.list_to_binary(uncompressed)
        end

      "RunLengthDecode" ->
        run_length_decode(data, byte_size(data), 0, "")

      "CCITTFaxDecode" ->
        {:error, "ccitt_fax_decode: not implemented"}

      "JBIG2Decode" ->
        {:error, "jbig2_decode: not implemented"}

      "DCTDecode" ->
        {:error, "dct_decode: not implemented"}

      "JPXDecode" ->
        {:error, "jpx_decode: not implemented"}

      "Crypt" ->
        {:error, "crypt_decode: not implemented"}

      _ ->
        {:ok, data}

    end
  end

end
