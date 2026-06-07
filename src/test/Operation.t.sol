// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import "forge-std/console2.sol";
import {Setup, ERC20, IStrategyInterface} from "./utils/Setup.sol";
import {ITroveManager} from "../interfaces/ITroveManager.sol";

contract OperationTest is Setup {

    function setUp() public virtual override {
        super.setUp();
    }

    function test_setupStrategyOK() public view {
        assertTrue(address(0) != address(strategy), "E0");
        assertEq(strategy.asset(), address(asset), "E1");
        assertEq(strategy.management(), management, "E2");
        assertEq(strategy.performanceFeeRecipient(), performanceFeeRecipient, "E3");
        assertEq(strategy.keeper(), keeper, "E4");
        assertEq(strategy.collateralToken(), yvusd, "E5");
        assertEq(strategy.GOVERNANCE(), management, "E6");
        assertEq(strategy.exchange(), exchange, "E7");
        assertEq(strategy.depositLimit(), type(uint256).max, "E8");
        assertEq(strategy.targetLeverageRatio(), 3e18, "E9");
        assertEq(strategy.leverageBuffer(), 0.25e18, "E10");
        assertEq(strategy.maxLeverageRatio(), 4e18, "E11");
        assertEq(strategy.minTendInterval(), 2 hours, "E12");
        assertEq(strategy.maxAmountToSwap(), type(uint256).max, "E13");
        assertEq(strategy.slippage(), 30, "E14");
        assertEq(strategy.minAmountToBorrow(), 100, "E15");
        assertEq(strategy.lossLimitRatio(), 10, "E16");
        assertEq(strategy.profitLimitRatio(), 500, "E17");
        assertTrue(strategy.allowed(address(strategy)), "E18");
        assertEq(strategy.TROVE_MANAGER(), troveManager, "E19");
        assertTrue(strategy.ALLOW_REDEMPTION(), "E20");
        assertEq(strategy.LENDER(), ITroveManager(troveManager).lender(), "E21");
        assertEq(strategy.DUTCH_DESK(), address(ITroveManager(troveManager).dutch_desk()), "E22");
        assertEq(strategy.AUCTION(), address(ITroveManager(troveManager).dutch_desk().auction()), "E23");
        assertEq(strategy.ORACLE(), address(ITroveManager(troveManager).price_oracle()), "E24");
        assertEq(strategy.MIN_DEBT(), ITroveManager(troveManager).min_debt(), "E25");
        assertEq(
            strategy.MCR(), ITroveManager(troveManager).minimum_collateral_ratio() * 1e18 / (10 ** decimals), "E26"
        );
    }

    function test_operation(
        uint256 _amount
    ) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        // Deploy funds via tend (since _deployFunds is empty to prevent sandwich attacks)
        vm.prank(keeper);
        strategy.tend();

        logStrategyStatus("After deposit");

        assertGt(strategy.totalAssets(), 0, "!totalAssets");

        // Levered to target with the expected collateral and debt
        _assertAtTargetLeverage();

        // Earn Interest
        accrueYield(_amount);

        // Report profit
        vm.prank(keeper);
        strategy.report();

        logStrategyStatus("After profit max unlock time");

        uint256 balanceBefore = asset.balanceOf(user);

        // Skip time to avoid closing on the same block
        skip(1 seconds);

        // Withdraw all funds
        vm.prank(user);
        strategy.redeem(_amount, user, user);

        assertGe(asset.balanceOf(user), balanceBefore, "!final balance");

        // Remaining position still levered to target after the withdraw
        _assertAtTargetLeverage();
    }

    function test_profitableReport(
        uint256 _amount
    ) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        // Deploy funds via tend (since _deployFunds is empty to prevent sandwich attacks)
        vm.prank(keeper);
        strategy.tend();

        logStrategyStatus("After deposit");

        assertGt(strategy.totalAssets(), 0, "!totalAssets");

        // Levered to target with the expected collateral and debt
        _assertAtTargetLeverage();

        // Earn Interest
        accrueYield(_amount);

        uint256 pricePerShareBefore = strategy.pricePerShare();

        // Report profit
        vm.prank(keeper);
        (uint256 profit, uint256 loss) = strategy.report();

        // Check return Values
        assertGt(profit, 0, "!profit");
        assertEq(loss, 0, "!loss");

        assertGt(strategy.pricePerShare(), pricePerShareBefore, "!pps");

        uint256 balanceBefore = asset.balanceOf(user);

        // Skip time to avoid closing on the same block
        skip(1 seconds);

        // Withdraw all funds
        vm.prank(user);
        strategy.redeem(_amount, user, user);

        assertGe(asset.balanceOf(user), balanceBefore, "!final balance");

        // Remaining position still levered to target after the withdraw
        _assertAtTargetLeverage();
    }

    function test_profitableReport_withFees(
        uint256 _amount
    ) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // Set protocol fee to 0 and perf fee to 10%
        setFees(0, 1_000);

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        // Deploy funds via tend (since _deployFunds is empty to prevent sandwich attacks)
        vm.prank(keeper);
        strategy.tend();

        logStrategyStatus("After deposit");

        assertGt(strategy.totalAssets(), 0, "!totalAssets");

        // Levered to target with the expected collateral and debt
        _assertAtTargetLeverage();

        // Earn Interest
        accrueYield(_amount);

        // Report profit
        vm.prank(keeper);
        (uint256 profit, uint256 loss) = strategy.report();

        // Check return Values
        assertGt(profit, 0, "!profit");
        assertEq(loss, 0, "!loss");

        // Get the expected fee
        uint256 expectedShares = (profit * 1_000) / MAX_BPS;

        assertEq(strategy.balanceOf(performanceFeeRecipient), expectedShares, "!perf fee shares");

        uint256 balanceBefore = asset.balanceOf(user);

        // Skip time to avoid closing on the same block
        skip(1 seconds);

        // Withdraw all funds
        vm.prank(user);
        strategy.redeem(_amount, user, user);

        assertGe(asset.balanceOf(user), balanceBefore, "!final balance");

        // Remaining position still levered to target after the withdraw
        _assertAtTargetLeverage();

        // Skip time to avoid closing on the same block
        skip(1 seconds);

        vm.prank(performanceFeeRecipient);
        strategy.redeem(expectedShares, performanceFeeRecipient, performanceFeeRecipient);

        assertGt(asset.balanceOf(performanceFeeRecipient), 0, "!perf fee out");
    }

    function test_operation_noIdleLiquidity(
        uint256 _amount,
        uint256 _keep
    ) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);
        _keep = bound(_keep, 0, _amount);

        // Deposit, then leave only `_keep` idle in the lender so the lever-up must redeem the rest
        mintAndDepositIntoStrategy(strategy, user, _amount);
        _drainLenderIdle(_keep);

        uint256 nonceBefore = ITroveManager(troveManager).dutch_desk().nonce();

        // Deploy funds via tend (since _deployFunds is empty to prevent sandwich attacks)
        vm.prank(keeper);
        strategy.tend();

        logStrategyStatus("After tend");

        // We redeemed at least some of what we wanted to borrow
        assertGt(ITroveManager(troveManager).dutch_desk().nonce(), nonceBefore, "!redeemed");

        // Position still levered to target, sourced via redemption
        _assertAtTargetLeverage();
    }

    function test_operation_leverageCappedByLiquidity(
        uint256 _amount,
        uint256 _keep
    ) public {
        _amount = bound(_amount, maxFuzzAmount, maxFuzzAmount * 100);
        _keep = bound(_keep, 0, _amount);

        // Deposit, then leave only `_keep` idle in the lender so the lever-up must redeem the rest
        mintAndDepositIntoStrategy(strategy, user, _amount);
        _drainLenderIdle(_keep);

        uint256 nonceBefore = ITroveManager(troveManager).dutch_desk().nonce();

        // Deploy funds via tend (since _deployFunds is empty to prevent sandwich attacks)
        vm.prank(keeper);
        strategy.tend();

        logStrategyStatus("After tend");

        // Redemption was used, but the borrow is capped by available liquidity so we land below target
        assertGt(ITroveManager(troveManager).dutch_desk().nonce(), nonceBefore, "!redeemed");

        assertGt(strategy.getCurrentLeverageRatio(), 1e18, "!levered up");
    }

    function test_operation_redemptionToZombie(
        uint256 _amount
    ) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount / 10);

        // Seeder shares == its deposit (minted at PPS 1 in setUp)
        uint256 seederDeposit = strategy.balanceOf(seeder);

        // Deposit and lever up to target
        mintAndDepositIntoStrategy(strategy, user, _amount);
        vm.prank(keeper);
        strategy.tend();
        _assertAtTargetLeverage();

        uint256 debtBefore = strategy.balanceOfDebt();

        // Redeem our position below MIN_DEBT, turning the trove into a zombie
        simulateCollateralRedemption(true);
        logStrategyStatus("After redemption");

        // Debt fell below MIN_DEBT and supply/borrow are paused, withdraws limited to idle
        assertLt(strategy.balanceOfDebt(), debtBefore, "!debt");
        assertLt(strategy.balanceOfDebt(), strategy.MIN_DEBT(), "!below min debt");
        assertEq(strategy.availableDepositLimit(user), 0, "!deposit paused");
        assertEq(strategy.availableWithdrawLimit(user), strategy.balanceOfAsset(), "!withdraw idle only");

        // Earn interest and report while still a zombie
        accrueYield(_amount);
        vm.prank(keeper);
        strategy.report();

        // Skip time to avoid touching the trove in the same block as the redemption
        skip(1 seconds);

        // Recover via shutdown + emergency withdraw: closes the zombie and frees the collateral
        vm.prank(emergencyAdmin);
        strategy.shutdownStrategy();
        vm.prank(emergencyAdmin);
        strategy.emergencyWithdraw(type(uint256).max);

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

    // @todo -- here test operation redemption no zombie

    function test_tendTrigger(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        (bool trigger, ) = strategy.tendTrigger();
        assertTrue(!trigger);

        mintAndDepositIntoStrategy(strategy, user, _amount);

        // After deposit with idle funds, tend should NOT auto-trigger.
        (trigger, ) = strategy.tendTrigger();
        assertFalse(trigger, "tend should not auto-trigger after deposit");

        // Deploy funds via tend
        vm.prank(keeper);
        strategy.tend();

        // After tend, should no longer need to tend (within buffer)
        (trigger, ) = strategy.tendTrigger();
        assertTrue(!trigger, "tend should not be triggered after tending");
    }

}
