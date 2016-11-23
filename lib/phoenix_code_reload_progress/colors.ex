defmodule PhoenixCodeReloadProgress.Colors do
  defp css_color(n) when is_binary(n),
    do: String.to_integer(n) |> css_color()
  defp css_color(31), do: :red
  defp css_color(33), do: "#b3b30a"

  def to_html(string) do
    Regex.replace(~r/\e\[(\d+)m(.+)?\e\[0m/, string, fn _, color, msg ->
      css = css_color(color)
      ~s(<span style="color: #{css}">#{msg}</span>)
    end)
  end
end

"\e[33mwarning: \e[0mthe Phoenix.Param protocol has already been consolidated, an implementation for HexWeb.Package has no effect\n  web/models/package.ex:8\n\n"
|> PhoenixCodeReloadProgress.Colors.to_html
|> IO.puts
