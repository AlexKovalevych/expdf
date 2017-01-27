defmodule Expdf.ElementName do
  alias Expdf.Font

  @derive [Expdf.Element]

  defstruct [:val]

  def parse(val, offset \\ 0) do
    case Regex.named_captures(~r/^\s*\/(?P<name>[A-Z0-9\-\+,#\.]+)/is, val) do
      nil -> false
      %{"name" => name} ->
        {pos, _} = :binary.match(val, name)
        offset = offset + pos + byte_size(name)
        {%__MODULE__{val: Font.decode_entities(name)}, offset}
    end
  end

end
