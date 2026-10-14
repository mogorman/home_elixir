defmodule HomeElixir.Flows.Examples.MailCheck do
  @moduledoc """
  Front-door mail check: snapshots `camera.frontdoor`, asks a vision LLM
  (req_llm, OpenAI-compatible server) whether a mail truck is present, shows
  the answer on a badge, and latches "Mail came today" until midnight.

  The latch is a stored date, not a boolean: `mail_date == today` is the
  derived state, so it goes false at midnight even if nothing runs then. A
  spawned sleeper pokes the flow at midnight purely to refresh the badge.
  (If the VM restarts after the poke was scheduled, the next check refreshes
  it — correctness never depends on the timer.)

  LLM settings under `:home_elixir` in config/secret.exs (or env):
  `:llm_url`, `:llm_model`, `:llm_api_key`.
  """
  use HomeElixir.Flow

  require Logger

  @behaviour HomeElixir.Node

  alias HomeElixir.FlowState

  @camera "camera.frontdoor_snapshots_clear"
  @prompt "Is there a mail truck present in this image? Answer with a single word: true or false."

  def setup do
    HomeElixir.Dep.install([{:req_llm, "~> 1.28"}])
    schedule_midnight_refresh()
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
        Logger.info("check: snapshot fetched in #{now_ms() - t0}ms")
        FlowState.put(:snapshot, "data:image/jpeg;base64,#{b64}")
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
    Application.get_env(:home_elixir, key, default)
  end

  defp schedule_midnight_refresh do
    spawn(fn ->
      case ms_until_local_midnight() do
        ms when ms > 0 ->
          Process.sleep(ms)

          HomeElixir.Registry.send_msg(
            __MODULE__,
            "check",
            HomeElixir.Msg.new("midnight", topic: "check")
          )

        _ ->
          :ok
      end
    end)
  end

  # Machine-local date (this Elixir build dropped Date.today/0 and
  # Calendar.default/0; the VM's :calendar always knows the system zone).
  defp local_today do
    {{y, m, d}, _} = :calendar.local_time()
    Date.new!(y, m, d)
  end

  defp ms_until_local_midnight do
    {{y, m, d}, _} = :calendar.local_time()
    tomorrow = Date.new!(y, m, d) |> Date.add(1)

    # Returns a list (ambiguous local times have two candidates).
    # ponytail: on a DST transition a local midnight may not exist (empty) —
    # then the badge just doesn't auto-refresh; the next check does.
    case :calendar.local_time_to_universal_time_dst(
           {{tomorrow.year, tomorrow.month, tomorrow.day}, {0, 0, 0}}
         ) do
      [midnight_utc | _] ->
        # This OTP returns seconds (not ms) from universal_time_to_system_time.
        :calendar.universal_time_to_system_time(midnight_utc) * 1000 -
          System.system_time(:millisecond)

      [] ->
        0
    end
  end

  # Web button (Inject re-emits the click payload into the handler).
  node("check", HomeElixir.Nodes.Inject,
    ui: %{type: "button", label: "Check for mail", payload: "check"}
  )

  # Display badges (this module); no wires needed — unconnected Inject nodes
  # feed the handler, and state-badge nodes are fed by its output.
  node("status", __MODULE__, which: :last_check, ui: %{type: "state", label: "Last check"})
  node("mail", __MODULE__, which: :mail_today, ui: %{type: "state", label: "Mail came today"})
  node("snapshot", __MODULE__, which: :snapshot, ui: %{type: "image", label: "Front door"})
end
