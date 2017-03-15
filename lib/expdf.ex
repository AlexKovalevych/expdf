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
    ElementNumeric,
    ElementNil,
    ElementArray,
    ElementMissing,
    ElementHexa,
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
              {:ok, header, %ElementMissing{}} ->
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

      "numeric" -> %ElementNumeric{val: float_val(val)}

      "boolean" -> %ElementBoolean{val: String.downcase(val) == "true"}

      "null" -> %ElementNil{}

      "(" ->
        val = "(#{val})"
        case ElementDate.parse(val) do
          false ->
            {element, _} = ElementString.parse(val)
            element
          {date, _} ->
            date
        end

      "<" ->
        parse_header_element("(", ElementHexa.decode(val))

      "/" ->
        {element, _} = ElementName.parse("/#{val}")
        element

      "[" ->
        values = Enum.reduce(val, [], fn {sub_type, sub_val, _, _}, acc ->
          [parse_header_element(sub_type, sub_val) | acc]
        end)
        %ElementArray{val: Enum.reverse(values)}

      "objref" -> %ElementXref{val: val}
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
