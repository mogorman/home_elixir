defmodule HomeElixir.HA.OAuth do
  @moduledoc """
  Home Assistant local OAuth (authorization code + PKCE).

  home-elixir registers with HA as a local OAuth client whose `client_id` is its
  own origin (the `:web_base_url` config); HA issues no client secret for local
  clients. `start_login/0` begins a flow (minting the `state` + PKCE pair, kept
  in `HomeElixir.HA.PendingLogins`) and returns the HA authorize URL to redirect
  the browser to; `complete_login/2` validates the redirected `state` and
  exchanges the `code` for an access token.
  """

  @ttl_ms 600_000

  require Logger
  alias HomeElixir.HA.PendingLogins

  @doc "Begin a login; returns `{:ok, authorize_url, state}` or `{:error, reason}`."
  def start_login do
    case HomeElixir.HA.rest_base() do
      nil ->
        {:error, "Home Assistant is not configured"}

      base ->
        state = :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
        {verifier, challenge} = pkce()
        PendingLogins.put(state, verifier, @ttl_ms)

        url = client(base, state) |> put_challenge(challenge) |> OAuth2.Client.authorize_url!()
        {:ok, url, state}
    end
  end

  @doc "Exchange a `code` for an access token, validating `state`."
  def complete_login(code, state) do
    case PendingLogins.take(state) do
      nil ->
        {:error, :invalid_state}

      verifier ->
        client = HomeElixir.HA.rest_base() |> client(state)

        case OAuth2.Client.get_token(client, [code: code, code_verifier: verifier]) do
          {:ok, %OAuth2.Client{token: %OAuth2.AccessToken{access_token: token}}} ->
            {:ok, token}

          {:error, reason} ->
            Logger.warning("HA OAuth token exchange failed: #{inspect(reason)}")
            {:error, {:token, reason}}
        end
    end
  end

  # ---- internals ----

  defp client(base, state) do
    # The authorize/token endpoints must be reachable by the BROWSER, so use
    # the external HA URL (config :ha_external_url) when set; fall back to the
    # internal rest_base for non-reverse-proxy setups.
    origin = HomeElixir.HA.web_base_url()
    ext = Application.get_env(:home_elixir, :ha_external_url) || base

    %OAuth2.Client{
      strategy: HomeElixir.HA.OAuthStrategy,
      authorize_url: ext <> "/auth/authorize",
      token_url: ext <> "/auth/token",
      client_id: origin,
      client_secret: "",
      redirect_uri: origin <> "/oauth/callback",
      params: %{"state" => state, "code_challenge_method" => "S256"}
    }
    # HA answers the token endpoint with JSON.
    |> OAuth2.Client.put_serializer("application/json", Jason)
  end

  defp put_challenge(client, challenge) do
    OAuth2.Client.put_param(client, "code_challenge", challenge)
  end

  # PKCE: verifier is a random url-safe string; challenge is its S256 digest.
  defp pkce do
    verifier = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
    challenge = :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)
    {verifier, challenge}
  end
end
