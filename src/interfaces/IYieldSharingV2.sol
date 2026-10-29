// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.23;

interface IYieldSharingV2 {

    function vesting() external view returns (uint256);
    function vested() external view returns (uint256);
    function point() external view returns (uint32 lastAccrued, uint32 lastClaimed, uint208 rate);

}
