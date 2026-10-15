defmodule HomeElixir.HA.OAuthStrategy do
  @moduledoc """
  The `OAuth2.Strategy.AuthCode` flow, minus the `Authorization: Basic` header.

  oauth2 always sends `Basic base64(client_id:client_secret)`. For Home
  Assistant's local client the `client_id` is a URL, so that header decodes to a
  garbage client id and the token exchange is rejected. HA identifies the client
  from `client_id` in the request body instead, so we omit the header.
  """
  use OAuth2.Strategy

  alias OAuth2.Strategy.AuthCode

  @impl true
  def authorize_url(client, params), do: AuthCode.authorize_url(client, params)

  @impl true
  def get_token(client, params, headers) do
    {code, params} = Keyword.pop(params, :code, client.params["code"])

    unless code do
      raise OAuth2.Error, reason: "Missing required key `code`"
    end

    client
    |> OAuth2.Client.put_param(:code, code)
    |> OAuth2.Client.put_param(:grant_type, "authorization_code")
    |> OAuth2.Client.put_param(:client_id, client.client_id)
    |> OAuth2.Client.put_param(:redirect_uri, client.redirect_uri)
    |> OAuth2.Client.merge_params(params)
    |> OAuth2.Client.put_headers(headers)
  end
end
