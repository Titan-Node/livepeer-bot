// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @notice Minimal interface to the Livepeer Controller (registry + pause switch).
/// @dev Arbitrum One: 0xD8E8328501E9645d16Cf49539efC04f734606ee4
interface IController {
    /// @notice Resolve a registered contract address by id, where id = keccak256(contractName).
    function getContract(bytes32 _id) external view returns (address);

    /// @notice True when the whole protocol is paused.
    function paused() external view returns (bool);

    /// @notice Governance owner of the Controller (used only in tests).
    function owner() external view returns (address);
}
