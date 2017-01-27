defmodule Expdf do
  alias Expdf.{
    Parser,
    Header,
    Object,
    ElementDate,
    ElementName,
    ElementXref,
    ElementString,
    ElementBoolean,
    ElementArray
  }

  @doc """
  Parse given string data

  ## Parameters
  - `data` - file content as binary string

  ## Example

    iex> File.read!("./test/test_data/test.pdf") |> Expdf.parse
    true

  """
  def parse(data) do
    with {:ok, parsed_data} <- Parser.parse(data),
         :ok <- check_encrypt(parsed_data),
         :ok <- check_objects(parsed_data) do
         #{:ok, parsed_objects} <- parse_objects(parsed_data)
         parse_objects(parsed_data)
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp check_objects(%Parser{objects: objects}) do
    if Enum.empty?(objects), do: {:error, "Object list not found."}, else: :ok
  end

  defp check_encrypt(%Parser{xref: xref}) do
    if xref.trailer.encrypt, do: {:error, "Secured pdf file are currently not supported."}, else: :ok
  end

  defp parse_objects(%Parser{objects: objects} = parser) do
    objects
    |> Enum.reduce([], fn {id, structure}, acc ->
      structure
      |> Enum.with_index
      |> Enum.reduce(Keyword.new(), fn {part, i}, objects ->
        {obj_type, obj_val, obj_offset, _} = part
        {header, content} = case obj_type do
          "[" ->
            elements = Enum.reduce(obj_val, [], fn sub_element, elements ->
              IO.inspect(sub_element)
              System.halt()
            end)
          "<<" ->
            {parse_header(obj_val), ""}
        end
        if !Keyword.has_key?(objects, id) do
          obj = Object.new(parser, header, content)
          #Keyword.put(objects, id, Object.new(parser, header, content))
          IO.inspect(obj)
          Keyword.put(objects, id, obj)
        else
          objects
        end
      end)
    end)
  end

  defp parse_header(structure) do
    count = Enum.count(structure)
    acc = -1..count - 1
    |> Enum.drop_every(2)
    |> Enum.reduce(Keyword.new(), fn i, acc ->
      {_, name, _, _} = Enum.at(structure, i)
      {type, val, _, _} = Enum.at(structure, i + 1)
      Keyword.put(acc, String.to_atom(name), parse_header_element(type, val))
    end)
    %Header{elements: acc}
  end

  defp parse_header_element(type, val) do
    case type do
      "<<" -> parse_header(val)

      "numeric" -> {:numeric, float_val(val)}

      "boolean" -> %ElementBoolean{val: String.downcase(val) == "true"}

      "null" -> {:null, nil}

      "(" ->
        val = "(#{val})"
        case ElementDate.parse(val) do
          false ->
            {element, _} = ElementString.parse(val)
            element
          {date, _} ->
            date
        end

      "/" ->
        {element, _} = ElementName.parse("/#{val}")
        element

      "[" ->
        values = Enum.reduce(val, [], fn {sub_type, sub_val, _, _}, acc ->
          [parse_header_element(sub_type, sub_val) | acc]
        end)
        IO.inspect(values)
        %ElementArray{val: Enum.reverse(values)}

      "objref" -> %ElementXref{val: val}

    end
  end

  defp float_val(value) do
    case Regex.run(~r/^[0-9.]+/, value) do
      {float, _} -> Float.parse(float)
      _ -> 0
    end
  end

end
