defmodule HomeElixir.HA.LiveUpdate do
  @moduledoc """
  Send and dismiss Android/iOS Home Assistant companion **Live Activities** to a
  person's devices — the reusable core. Flows just call `update/3` / `dismiss/2`.

  A person's companion devices are discovered from their `person.<name>` entity's
  `device_trackers` list; each `device_tracker.<slug>` maps to the notify service
  `mobile_app_<slug>` (the `notify` domain is added separately, so the service
  name carries no `notify.` prefix).

  The companion reads its Live Activity fields (`tag`, `live_update`, `progress`,
  `progress_max`, `chronometer`, `when`, `notification_icon`, `color`, ...) from
  the notify service's **`data`** dict; `title`/`message` stay top-level (HA's
  schema requires them there). `update/3` adds a fixed `tag` and
  `live_update: true` so a later call with the same tag updates the activity in
  place; `dismiss/2` clears it by tag.

  The dispatch is **fire-and-forget** (an async `cast` to the HA client), so a
  caller never blocks waiting for delivery; only the single `get_states` read
  that resolves a person's devices is a (bounded) blocking call. Android requires
  Android 16+ for Live Activities to render.
  """

  alias HomeElixir.HA

  @doc """
  Send (or update) a Live Activity on every companion device of `person`.

  `person` is a person name (`"mog"`) or full entity (`"person.mog"`); `tag` keys
  the activity; `payload` holds the companion fields (`title`, `message`,
  `progress`, `progress_max`, `chronometer`, `when`, `notification_icon`,
  `color`, ...). Returns `{:ok, count}` (devices dispatched to) or `{:error,
  reason}`: `:not_connected`, `:person_not_found`, `:no_devices`, or `:ha_timeout`.
  """
  def update(person, tag, payload) when is_binary(tag) and is_map(payload) do
    with {:ok, services} <- notify_services(person) do
      sd = update_service_data(tag, payload)
      Enum.each(services, &dispatch(&1, sd))
      {:ok, length(services)}
    end
  end

  @doc "Dismiss the Live Activity `tag` on every companion device of `person`."
  def dismiss(person, tag) when is_binary(tag) do
    with {:ok, services} <- notify_services(person) do
      # The companion ends an activity on a notification whose message is the
      # literal "clear_notification", carrying the activity's tag.
      sd = %{message: "clear_notification", data: %{tag: tag}}
      Enum.each(services, &dispatch(&1, sd))
      {:ok, length(services)}
    end
  end

  # Fire-and-forget (async cast) so the caller never blocks on delivery.
  defp dispatch(service, service_data) do
    HA.Client.fire(HA.client(), "call_service", %{
      domain: "notify",
      service: service,
      service_data: service_data
    })
  end

  # `title`/`message` top-level; the rest (plus tag + live_update) in `data`.
  defp update_service_data(tag, payload) do
    {message, rest} = Map.pop(payload, :message, "")
    {title, rest} = Map.pop(rest, :title)
    data = rest |> Map.put(:tag, tag) |> Map.put(:live_update, true)

    base = %{message: message, data: data}
    if title, do: Map.put(base, :title, title), else: base
  end

  # The `mobile_app_<slug>` notify services for a person's companion devices, or
  # an error tuple.
  defp notify_services(person) do
    with true <- HA.connected?(),
         {:ok, st} <- read_person(person_entity(person)) do
      case Map.get(st["attributes"] || %{}, "device_trackers") do
        trackers when is_list(trackers) and length(trackers) > 0 ->
          # device_tracker.<slug> -> mobile_app_<slug> (the `notify` domain is
          # added separately by the call_service, so no prefix here).
          {:ok,
           Enum.map(trackers, fn dt ->
             dt |> String.replace_leading("device_tracker.", "mobile_app_")
           end)}

        _ ->
          {:error, :no_devices}
      end
    else
      false -> {:error, :not_connected}
      {:error, {:not_found, _}} -> {:error, :person_not_found}
      {:error, :timeout} -> {:error, :ha_timeout}
      _ -> {:error, :no_devices}
    end
  end

  # A person read is a `get_states` that can transiently fail (WS `id_reuse` /
  # timeout); one retry uses a fresh, higher WS id that HA accepts.
  defp read_person(entity) do
    case HA.state(entity) do
      {:error, :timeout} -> HA.state(entity)
      {:error, %{code: "id_reuse"}} -> HA.state(entity)
      other -> other
    end
  end

  defp person_entity(entity) do
    if String.starts_with?(entity, "person."), do: entity, else: "person.#{entity}"
  end
end
