// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import {Setup, ERC20, IStrategyInterface} from "./utils/Setup.sol";
import {ITroveManager} from "../interfaces/ITroveManager.sol";
import {ExchangeMock} from "./mocks/ExchangeMock.sol";

/// @notice Auction-take tests that need a lossy exchange, so they run against the
///         configurable mock instead of the real vault exchange
contract AuctionLossTest is Setup {

    function setUp() public virtual override {
        super.setUp();
    }

    function _deployExchange() internal override returns (address) {
        return address(new ExchangeMock(address(asset), yvusd, address(ITroveManager(troveManager).price_oracle())));
    }

    function test_operation_auctionTakeWithLoss(
        uint256 _amount,
        uint256 _keep
    ) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount / 10);
        _keep = bound(_keep, 0, _amount);

        // Lossy collateral -> asset swaps only, within the strategy's slippage tolerance
        ExchangeMock(exchange).setSlippage(0, 10);

        // Not enough idle, so the borrow must redeem and take the auction
        _drainLenderIdle(_keep);
        mintAndDepositIntoStrategy(strategy, user, _amount);

        // The auction-take step reverts bc we don't have enough assets to pay what's needed to take the auction
        vm.prank(keeper);
        vm.expectRevert();
        strategy.tend();
    }

}
