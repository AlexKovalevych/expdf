defmodule Expdf do
  def parse(data) do
    case :binary.match(data, "%PDF-") do
      :nomatch ->
        {:error, "Invalid PDF data: missing %PDF header"}
      {pos, _} ->
        len = byte_size(data) - pos
        pdf_data = binary_part(data, pos, len)
        xref = get_xref_data(pdf_data)
    end
  end

  defp get_xref_data(data, offset \\ 0, xref \\ []) do

  end

end
