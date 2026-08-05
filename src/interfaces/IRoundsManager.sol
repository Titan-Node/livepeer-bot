// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @notice Minimal interface to the Livepeer RoundsManager.
/// @dev Arbitrum One: 0xdd6f56DcC28D3F5f27084381fE8Df634985cc39f
interface IRoundsManager {
    /// @notice Current round number, derived purely from block numbers (no storage).
    function currentRound() external view returns (uint256);

    /// @notice True once someone has called initializeRound() for the current round.
    function currentRoundInitialized() external view returns (bool);

    /// @notice Permissionless once-per-round initialization; reward calls revert until it runs.
    function initializeRound() external;

    /// @notice Round length in blocks (used only in tests).
    function roundLength() external view returns (uint256);
}
