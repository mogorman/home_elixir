defmodule HomeElixir.HA.LiveUpdate do
  @moduledoc """
  Send and dismiss Android/iOS Home Assistant companion **Live Activities** to a
  person's devices — the reusable core. Flows just call `update/3` / `dismiss/2`.

  A person's companion devices are discovered from their `person.<name>` entity's
  `device_trackers` list; each `device_tracker.X` maps to the companion notify
  service `notify.mobile_app_X`.

  The Live Activity companion fields go in `payload` (`title`, `message`,
  `progress`, `progress_max`, `chronometer`, `when`, `when_relative`,
  `notification_icon`, `color`, ...). `update/3` adds a fixed `tag` and
  `live_update: true` so a later call with the same tag updates the activity in
  place; `dismiss/2` clears the activity by tag. Android requires Android 16+.
  """

  alias HomeElixir.HA

  @doc """
  Send (or update) a Live Activity on every companion device of `person`.

  `person` is a person name (`"mog"`) or full entity (`"person.mog"`); `tag` keys
  the activity; `payload` holds the companion fields. Returns `{:ok, count}`
  (devices notified) or `{:error, reason}` (`:not_connected`, `:no_devices`).
  """
  def update(person, tag, payload) when is_binary(tag) and is_map(payload) do
    with {:ok, services} <- notify_services(person) do
      Enum.each(services, fn service ->
        HA.Client.call(HA.client(), "call_service", %{
          domain: "notify",
          service: service,
          service_data: Map.put(payload, :tag, tag) |> Map.put(:live_update, true)
        })
      end)

      {:ok, length(services)}
    end
  end

  @doc "Dismiss the Live Activity `tag` on every companion device of `person`."
  def dismiss(person, tag) when is_binary(tag) do
    with {:ok, services} <- notify_services(person) do
      Enum.each(services, fn service ->
        HA.Client.call(HA.client(), "call_service", %{
          domain: "notify",
          service: service,
          service_data: %{clear_notification: true, notification_tag: tag}
        })
      end)

      {:ok, length(services)}
    end
  end

  # The `notify.mobile_app_X` services for a person's companion devices, or an
  # error tuple.
  defp notify_services(person) do
    with true <- HA.connected?,
         {:ok, %{"attributes" => attrs}} <- HA.state(person_entity(person)),
         trackers when is_list(trackers) and length(trackers) > 0 <- Map.get(attrs, "device_trackers") do
      {:ok,
       Enum.map(trackers, fn dt ->
         dt |> String.replace_leading("device_tracker.", "notify.mobile_app.")
       end)}
    else
      false -> {:error, :not_connected}
      _ -> {:error, :no_devices}
    end
  end

  defp person_entity(entity) do
    if String.starts_with?(entity, "person.") do
      entity
    else
      "person.#{entity}"
    end
  end
end
