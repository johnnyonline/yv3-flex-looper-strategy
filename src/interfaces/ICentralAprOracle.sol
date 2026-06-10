// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.23;

interface ICentralAprOracle {

    function getStrategyApr(
        address _strategy,
        int256 _debtChange
    ) external view returns (uint256);

}
