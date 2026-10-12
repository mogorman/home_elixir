defmodule HomeElixir.EntityBrowserTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias HomeElixir.EntityBrowser

  # Canned lists mirroring the three HA WS calls (string keys, as HA returns them).
  defp states, do: [
    %{"entity_id" => "sensor.front_door", "state" => "open",
      "attributes" => %{"friendly_name" => "Front Door", "device_class" => "door"}},
    %{"entity_id" => "light.kitchen", "state" => "on",
      "attributes" => %{"friendly_name" => "Kitchen Light"}},
    %{"entity_id" => "sensor.unknown", "state" => "42",
      "attributes" => %{"unit_of_measurement" => "°C"}},
    %{"entity_id" => "switch.d2", "state" => "off", "attributes" => %{}}
  ]

  defp registry, do: [
    %{"entity_id" => "sensor.front_door", "device_id" => "d1", "area_id" => nil},
    %{"entity_id" => "light.kitchen", "device_id" => nil, "area_id" => "kitchen"},
    %{"entity_id" => "switch.d2", "device_id" => "d2", "area_id" => nil}
    # sensor.unknown intentionally absent from the registry
  ]

  # device ids use "id" (not "device_id"); area_id is a slug.
  defp devices, do: [
    %{"id" => "d1", "name" => "Front Door", "area_id" => "kitchen"},
    %{"id" => "d2", "name" => "Thermostat", "area_id" => nil}
  ]

  defp build do
    EntityBrowser.build(states(), registry(), devices())
  end

  defp find(areas, name), do: Enum.find(areas, &(&1["name"] == name))

  test "build/3 groups entities Area > Device > Entity, with No-area and loose buckets" do
    [kitchen, no_area] = build()

    assert kitchen["name"] == "Kitchen"
    assert no_area["name"] == "No area"

    # Kitchen: Front Door device holds sensor.front_door; light.kitchen is loose.
    assert [%{"name" => "Front Door", "entities" => [%{"id" => "sensor.front_door"}]}] =
             kitchen["devices"]

    assert [%{"id" => "light.kitchen"}] = kitchen["entities"]

    # No area: Thermostat (d2, no area) holds switch.d2; sensor.unknown is loose.
    assert [%{"name" => "Thermostat", "entities" => [%{"id" => "switch.d2"}]}] =
             no_area["devices"]

    assert [%{"id" => "sensor.unknown"}] = no_area["entities"]
  end

  test "build/3 carries state, unit, device_class, and falls back to the id for name" do
    [_, no_area] = build()
    [unknown] = no_area["entities"]

    assert %{"id" => "sensor.unknown", "state" => "42", "unit" => "°C", "name" => "sensor.unknown"} =
             unknown

    [kitchen] = [find(build(), "Kitchen")]
    [front] = kitchen["devices"] |> hd() |> Map.get("entities")
    assert front["cls"] == "door"
    assert front["name"] == "Front Door"
  end

  test "build/3 names a device missing from the device list 'Unnamed device'" do
    reg = [%{"entity_id" => "sensor.x", "device_id" => "ghost", "area_id" => nil}]

    tree =
      EntityBrowser.build(
        [%{"entity_id" => "sensor.x", "state" => "s", "attributes" => %{}}],
        reg,
        []
      )

    [%{"name" => "No area", "devices" => [%{"name" => "Unnamed device", "entities" => [_]}]}] = tree
  end

  test "area_label/1 prettifies an area slug" do
    tree =
      EntityBrowser.build(
        [%{"entity_id" => "light.x", "state" => "on", "attributes" => %{}}],
        [%{"entity_id" => "light.x", "device_id" => "d", "area_id" => nil}],
        [%{"id" => "d", "name" => "D", "area_id" => "living_room"}]
      )

    [%{"name" => "Living Room"}] = tree
  end
end
