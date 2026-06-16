// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import {Setup, ERC20, IStrategyInterface} from "./utils/Setup.sol";
import {ITroveManager} from "../interfaces/ITroveManager.sol";

contract ShutdownTest is Setup {

    function setUp() public virtual override {
        super.setUp();
    }

    function test_shutdownCanWithdraw(
        uint256 _amount
    ) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // Deposit and lever up to target
        mintAndDepositIntoStrategy(strategy, user, _amount);
        vm.prank(keeper);
        strategy.tend();
        _assertAtTargetLeverage();

        // Earn interest and report
        accrueYield(_amount);
        vm.prank(keeper);
        strategy.report();

        // Shut the strategy down
        vm.prank(emergencyAdmin);
        strategy.shutdownStrategy();

        // Deposits are paused but the levered position is untouched
        assertEq(strategy.maxDeposit(user), 0, "!deposit paused");
        _assertAtTargetLeverage();

        // Skip time to avoid delevering on the same block as the last trove touch
        skip(1 seconds);

        // The user can still withdraw their full position; the strategy delevers to free it
        vm.startPrank(user);
        strategy.redeem(strategy.balanceOf(user), user, user);
        vm.stopPrank();
        assertGe(asset.balanceOf(user), _amount, "!user recovered");

        // The remaining seed position is still levered to target
        _assertAtTargetLeverage();
    }

    function test_emergencyWithdraw_maxUint(
        uint256 _amount
    ) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // Seeder shares == its deposit (minted at PPS 1 in setUp)
        uint256 seederDeposit = strategy.balanceOf(seeder);

        // Deposit and lever up to target
        mintAndDepositIntoStrategy(strategy, user, _amount);
        vm.prank(keeper);
        strategy.tend();
        _assertAtTargetLeverage();

        // Earn interest and report
        accrueYield(_amount);
        vm.prank(keeper);
        strategy.report();

        // Skip time to avoid closing on the same block as the last trove touch
        skip(1 seconds);

        // Shut down and emergency-close the Trove; the partial-conversion close leaves equity loose
        vm.prank(emergencyAdmin);
        strategy.shutdownStrategy();
        vm.prank(emergencyAdmin);
        strategy.emergencyWithdraw(type(uint256).max);

        // Realize the equity the close left as loose collateral
        vm.prank(emergencyAdmin);
        strategy.convertCollateralToAsset(type(uint256).max);

        // The trove is fully closed: nothing is borrowed and all value is idle
        assertEq(strategy.balanceOfDebt(), 0, "!debt");
        assertEq(ITroveManager(troveManager).troves(strategy.troveId()).collateral, 0, "!trove emptied");

        // Both the user and the seeder withdraw and get back at least what they put in
        vm.startPrank(user);
        strategy.redeem(strategy.balanceOf(user), user, user);
        vm.stopPrank();
        assertGe(asset.balanceOf(user), _amount, "!user recovered");

        vm.startPrank(seeder);
        strategy.redeem(strategy.balanceOf(seeder), seeder, seeder);
        vm.stopPrank();
        assertGe(asset.balanceOf(seeder), seederDeposit, "!seeder recovered");
    }

}
