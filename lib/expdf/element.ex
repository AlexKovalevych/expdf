defprotocol Expdf.Element do
  @doc """
  Get content of element
  """
  def content(element)

end

defimpl Expdf.Element, for: Any do
  def content(%{val: val}), do: val
end
