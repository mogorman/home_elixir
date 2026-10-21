# `HomeElixir.Web`
[🔗](https://github.com/mogorman/home_elixir/blob/main/lib/home_elixir/web.ex#L1)

Web UI + JSON API for managing flows: a list page, an inline-highlighted
editor for flow files, and a live-updating log page.

The `/terminal` route gives the browser a real IEx attached to the running
app: when the app is a named node it opens `iex --remsh home_elixir` (a
distributed connection into this VM), otherwise it falls back to `iex -S mix`.

Routes:
  GET  /                        flow list (load/unload/edit)
  GET  /edit                    editor for a new flow
  GET  /edit/:name              editor preloaded with flows/:name.ex
  GET  /logs                    live log view
  GET  /terminal                real IEx in the browser (xterm.js over WebSocket)
  GET  /api/flows               list flows (JSON)
  GET  /api/entity_tree         HA Area > Device > Entity tree (JSON)
  GET  /api/logs?since=N        log lines newer than N (JSON)
  GET  /api/flows/:name/ui      UI elements for one flow (JSON)
  POST /api/flows/:name/load | unload | reload
  POST /api/flows/reload        reload all loaded flows
  POST /api/flows/save | check   (save reuses the editor's path via the X-Flow-Name header; new files derive it from the module)

# `base_path`

# `call`

# `dispatch`

# `home_path`

# `ingress?`

# `init`

# `login_path`

# `name_from_source`

---

*Consult [api-reference.md](api-reference.md) for complete listing*
