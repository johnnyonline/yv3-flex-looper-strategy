// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

interface IDebtInFrontHelper {
    /// @notice Total debt of troves with rate in [low, high) — i.e. what a
    ///         borrower at `high` can redeem.
    function get_debt_in_front(
        address troveManager,
        uint256 interestRateLow,
        uint256 interestRateHigh,
        uint256 stopAtTroveId,
        uint256 hintPrevId,
        uint256 hintNextId
    ) external view returns (uint256);
}
