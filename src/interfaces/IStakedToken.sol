// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.23;

interface IStakedToken {

    function totalAssets() external view returns (uint256);
    function convertToAssets(
        uint256 _shares
    ) external view returns (uint256);
    function yieldSharing() external view returns (address);

}
