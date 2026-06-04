// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.18;

interface IExchange {
    function name() external pure returns (string memory);

    function exchange(
        address from,
        address to,
        uint256 amountIn,
        uint256 amountOutMin
    ) external returns (uint256 amountOut);
}
