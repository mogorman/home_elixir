# `HomeElixir.HA.OAuth`
[🔗](https://github.com/mogorman/home_elixir/blob/main/lib/home_elixir/ha/oauth.ex#L1)

Home Assistant local OAuth (authorization code + PKCE).

home-elixir registers with HA as a local OAuth client whose `client_id` is its
own origin (the `:web_base_url` config); HA issues no client secret for local
clients. `start_login/0` begins a flow (minting the `state` + PKCE pair, kept
in `HomeElixir.HA.PendingLogins`) and returns the HA authorize URL to redirect
the browser to; `complete_login/2` validates the redirected `state` and
exchanges the `code` for an access token.

# `complete_login`

Exchange a `code` for an access token, validating `state`.

# `start_login`

Begin a login; returns `{:ok, authorize_url, state}` or `{:error, reason}`.

---

*Consult [api-reference.md](api-reference.md) for complete listing*
