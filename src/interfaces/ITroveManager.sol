// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

interface ITroveManager {
    // Vyper flag `Status` ABI-encodes as uint256; every field is a 32-byte slot.
    struct Trove {
        uint256 debt;
        uint256 collateral;
        uint256 annualInterestRate;
        uint64 lastDebtUpdateTime;
        uint64 lastInterestRateAdjTime;
        address owner;
        uint256 status;
    }

    function borrow_token() external view returns (address);
    function collateral_token() external view returns (address);
    function price_oracle() external view returns (address);
    function lender() external view returns (address);
    function dutch_desk() external view returns (address);
    function min_debt() external view returns (uint256);
    function minimum_collateral_ratio() external view returns (uint256); // WAD, e.g. 1.1e18

    function troves(uint256 troveId) external view returns (Trove memory);
    function get_trove_debt_after_interest(uint256 troveId) external view returns (uint256);

    function open_trove(
        uint256 ownerIndex,
        uint256 collateralAmount,
        uint256 debtAmount,
        uint256 prevId,
        uint256 nextId,
        uint256 annualInterestRate,
        uint256 maxUpfrontFee,
        uint256 minBorrowOut,
        uint256 minCollateralOut,
        address owner
    ) external returns (uint256);
    function add_collateral(uint256 troveId, uint256 collateralAmount) external;
    function remove_collateral(uint256 troveId, uint256 collateralAmount) external;
    function borrow(
        uint256 troveId,
        uint256 debtAmount,
        uint256 maxUpfrontFee,
        uint256 minBorrowOut,
        uint256 minCollateralOut
    ) external;
    function repay(uint256 troveId, uint256 debtAmount) external;
    function close_trove(uint256 troveId) external;
}
