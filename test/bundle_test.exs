defmodule HomeElixir.BundleTest do
  use ExUnit.Case, async: true
  alias HomeElixir.Bundle

  # Flow names (no .ex) — includes a sub-folder name to exercise nested paths.
  @flows [
    {"alpha", "defmodule HomeElixir.Flows.Alpha do\nend\n"},
    {"LivingRoom/counter", "defmodule HomeElixir.Flows.LivingRoom.Counter do\nend\n"}
  ]

  test "json round-trips" do
    assert {:ok, {bytes, "home-elixir-flows.json", "application/json"}} = Bundle.produce(@flows, :json)
    assert {:ok, pairs} = Bundle.consume(bytes, :json)
    assert Map.new(pairs) == Map.new(@flows)
  end

  # tar / zip run only where their backend is present (the dev OTP here lacks a
  # standard :zip); they fully exercise in the release image.
  test "tar round-trips" do
    if Bundle.available?(:tar) do
      assert {:ok, {bytes, "home-elixir-flows.tar", "application/x-tar"}} = Bundle.produce(@flows, :tar)
      assert {:ok, pairs} = Bundle.consume(bytes, :tar)
      assert Map.new(pairs) == Map.new(@flows)
    end
  end

  test "zip round-trips" do
    if Bundle.available?(:zip) do
      assert {:ok, {bytes, "home-elixir-flows.zip", "application/zip"}} = Bundle.produce(@flows, :zip)
      assert {:ok, pairs} = Bundle.consume(bytes, :zip)
      assert Map.new(pairs) == Map.new(@flows)
    end
  end

  test "consume a bad archive yields no flows" do
    case Bundle.consume("definitely not an archive", :tar) do
      {:ok, pairs} -> assert pairs == []
      {:error, _} -> :ok
    end

    assert {:error, _} = Bundle.consume("not json", :json)
  end

  test "parse_format maps strings" do
    assert Bundle.parse_format("zip") == :zip
    assert Bundle.parse_format("tar") == :tar
    assert Bundle.parse_format("json") == :json
    assert Bundle.parse_format("nope") == :none
  end
end
