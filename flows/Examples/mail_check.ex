defmodule HomeElixir.Flows.Examples.MailCheck do
  @moduledoc """
  Front-door mail check: snapshots `camera.frontdoor`, asks a vision LLM
  (req_llm, OpenAI-compatible server) whether a mail truck is present, shows
  the answer on a badge, and latches "Mail came today" until midnight.

  The latch is a stored date, not a boolean: `mail_date == today` is the
  derived state, so it goes false at midnight even if nothing runs then. A
  nightly cron (a `Schedule` node, `0 0 * * *`) pokes the flow at local
  midnight purely to refresh the badge; correctness never depends on it.

  LLM settings are editable in the UI (flow panel → config) and fall back to
  `:home_elixir` in config/secret.exs / env vars: `:llm_url`, `:llm_model`,
  `:llm_api_key`.
  """
  use HomeElixir.Flow

  require Logger

  @behaviour HomeElixir.Node

  alias HomeElixir.FlowState

  @camera "camera.frontdoor_snapshots_clear"
  @prompt "Is there a mail truck present in this image? Answer with a single word: true or false."

  def setup do
    HomeElixir.Dep.install([{:req, "~> 0.5"}, {:req_llm, "~> 1.28"}])

    # Declare editable keys + defaults. Only-if-absent, so a value the user later
    # edits in the UI survives reloads. The API key is seeded from current config
    # (secret.exs/env) so it's editable in the UI without breaking a working key.
    HomeElixir.Config.seed(%{
      llm_url: "http://localhost:42808/v1",
      llm_model: "deepthought-first"
    })

    HomeElixir.Config.seed(
      %{llm_api_key: Application.get_env(:home_elixir, :llm_api_key) || "set-in-config-ui"},
      scope: :global
    )
  end

  # ---- handler flow: the button click and the midnight poke arrive here ----
  def handle(%{payload: "check"}), do: check_mail()
  def handle(%{payload: "midnight"}), do: :ok

  # ---- display nodes: this module doubles as both badges (see counter.ex) ----
  @impl true
  def init(config), do: %{which: Map.get(config, :which), state: value(config)}

  @impl true
  def handle(_msg, data), do: {[nil], Map.put(data, :state, value(data))}

  # ---- internals ----

  defp check_mail do
    Logger.info("check: start")
    t0 = now_ms()

    case snapshot_b64() do
      {:ok, b64} ->
        data_url = "data:image/jpeg;base64,#{b64}"
        Logger.info("check: snapshot fetched in #{now_ms() - t0}ms")
        FlowState.put(:snapshot, data_url)
        push_snapshot(data_url)
        check_answer(ask_llm(b64))

      {:error, reason} ->
        Logger.warning("check: snapshot failed in #{now_ms() - t0}ms: #{inspect(reason)}")
        FlowState.put(:last_check, "error")
    end
  end

  defp check_answer({:ok, text}) do
    # The model is told to answer a single word, but often wraps it in newlines
    # ("\n\nfalse"). Match true/false explicitly; default to 0 (no mail) when the
    # reply is unparseable, so a non-answer never latches "mail came today".
    flag =
      cond do
        text =~ ~r/\btrue\b/i -> 1
        text =~ ~r/\bfalse\b/i -> 0
        true -> 0
      end

    Logger.info("check: done, answer=#{inspect(text)} -> #{flag}")
    if flag == 1, do: FlowState.put(:mail_date, to_string(local_today()))
    FlowState.put(:last_check, flag)
  end

  defp check_answer({:error, reason}) do
    Logger.warning("check failed: #{inspect(reason)}")
    FlowState.put(:last_check, "error")
  end

  defp ask_llm(b64) do
    t0 = now_ms()

    case ReqLLM.generate_text(
           model_spec(),
           ReqLLM.Context.new([
             ReqLLM.Context.with_image(:user, @prompt, "data:image/jpeg;base64,#{b64}")
           ]),
           api_key: llm_config(:llm_api_key),
           max_tokens: 400
         ) do
      {:ok, response} ->
        Logger.info("check: llm responded in #{now_ms() - t0}ms")
        {:ok, response_text(response)}

      other ->
        Logger.warning("check: llm failed in #{now_ms() - t0}ms: #{inspect(other)}")
        {:error, "llm: #{inspect(other)}"}
    end
  end

  defp now_ms, do: System.monotonic_time(:millisecond)

  # Push the fresh snapshot to the UI as soon as it's captured (before the slow
  # LLM call), so the front-door image updates immediately rather than waiting
  # for handle/1 to return.
  defp push_snapshot(data_url) do
    flow = __MODULE__ |> to_string() |> String.split(".") |> List.last() |> Macro.underscore()
    HomeElixir.UI.Hub.push(:state, %{flow: flow, node: "snapshot", value: data_url})
  end

  # The model's text answer, ignoring its reasoning/thinking parts.
  defp response_text(response) do
    response.message.content
    |> Enum.filter(&(&1.type == :text))
    |> Enum.map(& &1.text)
    |> Enum.join()
  end

  # deepthought-first is not in LLMDB, so the model spec must carry its own
  # execution contract (req_llm's shared OpenAI chat adapter).
  defp model_spec do
    %{
      provider: :openai,
      id: llm_config(:llm_model, "deepthought-first"),
      base_url: llm_config(:llm_url, "http://localhost:42808/v1"),
      execution: %{
        text: %{
          supported: true,
          family: "openai_chat_compatible",
          wire_protocol: "openai_chat",
          path: "/chat/completions"
        }
      }
    }
  end

  defp snapshot_b64 do
    base = HomeElixir.HA.rest_base()
    token = HomeElixir.HA.token()

    case Req.get("#{base}/api/camera_proxy/#{@camera}",
           headers: [authorization: "Bearer #{token}"]
         ) do
      {:ok, %Req.Response{status: 200, body: bytes}} -> {:ok, Base.encode64(bytes)}
      other -> {:error, "snapshot: #{inspect(other)}"}
    end
  end

  defp value(%{which: :last_check}), do: FlowState.get(:last_check)
  defp value(%{which: :mail_today}), do: FlowState.get(:mail_date) == to_string(local_today())
  defp value(%{which: :snapshot}), do: FlowState.get(:snapshot)

  defp llm_config(key, default \\ nil) do
    HomeElixir.Config.get(key, default)
  end

  # Machine-local date (this Elixir build dropped Date.today/0 and
  # Calendar.default/0; the VM's :calendar always knows the system zone).
  defp local_today do
    {{y, m, d}, _} = :calendar.local_time()
    Date.new!(y, m, d)
  end

  # Web button (Inject re-emits the click payload into the handler).
  node("check", HomeElixir.Nodes.Inject,
    ui: %{type: "button", label: "Check for mail", payload: "check"}
  )

  # Nightly reset: a cron (wall clock) pokes the flow at local midnight so the
  # "Mail came today" badge re-derives to false. Replaces the old spawned sleeper.
  node("midnight", HomeElixir.Nodes.Schedule, cron: "0 0 * * *", payload: "midnight")

  # Display badges (this module); no wires needed — unconnected Inject nodes
  # feed the handler, and state-badge nodes are fed by its output.
  node("status", __MODULE__, which: :last_check, ui: %{type: "state", label: "Last check"})
  node("mail", __MODULE__, which: :mail_today, ui: %{type: "state", label: "Mail came today"})
  node("snapshot", __MODULE__, which: :snapshot, ui: %{type: "image", label: "Front door"})
end
