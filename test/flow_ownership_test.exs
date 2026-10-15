defmodule HomeElixir.FlowOwnershipTest do
  use ExUnit.Case, async: false

  alias HomeElixir.FlowState

  setup_all do
    FlowState.start()
    :ok
  end

  test "flow_owner / set_flow_owner" do
    FlowState.set_flow_owner("flow_a", "alice")
    assert FlowState.flow_owner("flow_a") == "alice"
    assert FlowState.flow_owner("nope") == nil
  end

  test "assign_owner_if_new only claims unowned flows" do
    assert FlowState.assign_owner_if_new("flow_b", "bob") == "bob"
    # A second, different user does not steal it.
    assert FlowState.assign_owner_if_new("flow_b", "mallory") == "bob"
    # An unowned flow gets claimed.
    assert FlowState.assign_owner_if_new("flow_c", "carol") == "carol"
  end

  test "owned_flow_names lists only the owner's flows" do
    FlowState.set_flow_owner("mine_1", "owner_x")
    FlowState.set_flow_owner("mine_2", "owner_x")
    FlowState.set_flow_owner("yours", "owner_y")

    assert Enum.sort(FlowState.owned_flow_names("owner_x")) == ["mine_1", "mine_2"]
    assert FlowState.owned_flow_names("owner_y") == ["yours"]
    assert FlowState.owned_flow_names("nobody") == []
  end

  test "all_flow_owners returns the name => owner map" do
    FlowState.set_flow_owner("mapped", "zed")
    owners = FlowState.all_flow_owners()
    assert owners["mapped"] == "zed"
  end
end
