defmodule Expdf.Header do
  alias Expdf.Parser
  alias Expdf.Element
  import String, only: [to_atom: 1]

  defstruct elements: []

  def get_details(%__MODULE__{elements: elements}, deep \\ true) do
    elements
    |> Enum.reduce(%{}, fn {key, element}, acc ->
      case {element, deep} do
        {%__MODULE__{}, true} -> Map.put(acc, key, Element.details(element, deep))
        {{:object, _}, true} -> Map.put(acc, key, Element.details(element, false))
        {{:array, _}, true} -> Map.put(acc, key, Element.details(element))
        {{:array, _}, false} -> acc
        _ -> Map.put(acc, key, Element.content(element))
      end
    end)
  end

  def has(%__MODULE__{elements: elements}, name) do
    Keyword.has_key?(elements, name)
  end

  def get(parser, %__MODULE__{elements: elements} = header, name) when is_binary(name) do
    name = String.to_atom(name)
    case Keyword.get(elements, name) do
      nil ->
        {:ok, header, nil}
      element ->
        case resolve_xref(parser, element, name) do
          {:error, reason} -> {:error, reason}
          {:ok, obj} -> {:ok, %{header | elements: Keyword.put(elements, name, obj)}, obj}
        end
    end
  end

  def parse(content, parser, position \\ 0) do
    if String.slice(String.trim(content), 0, 2) == "<<" do
      Element.parse(:struct, content, position)
    else
      case Element.parse(:array, content, position) do
        {:array, elements, offset} ->
          %__MODULE__{elements: elements}
        _ ->
          %__MODULE__{}
      end
    end
  end

  defp resolve_xref(%Parser{objects: objects, elements: elements}, {:xref, val}, name) do
    case Keyword.get(elements, String.to_atom(val)) do
      nil -> {:error, "Missing object reference # #{name}"}
      obj -> {:ok, obj}
    end
  end

  defp resolve_xref(_, element, _) do
    {:ok, element}
  end

end
