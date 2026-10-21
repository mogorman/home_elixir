defmodule Mix.Tasks.Docs.InjectBase do
  @shortdoc "Anchor the generated ExDoc pages to their own root with a <base>."
  @moduledoc """
  Injects a client-side `<base href="<base>/static/docs/">` into each
  `priv/static/docs/*.html` right after `<head>`.

  The ExDoc site is a static sub-site. Its links are relative, so they only
  resolve correctly when the browser's URL already carries the sub-path. Setting
  an explicit `<base>` anchored at the site's own root makes it work under any
  reverse-proxy / HA-ingress prefix (the prefix is computed in the browser, since
  behind HA ingress the supervisor only reveals it client-side).
  """

  # Emits: <base href="<ingress-prefix>/static/docs/"> (prefix "" at the site root).
  @tag ~s|<script>(function(){var m=location.pathname.match(/^\\/api\\/(?:hassio_)?ingress\\/[^\\/]+/);document.write('<base href="'+(m?m[1]:"")+'/static/docs/">');})();</script>|

  @spec run([String.t()]) :: :ok
  def run(_args) do
    injected =
      Path.wildcard("priv/static/docs/*.html")
      |> Enum.count(fn f ->
        s = File.read!(f)

        if String.contains?(s, "<head>") and not String.contains?(s, @tag) do
          File.write!(f, String.replace(s, "<head>", "<head>" <> @tag, global: false))
          true
        else
          false
        end
      end)

    Mix.shell().info("docs <base> ensured in #{injected} page(s) under priv/static/docs")
    :ok
  end
end
