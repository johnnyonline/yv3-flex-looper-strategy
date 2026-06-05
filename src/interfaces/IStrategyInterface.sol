// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {IStrategy} from "@tokenized-strategy/interfaces/IStrategy.sol";

interface IStrategyInterface is IStrategy {
    // Immutables / config
    function TROVE_MANAGER() external view returns (address);
    function ALLOW_REDEMPTION() external view returns (bool);
    function MIN_DEBT() external view returns (uint256);
    function MCR() external view returns (uint256);

    // State
    function troveId() external view returns (uint256);
    function debtInFrontHintPrev() external view returns (uint256);
    function debtInFrontHintNext() external view returns (uint256);

    // Management
    function openTrove(uint256 _assetToSeed, uint256 _annualInterestRate, uint256 _prevId, uint256 _nextId)
        external
        returns (uint256);
    function adjustInterestRate(
        uint256 _newAnnualInterestRate,
        uint256 _prevId,
        uint256 _nextId,
        uint256 _maxUpfrontFee
    ) external;
    function setDebtInFrontHints(uint256 _hintPrev, uint256 _hintNext) external;
}
