defmodule Expdf.ElementDate do
  use Timex

  @derive [Expdf.Element]

  defstruct [:val]

  @formats [
    "4": "%Y",
    "6": "%Y%m",
    "8": "%Y%m%d",
    "10": "%Y%m%d%H",
    "12": "%Y%m%d%H%M",
    "14": "%Y%m%d%H%M%S",
    "15": "%Y%m%d%H%M%S%Z",
    "17": "%Y%m%d%H%M%S%z",
    "18": "%Y%m%d%H%M%S%z",
    "19": "%Y%m%d%H%M%S%z",
  ]

  def parse(content, offset \\ 0) do
    case Regex.named_captures(~r/^\s*\(D\:(?P<name>.*?)\)/s, content) do
      nil -> false
      %{"name" => match_name} ->
        name = String.replace(match_name, "'", "")
        if Regex.match?(~r/^\d{4}(\d{2}(\d{2}(\d{2}(\d{2}(\d{2}(Z(\d{2,4})?|[\+-]?\d{2}(\d{2})?)?)?)?)?)?)?$/, name) do
          pos = case :binary.match(name, "Z") do
            {pos, _} -> pos
            :nomatch -> false
          end
          name = cond do
            pos -> binary_part(name, 0, pos + 1)
            byte_size(name) == 18 && Regex.match?(~r/[^\+-]0000$/, name) -> binary_part(name, 0, byte_size(name) - 4)
            true -> name
          end
          format = @formats[name |> byte_size |> to_string |> String.to_atom]
          case Timex.parse(name, format, :strftime) do
            {:ok, date} ->
              pos = case :binary.match(content, "(D:") do
                :nomatch -> 0
                {pos, _} -> pos
              end
              offset = offset + pos + byte_size(match_name) + 4 # 1 for '(D:' and ')'
              {%__MODULE__{val: date}, offset}
            {:error, _} -> false
          end
        else
          if Regex.match?(~r/^\d{1,2}-\d{1,2}-\d{4},?\s+\d{2}:\d{2}:\d{2}[\+-]\d{4}$/, name) do
            name = String.replace(name, ",", "")
            format = "{M}-{D}-{YYYY} {h24}:{m}:{s}{Z}"
            case Timex.parse(name, format, :strftime) do
              {:ok, date} ->
                pos = case :binary.match(content, "(D:") do
                  :nomatch -> 0
                  {pos, _} -> pos
                end
                offset = offset + pos + byte_size(match_name) + 4 # 1 for '(D:' and ')'
                {%__MODULE__{val: date}, offset}
              {:error, _} -> false
            end
          else
            false
          end
        end
    end
  end

end
