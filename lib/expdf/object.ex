defmodule Expdf.Object do
  alias Expdf.Header
  alias Expdf.Element

  defstruct [:content, :header]

  def new(parser, header, content) do
    case Header.get(parser, header, "Type") do
      {:error, reason} -> {:error, reason}
      {:ok, header, obj} ->
        case Element.content(obj) do
          "XObject" ->
            case Header.get(parser, header, "Subtype") do
              {:ok, header, obj} ->
                case Element.content(obj) do
                  "Image" -> {:image, header, content}
                  "Form" -> {:form, header, content}
                  _ -> {:object, header, content}
                end
              _ ->
                {:object, header, content}
            end

          "Pages" -> {:pages, header, content}
          "Page" -> {:page, header, content}
          "Encoding" -> {:encoding, header, content}
          "Font" ->
            subtype = case Header.get(parser, header, "Subtype") do
              {:ok, _, obj} ->
                subtype = Element.content(obj)
                if Enum.member?(~w(CIDFontType0 CIDFontType2 TrueType Type0 Type1), subtype) do
                  subtype
                else
                  nil
                end
              _ -> nil
            end
            type = if subtype, do: "font_#{subtype}" |> String.to_atom(), else: :font
            {type, header, content}
          _ -> {:object, header, content}
        end
    end
  end
end
