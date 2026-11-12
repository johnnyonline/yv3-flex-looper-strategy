// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.23;

interface ILidoWithdrawalQueue {

    struct WithdrawalRequestStatus {
        uint256 amountOfStETH;
        uint256 amountOfShares;
        address owner;
        uint256 timestamp;
        bool isFinalized;
        bool isClaimed;
    }

    function getWithdrawalStatus(
        uint256[] calldata _requestIds
    ) external view returns (WithdrawalRequestStatus[] memory);

    function requestWithdrawals(
        uint256[] calldata _amounts,
        address _owner
    ) external returns (uint256[] memory requestIds);

    function claimWithdrawal(
        uint256 _requestId
    ) external;

    function claimWithdrawals(
        uint256[] calldata _requestIds,
        uint256[] calldata _hints
    ) external;

}
