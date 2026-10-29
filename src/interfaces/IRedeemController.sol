// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.23;

interface IRedeemController {

    function receiptToAsset(
        uint256 _receiptAmount
    ) external view returns (uint256);
    function userPendingClaims(
        address _user
    ) external view returns (uint256);
    function totalEnqueuedRedemptions() external view returns (uint256);
    function queueLength() external view returns (uint256);

}
