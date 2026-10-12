defmodule HomeElixir.EntityBrowser do
  @moduledoc """
  Build an Area > Device > Entity tree of Home Assistant entities, for the
  editor's entity browser. `build/3` is pure and assembles the tree from three
  read-only HA lists; `tree/0` fetches them from the shared HA client.

  Areas come from each device's `area_id` (there is no reliable "list areas"
  command across HA versions), so area labels are the prettified area slug.
  """

  alias HomeElixir.HA

  @no_area "No area"
  @no_device "Unnamed device"

  @doc "Fetch and build the tree. `connected: false` when no HA client is running."
  def tree do
    case HA.client() do
      nil ->
        %{connected: false, areas: []}

      client ->
        %{
          connected: true,
          areas:
            build(
              fetch(client, "get_states"),
              fetch(client, "config/entity_registry/list"),
              fetch(client, "config/device_registry/list")
            )
        }
    end
  end

  @doc """
  Pure: build the Area > Device > Entity tree from three HA lists.

  `states` (`get_states`), `registry` (`config/entity_registry/list`),
  `devices` (`config/device_registry/list`). An entity's area is its own
  `area_id`, else its device's; with no area it goes under `"No area"`. Entities
  with no device are listed loose under their area; a `device_id` not in
  `devices` is named `"Unnamed device"`. Returns a list of
  `%{"name", "devices" => [%{"name", "entities"}], "entities"}` maps, each
  entity a `%{"id", "name", "state", "unit", "cls"}` map.
  """
  def build(states, registry, devices) do
    reg_by_id = Map.new(registry, fn r -> {Map.get(r, "entity_id"), r} end)
    device_by_id = Map.new(devices, fn d -> {Map.get(d, "id"), d} end)

    entities =
      for s <- states do
        id = Map.get(s, "entity_id")
        attrs = Map.get(s, "attributes") || %{}
        reg = Map.get(reg_by_id, id)
        device_id = reg && Map.get(reg, "device_id")
        device = device_id && Map.get(device_by_id, device_id)
        area_id = (reg && Map.get(reg, "area_id")) || (device && Map.get(device, "area_id"))

        %{
          id: id,
          name: Map.get(attrs, "friendly_name") || id,
          state: Map.get(s, "state"),
          unit: Map.get(attrs, "unit_of_measurement"),
          cls: Map.get(attrs, "device_class"),
          device_id: device_id,
          area_id: area_id,
          device_name: (device && Map.get(device, "name")) || @no_device
        }
      end

    entities
    |> Enum.group_by(& &1.area_id)
    |> Enum.map(fn {area_id, es} ->
      {with_dev, loose} = Enum.split_with(es, & &1.device_id)

      devices =
        with_dev
        |> Enum.group_by(& &1.device_id)
        |> Enum.map(fn {_dev_id, devs} ->
          %{"name" => hd(devs).device_name, "entities" => render(devs)}
        end)
        |> Enum.sort_by(fn d -> d["name"] end)

      %{"name" => area_label(area_id), "devices" => devices, "entities" => render(loose)}
    end)
    |> Enum.sort_by(fn a -> a["name"] end)
  end

  # "living_room" -> "Living Room"; nil -> "No area".
  defp area_label(nil), do: @no_area

  defp area_label(area_id) do
    area_id
    |> String.split(~r/[-_]/)
    |> Enum.map(&String.capitalize/1)
    |> Enum.join(" ")
  end

  defp render(es) do
    for e <- Enum.sort_by(es, & &1.id) do
      %{"id" => e.id, "name" => e.name, "state" => e.state, "unit" => e.unit, "cls" => e.cls}
    end
  end

  # A read-only HA call; an error (or a non-list result) degrades to [] so the
  # tree still shows whatever did come back rather than failing the whole page.
  defp fetch(client, type) do
    case HA.Client.call(client, type) do
      list when is_list(list) -> list
      _ -> []
    end
  end
end
