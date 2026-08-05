// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IRoundsManager} from "../../../src/interfaces/IRoundsManager.sol";

/// @notice Settable model of the Livepeer RoundsManager.
///
///         `initializeRound()` flips the initialized flag (optionally bumping the round
///         number so tests can prove the caller reads `currentRound` AFTER initializing),
///         or reverts on demand with a settable reason shape: Error(string), a custom
///         error, or empty revert data.
contract MockRoundsManager is IRoundsManager {
    enum InitMode {
        Succeed,
        RevertString,
        RevertCustom,
        RevertEmpty
    }

    error InitializeBroken(uint256 code);

    uint256 public constant INIT_CUSTOM_CODE = 123;

    uint256 internal _round;
    bool internal _initialized;
    uint256 internal _roundLength = 6377;
    InitMode internal _initMode;
    string internal _initRevertReason = "MOCK_ROUND_NOT_INITIALIZABLE";
    bool internal _bumpRoundOnInit;

    /// @notice How many times initializeRound() was invoked (reverted attempts roll back).
    uint256 public initializeRoundCalls;

    // ------------------------------------------------------------ IRoundsManager
    function currentRound() external view returns (uint256) {
        return _round;
    }

    function currentRoundInitialized() external view returns (bool) {
        return _initialized;
    }

    function roundLength() external view returns (uint256) {
        return _roundLength;
    }

    function initializeRound() external {
        initializeRoundCalls++;
        if (_initMode == InitMode.RevertString) revert(_initRevertReason);
        if (_initMode == InitMode.RevertCustom) revert InitializeBroken(INIT_CUSTOM_CODE);
        if (_initMode == InitMode.RevertEmpty) revert();
        _initialized = true;
        if (_bumpRoundOnInit) _round += 1;
    }

    // ------------------------------------------------------------ test knobs
    function setCurrentRound(uint256 _r) external {
        _round = _r;
    }

    function setInitialized(bool _i) external {
        _initialized = _i;
    }

    function setRoundLength(uint256 _l) external {
        _roundLength = _l;
    }

    function setInitMode(InitMode _m) external {
        _initMode = _m;
    }

    function setInitRevertReason(string calldata _reason) external {
        _initRevertReason = _reason;
    }

    function setBumpRoundOnInit(bool _b) external {
        _bumpRoundOnInit = _b;
    }

    function initRevertReason() external view returns (string memory) {
        return _initRevertReason;
    }
}
