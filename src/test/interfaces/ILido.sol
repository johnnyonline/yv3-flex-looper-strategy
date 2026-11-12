// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.23;

interface ILidoQueue {

    function finalize(
        uint256 _lastRequestIdToBeFinalized,
        uint256 _maxShareRate
    ) external payable;

    function prefinalize(
        uint256[] calldata _batches,
        uint256 _maxShareRate
    ) external view returns (uint256 ethToLock, uint256 sharesToBurn);

    function findCheckpointHints(
        uint256[] calldata _requestIds,
        uint256 _firstIndex,
        uint256 _lastIndex
    ) external view returns (uint256[] memory hintIds);

    function getLastCheckpointIndex() external view returns (uint256);

}

interface IStETH {

    function getPooledEthByShares(
        uint256 _sharesAmount
    ) external view returns (uint256);

}
