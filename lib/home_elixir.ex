defmodule HomeElixir do
  @moduledoc """
  Home Assistant flow engine entry point.

  `hello/0` is the hello world: it makes the engineering clock say
  "hello world" over its TTS by firing the `tts.speak` service.
  """

  alias HomeElixir.HA

  @hello_message "hello world"
  @default_entity "media_player.engineering_clock"

  @doc """
  Hello world: make the engineering clock say "hello world" over its TTS.

  Fires the `tts.speak` service on the entity from `hello_entity_id/0`.
  Returns `:ok` when the call is fired against a connected client, or
  `{:error, :not_connected}` when no HA client is running.

      iex> HomeElixir.hello()   # with no HA client connected
      {:error, :not_connected}

  With a connected client this returns `:ok` and the clock speaks.
  """
  def hello do
    case HA.client() do
      nil ->
        {:error, :not_connected}

      client ->
        HA.Client.fire(client, "call_service", %{
          domain: "tts",
          service: "speak",
          service_data: %{entity_id: hello_entity_id(), message: @hello_message}
        })

        :ok
    end
  end

  @doc """
  The entity `hello/0` speaks on.

  Resolution order: the `HA_HELLO_ENTITY` env var, then the
  `:hello_entity_id` config, then the default `media_player.engineering_clock`.
  """
  def hello_entity_id do
    System.get_env("HA_HELLO_ENTITY") ||
      Application.get_env(:home_elixir, :hello_entity_id, @default_entity)
  end
end
