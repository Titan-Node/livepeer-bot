// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {UnitBase} from "./Base.t.sol";
import {LivepeerRewardCaller} from "../../src/LivepeerRewardCaller.sol";
import {IController} from "../../src/interfaces/IController.sol";
import {MockController} from "./mocks/MockController.sol";

contract ConstructorTest is UnitBase {
    function test_RevertWhen_ControllerIsZero() public {
        vm.expectRevert(LivepeerRewardCaller.ZeroAddress.selector);
        new LivepeerRewardCaller(IController(address(0)));
    }

    function test_RevertWhen_BondingManagerUnresolved() public {
        MockController bare = new MockController();
        bare.setContract(ROUNDS_MANAGER_ID, address(rounds)); // rounds resolves, bonding does not
        vm.expectRevert(LivepeerRewardCaller.ZeroAddress.selector);
        new LivepeerRewardCaller(IController(address(bare)));
    }

    function test_RevertWhen_RoundsManagerUnresolved() public {
        MockController bare = new MockController();
        bare.setContract(BONDING_MANAGER_ID, address(bm)); // bonding resolves, rounds does not
        vm.expectRevert(LivepeerRewardCaller.ZeroAddress.selector);
        new LivepeerRewardCaller(IController(address(bare)));
    }

    function test_Deploy_StoresControllerAndConstants() public view {
        assertEq(address(rc.CONTROLLER()), address(controller));
        assertEq(rc.MIN_CALL_GAS(), 2_500_000);
        assertEq(rc.BASE_CALL_GAS(), 1_500_000);
        assertEq(rc.PER_NODE_MARGIN(), 10_000);
        assertEq(rc.CALL_GAS_RESERVE(), 150_000);
    }
}
