# `HomeElixir.HA.OAuthStrategy`
[🔗](https://github.com/mogorman/home_elixir/blob/main/lib/home_elixir/ha/oauth_strategy.ex#L1)

The `OAuth2.Strategy.AuthCode` flow, minus the `Authorization: Basic` header.

oauth2 always sends `Basic base64(client_id:client_secret)`. For Home
Assistant's local client the `client_id` is a URL, so that header decodes to a
garbage client id and the token exchange is rejected. HA identifies the client
from `client_id` in the request body instead, so we omit the header.

---

*Consult [api-reference.md](api-reference.md) for complete listing*
