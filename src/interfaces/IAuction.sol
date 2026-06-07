// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.23;

interface IAuction {

    function buy_token() external view returns (address); // borrow token (asset)
    function sell_token() external view returns (address); // collateral
    function take(
        uint256 auctionId,
        uint256 maxTakeAmount,
        address receiver,
        bytes calldata data
    ) external returns (uint256);

}
