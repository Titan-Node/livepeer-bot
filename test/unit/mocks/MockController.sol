// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IController} from "../../../src/interfaces/IController.sol";

/// @notice Minimal settable model of the Livepeer Controller (registry + pause switch).
contract MockController is IController {
    mapping(bytes32 => address) internal _registry;
    bool internal _paused;
    address internal _owner;

    // ------------------------------------------------------------ IController
    function getContract(bytes32 _id) external view returns (address) {
        return _registry[_id];
    }

    function paused() external view returns (bool) {
        return _paused;
    }

    function owner() external view returns (address) {
        return _owner;
    }

    // ------------------------------------------------------------ test knobs
    function setContract(bytes32 _id, address _addr) external {
        _registry[_id] = _addr;
    }

    function setPaused(bool _p) external {
        _paused = _p;
    }

    function setOwner(address _o) external {
        _owner = _o;
    }
}
