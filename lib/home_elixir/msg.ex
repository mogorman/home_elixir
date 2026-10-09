defmodule HomeElixir.Msg do
  @moduledoc """
  A message flowing through a flow, Node-RED-style. `payload` is the primary
  value; `topic` and `data` carry metadata; extra fields live in `data`.
  """

  @enforce_keys [:payload]
  defstruct [:payload, :topic, data: %{}, msgid: nil]

  @type t :: %__MODULE__{
          payload: term(),
          topic: term(),
          data: map(),
          msgid: term()
        }

  @doc "Build a message: `Msg.new(\"hi\", topic: \"x\")`."
  def new(payload, opts \\ []) do
    struct!(__MODULE__, Keyword.put(opts, :payload, payload))
  end
end
