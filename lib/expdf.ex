defmodule Expdf do
  alias Expdf.{
    Document,
    Parser,
    Header,
    Object,
    ElementHexa,
    Element,
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
         :ok <- check_objects(parsed_data),
         {:ok, parsed_data} <- parse_objects(parsed_data) do
         create_document(parsed_data)
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

  def create_document(%Parser{elements: elements} = parser) do
    dictionary = elements
    |> Enum.map(fn {id, object} ->
      {type, header, _} = object
      case Header.get(parser, header, "Type") do
        {:ok, header, nil} -> nil
        {:ok, header, obj} -> {Element.content(obj), id, object}
      end
    end)
    |> Enum.filter(fn val -> !is_nil(val) end)
    |> Enum.group_by(fn {type, id, object} -> type end)
    document = %Document{dictionary: dictionary, trailer: parse_trailer(parser.xref.trailer)}
    Document.parse_details(parser, document)
  end

  defp parse_trailer(structure) when is_list(structure) do
    trailer = structure
    |> Enum.filter(&(!is_nil(&1)))
    |> Enum.with_index
    |> Enum.reduce(Keyword.new(), fn {values, i}, acc ->
      name = i |> to_string |> String.to_atom
      value = cond do
        is_number(values) -> {:numeric, values}
        is_list(values) -> {:array, parse_trailer(values)}
        String.match?(values, ~r/_/) -> {:xref, values}
        true -> parse_header_element("(", values)
      end
      Keyword.put(acc, name, value)
    end)
    %Header{elements: trailer}
  end

  defp parse_trailer(structure) when is_map(structure) do
    trailer = structure
    |> Enum.filter(fn val ->
      case val do
        {name, values} -> !is_nil(values)
        _ -> !is_nil(val)
      end
    end)
    |> Enum.reduce(Keyword.new(), fn {name, values}, acc ->
      name = name |> to_string |> String.capitalize |> String.to_atom
      value = cond do
        is_number(values) -> {:numeric, values}
        is_list(values) -> {:array, parse_trailer(values)}
        String.match?(values, ~r/_/) -> {:xref, values}
        true -> parse_header_element("(", values)
      end
      Keyword.put(acc, name, value)
    end)
    %Header{elements: trailer}
  end

  defp parse_objects(%Parser{objects: objects} = parser) do
    elements = objects
    |> Enum.reduce(%{}, fn {id, structure}, acc ->
      {header, content, new_objects} = structure
      |> Enum.with_index
      |> Enum.reduce_while({%Header{}, "", []}, fn {part, i}, {header, content, new_objects} ->
        {obj_type, obj_val, obj_offset, obj_content} = part
        {new_header, new_content, new_objects, break} = case obj_type do
          "[" ->
            elements = Enum.reduce(obj_val, [], fn sub_element, elements ->
              {sub_type, sub_val, sub_offset, sub_content} = sub_element
              [parse_header_element(sub_type, sub_val) | elements]
            end)
            |> Enum.reverse()
            {%Header{elements: elements}, content, [], false}
          "<<" ->
            {parse_header(obj_val), "", [], false}
          "stream" ->
            obj_content = Enum.at(obj_content, 0, obj_val)
            case Header.get(parser, header, "Type") do
              {:ok, header, nil} ->
                {header, content, [], false}
              {:ok, obj} ->
                if obj.val == "ObjStm" do
                  matches = Regex.run(~r/^((\d+\s+\d+\s*)*)(.*)$/s, content)
                  new_content = matches |> Enum.at(3)

                  # Extract xrefs
                  table = Regex.split(~r/(\d+\s+\d+\s*)/s, Enum.at(matches, 1), [:trim, :include_captures])
                          |> Enum.into(%{}, fn xref ->
                            [id, position] = String.split(String.trim(xref), " ")
                            {position, id}
                          end)
                  positions = Map.keys(table) |> Enum.sort

                  new_objects = positions
                  |> Enum.with_index
                  |> Enum.map(fn {position, i} ->
                    id = "#{Map.get(table, position) |> to_string}_0"
                    next_position = Enum.at(positions, i + 1, byte_size(content))
                    sub_content = String.slice(content, position, next_position - position)
                    sub_header = Header.parse(sub_content, parser)
                    Object.new(parser, sub_header, "")
                  end)
                  {header, obj_content, new_objects, true}
                else
                  {header, obj_content, [], false}
                end
              _ ->
                {header, content, [], false}
            end
          _ ->
            element = parse_header_element(obj_type, obj_val)
            if element do
              {%Header{elements: [element]}, content, [], false}
            else
              {header, content, [], false}
            end
        end
        if break, do: {:halt, {new_header, new_content, new_objects}}, else: {:cont, {new_header, new_content, new_objects}}
      end)
      if Enum.empty?(new_objects) do
        case Map.has_key?(acc, id) do
          true -> acc
          false ->
            obj = Object.new(parser, header, content)
            Map.put(acc, id, obj)
        end
      else
        new_objects
        |> Enum.map(fn {id, obj} ->
          Map.put(acc, id, obj)
        end)
      end
    end)
    elements = elements
    |> Map.keys
    |> Enum.sort(fn id1, id2 ->
      [i1, _] = String.split(to_string(id1), "_")
      [i2, _] = String.split(to_string(id2), "_")
      String.to_integer(i1) < String.to_integer(i2)
    end)
    |> Enum.map(fn id ->
      {id, Map.get(elements, id)}
    end)
    {:ok, %{parser | elements: elements}}
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

      "boolean" -> {:boolean, String.downcase(val) == "true"}

      "null" -> nil

      "(" ->
        val = "(#{val})"
        case Element.parse(:date, val) do
          false -> Element.parse(:string, val)
          date -> date
        end

      "<" ->
        parse_header_element("(", ElementHexa.decode(val))

      "/" ->
        Element.parse(:name, "/#{val}")

      "[" ->
        values = Enum.reduce(val, [], fn {sub_type, sub_val, _, _}, acc ->
          [parse_header_element(sub_type, sub_val) | acc]
        end)
        {:array, Enum.reverse(values)}

      "objref" -> {:xref, val}
      "endstream" -> nil
      "obj" -> nil
      "" -> nil
    end
  end

  defp float_val(value) do
    case Regex.run(~r/^[0-9.]+/, value) do
      [float] ->
        {float, _} = Float.parse(float)
        float
      _ -> 0.0
    end
  end

end
