defmodule Expdf.ElementXref do
  defstruct [:val]

  def parse(content, offset \\ 0) do
    IO.inspect(content)
    System.halt()
    case Regex.named_captures(~r/^\s*(?P<id>[0-9]+\s+[0-9]+\s+R)/s, content) do
      nil -> false
      %{"id" => id} ->
        {pos, _} = :binary.match(content, id)
        offset = offset + pos + byte_size(id)
        {%__MODULE__{val: :binary.replace(String.trim_trailing(id, " R"), " ", "_")}, offset}
    end
  end

end
