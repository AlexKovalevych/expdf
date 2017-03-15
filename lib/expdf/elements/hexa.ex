defmodule Expdf.ElementHexa do
  def decode(value) do
    text = case String.slice(value, 0, 2) do
      "00" ->
        Enum.chunk(0..byte_size(value) - 1, 1, 4, [])
        |> Enum.reduce("", fn [i], text ->
          hex = String.slice(value, i, 4)
          {symbol, _} = Integer.parse("a0", 16)
          "#{text}&##{<<symbol>>}#{String.pad_leading(symbol, 4, "0")};"
        end)
      _ ->
        Enum.chunk(0..byte_size(value) - 1, 1, 2, [])
        |> Enum.reduce("", fn [i], text ->
          hex = String.slice(value, i, 2)
          {symbol, _} = Integer.parse(hex, 16)
          text <> <<symbol>>
        end)
    end
    HtmlEntities.decode(text)
  end
end
