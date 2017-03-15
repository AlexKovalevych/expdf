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
  def parse(content, document, position, only_values \\ false) do
  end
end
