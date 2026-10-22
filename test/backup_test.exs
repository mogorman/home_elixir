defmodule HomeElixir.BackupTest do
  use ExUnit.Case, async: false

  alias HomeElixir.{Backup, Auth, Config, FlowState}

  @flow_name "bk_flow"
  @flow_src "defmodule HomeElixir.Flows.BkFlow do\n  use HomeElixir.Flow\nend\n"
  @mod String.to_atom("Elixir.HomeElixir.Flows.BkFlow")

  setup do
    tmp = Path.join(System.tmp_dir!(), "backup_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    File.write!(Path.join(tmp, @flow_name <> ".ex"), @flow_src)
    Application.put_env(:home_elixir, :flows_dir, tmp)

    # Seed one value in each section of the backup.
    Auth.create_user("bk_alice", "secret123", "user")
    Config.put_global(:bk_key, "bk_value")
    FlowState.set_flow_owner(@flow_name, "bk_alice")
    FlowState.as(@mod, fn -> FlowState.put(:count, 41) end)

    on_exit(fn ->
      Application.put_env(:home_elixir, :flows_dir, "flows")
      File.rm_rf!(tmp)

      Auth.delete_user("bk_alice")
      Config.delete(:global, :bk_key)
      FlowState.clear_flow_owner(@flow_name)
      FlowState.as(@mod, fn -> FlowState.delete(:count) end)
    end)

    :ok
  end

  defp flow_path, do: Path.join(Application.get_env(:home_elixir, :flows_dir), @flow_name <> ".ex")

  test "snapshot then restore round-trips all state" do
    doc = Backup.snapshot()

    assert doc["home_elixir_backup"] == 1
    assert Map.get(doc["flows"], @flow_name) == @flow_src
    assert Enum.any?(doc["users"], &(&1["name"] == "bk_alice"))

    # Erase everything we seeded.
    Auth.delete_user("bk_alice")
    Config.delete(:global, :bk_key)
    FlowState.clear_flow_owner(@flow_name)
    FlowState.as(@mod, fn -> FlowState.delete(:count) end)
    File.rm!(flow_path())

    # Confirm it's gone.
    refute Enum.any?(Auth.list_users(), &(&1[:name] == "bk_alice"))
    assert is_nil(Config.get(:bk_key))
    assert is_nil(FlowState.flow_owner(@flow_name))
    refute File.exists?(flow_path())

    # Restore from the snapshot.
    summary = Backup.restore(doc)
    assert summary[:ok] == true
    assert summary[:flows] >= 1
    assert summary[:users] >= 1

    # Confirm it's all back.
    assert File.read!(flow_path()) == @flow_src
    assert Enum.any?(Auth.list_users(), &(&1[:name] == "bk_alice"))
    assert Config.get(:bk_key) == "bk_value"
    assert FlowState.flow_owner(@flow_name) == "bk_alice"
    assert FlowState.as(@mod, fn -> FlowState.get(:count) end) == 41
  end

  test "restore rejects a document without the magic key" do
    assert_raise ArgumentError, fn -> Backup.restore(%{"foo" => "bar"}) end
  end
end
