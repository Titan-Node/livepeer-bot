// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {LivepeerRewardCaller} from "../../src/LivepeerRewardCaller.sol";
import {IController} from "../../src/interfaces/IController.sol";
import {MockController} from "./mocks/MockController.sol";
import {MockRoundsManager} from "./mocks/MockRoundsManager.sol";
import {MockBondingManager} from "./mocks/MockBondingManager.sol";

/// @notice Shared harness for the LivepeerRewardCaller unit suite.
abstract contract UnitBase is Test {
    bytes32 internal constant BONDING_MANAGER_ID = keccak256("BondingManager");
    bytes32 internal constant ROUNDS_MANAGER_ID = keccak256("RoundsManager");
    uint256 internal constant ROUND = 1500;

    // topic0 of the reward caller's events
    bytes32 internal constant SIG_ROUND_INITIALIZED = keccak256("RoundInitialized(uint256,address)");
    bytes32 internal constant SIG_SUCCEEDED = keccak256("RewardCallSucceeded(uint256,address,address,uint256)");
    bytes32 internal constant SIG_FAILED = keccak256("RewardCallFailed(uint256,address,address,bytes)");
    bytes32 internal constant SIG_BATCH = keccak256("BatchProcessed(uint256,address,uint256,uint256,uint256,bool)");

    // Local redeclarations of the contract's events for vm.expectEmit.
    event RoundInitialized(uint256 indexed round, address indexed caller);
    event RewardCallSucceeded(uint256 indexed round, address indexed transcoder, address indexed caller, uint256 gasUsed);
    event RewardCallFailed(uint256 indexed round, address indexed transcoder, address indexed caller, bytes revertData);
    event BatchProcessed(
        uint256 indexed round, address indexed caller, uint256 processed, uint256 rewarded, uint256 failed, bool complete
    );

    MockController internal controller;
    MockRoundsManager internal rounds;
    MockBondingManager internal bm;
    LivepeerRewardCaller internal rc;

    address internal keeper = makeAddr("keeper");

    function setUp() public virtual {
        _freshDeploy();
    }

    /// @dev Fresh mocks + fresh reward caller wired through a fresh controller.
    function _freshDeploy() internal {
        controller = new MockController();
        rounds = new MockRoundsManager();
        bm = new MockBondingManager();
        controller.setContract(BONDING_MANAGER_ID, address(bm));
        controller.setContract(ROUNDS_MANAGER_ID, address(rounds));
        _setRound(ROUND, true);
        rc = new LivepeerRewardCaller(IController(address(controller)));
    }

    /// @dev Keep the two mocks' notion of the current round in sync.
    function _setRound(uint256 _r, bool _initialized) internal {
        rounds.setCurrentRound(_r);
        rounds.setInitialized(_initialized);
        bm.setCurrentRound(_r);
    }

    /// @dev Add a transcoder to the mock pool with the three predicate dimensions.
    function _addT(address _t, uint256 _stake, bool _subscribed, bool _active, uint256 _lastRewardRound) internal {
        bm.addToPool(_t, _stake);
        bm.setActive(_t, _active);
        bm.setLastRewardRound(_t, _lastRewardRound);
        if (_subscribed) bm.setRewardCallerFor(_t, address(rc));
    }

    /// @dev Subscribed + active + unrewarded: a sweep must reward it.
    function _addGood(address _t, uint256 _stake) internal {
        _addT(_t, _stake, true, true, 0);
    }

    /// @dev Subscribed+active+unrewarded node whose reward burns ~_burn gas, then succeeds.
    function _addBurner(address _t, uint256 _stake, uint256 _burn) internal {
        _addGood(_t, _stake);
        bm.setFailureMode(_t, MockBondingManager.FailureMode.BurnThenSucceed);
        bm.setBurnAmount(_t, _burn);
    }

    // ---------------------------------------------------------------- slot helpers
    // Mirror MockBondingManager's storage layout (slots 0,1,2) so pre-check invocation
    // order can be reconstructed from vm.record()/vm.accesses() read traces.

    function _slotSubscribed(address _t) internal pure returns (bytes32) {
        return keccak256(abi.encode(_t, uint256(0)));
    }

    function _slotLastReward(address _t) internal pure returns (bytes32) {
        return keccak256(abi.encode(_t, uint256(1)));
    }

    function _slotActive(address _t) internal pure returns (bytes32) {
        return keccak256(abi.encode(_t, uint256(2)));
    }

    /// @dev Filter a raw read-slot trace down to pre-check reads on the given transcoders.
    ///      tag 1 = [a] transcoderToRewardCaller, 2 = [b] getTranscoder, 3 = [c] isActiveTranscoder.
    function _precheckTrace(bytes32[] memory _readSlots, address[] memory _ts)
        internal
        pure
        returns (uint8[] memory tags, address[] memory whos)
    {
        tags = new uint8[](_readSlots.length);
        whos = new address[](_readSlots.length);
        uint256 n;
        for (uint256 i; i < _readSlots.length; ++i) {
            for (uint256 j; j < _ts.length; ++j) {
                if (_readSlots[i] == _slotSubscribed(_ts[j])) {
                    tags[n] = 1;
                    whos[n] = _ts[j];
                    ++n;
                    break;
                }
                if (_readSlots[i] == _slotLastReward(_ts[j])) {
                    tags[n] = 2;
                    whos[n] = _ts[j];
                    ++n;
                    break;
                }
                if (_readSlots[i] == _slotActive(_ts[j])) {
                    tags[n] = 3;
                    whos[n] = _ts[j];
                    ++n;
                    break;
                }
            }
        }
        assembly ("memory-safe") {
            mstore(tags, n)
            mstore(whos, n)
        }
    }

    // ---------------------------------------------------------------- log helpers

    /// @dev Count events with `_sig` emitted by the reward caller.
    function _countLogs(Vm.Log[] memory _logs, bytes32 _sig) internal view returns (uint256 c) {
        for (uint256 i; i < _logs.length; ++i) {
            if (_logs[i].emitter == address(rc) && _logs[i].topics[0] == _sig) ++c;
        }
    }

    /// @dev Count + decode of the LAST BatchProcessed emitted by the reward caller.
    function _batchStats(Vm.Log[] memory _logs)
        internal
        view
        returns (uint256 count, uint256 processed, uint256 rewarded, uint256 failed, bool complete)
    {
        for (uint256 i; i < _logs.length; ++i) {
            if (_logs[i].emitter == address(rc) && _logs[i].topics[0] == SIG_BATCH) {
                ++count;
                (processed, rewarded, failed, complete) = abi.decode(_logs[i].data, (uint256, uint256, uint256, bool));
            }
        }
    }

    /// @dev Walk the mock pool head-to-tail.
    function _walkPool() internal view returns (address[] memory order) {
        order = new address[](bm.getTranscoderPoolSize());
        uint256 n;
        address t = bm.getFirstTranscoderInPool();
        while (t != address(0)) {
            order[n++] = t;
            t = bm.getNextTranscoderInPool(t);
        }
        assembly ("memory-safe") {
            mstore(order, n)
        }
    }

    // ---------------------------------------------------------------- array builders
    function _arr(address _a) internal pure returns (address[] memory r) {
        r = new address[](1);
        r[0] = _a;
    }

    function _arr(address _a, address _b) internal pure returns (address[] memory r) {
        r = new address[](2);
        r[0] = _a;
        r[1] = _b;
    }

    function _arr(address _a, address _b, address _c) internal pure returns (address[] memory r) {
        r = new address[](3);
        r[0] = _a;
        r[1] = _b;
        r[2] = _c;
    }

    function _arr(address _a, address _b, address _c, address _d) internal pure returns (address[] memory r) {
        r = new address[](4);
        r[0] = _a;
        r[1] = _b;
        r[2] = _c;
        r[3] = _d;
    }

    function _zeros(uint256 _n) internal pure returns (address[] memory r) {
        r = new address[](_n);
    }
}
