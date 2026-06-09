// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

// Adapted from tokenized-looper base tests for the Flex CDP looper: block advances for Flex's
// same-block debt guard, seed-trove-aware baselines, and MIN_DEBT-floor handling.

import "forge-std/console2.sol";
import {Setup} from "../utils/Setup.sol";

abstract contract BaseOperationTest is Setup {

    // Allow tiny residual collateral after full unwind due to rounding/swap dust.
    uint256 internal constant UNWIND_COLLATERAL_DUST_BPS = 2; // 0.02%
    uint256 internal constant MIN_UNWIND_COLLATERAL_DUST = 1;

    function setUp() public virtual override {
        super.setUp();
    }

    function _maxUnwindCollateralDust(
        uint256 collateralBeforeUnwind
    ) internal pure virtual returns (uint256) {
        uint256 relativeDust = collateralBeforeUnwind / (10_000 / UNWIND_COLLATERAL_DUST_BPS);
        return relativeDust > MIN_UNWIND_COLLATERAL_DUST ? relativeDust : MIN_UNWIND_COLLATERAL_DUST;
    }

    function _baseTestAmount() internal view returns (uint256) {
        uint256 min = minFuzzAmount;
        uint256 max = maxFuzzAmount;
        if (max <= min) return min;

        uint256 mid = (min + max) / 2;
        return mid > min ? mid : min;
    }

    function _baseIdleAmount() internal view returns (uint256) {
        uint256 idle = _baseTestAmount() / 10;
        return idle > 0 ? idle : 1;
    }

    function _warningLTV() internal view returns (uint256) {
        return 1e18 - (1e36 / strategy.maxLeverageRatio());
    }

    function _expectedAvailableWithdrawLimit() internal view returns (uint256) {
        uint256 idleAssets = strategy.balanceOfAsset();
        (uint256 collateralValue, uint256 currentDebt) = strategy.position();

        if (currentDebt > collateralValue) return idleAssets;

        uint256 currentEquity = collateralValue - currentDebt;
        uint256 flashloanAvailable = strategy.maxFlashloan();

        if (flashloanAvailable >= currentDebt) return idleAssets + currentEquity;

        if (strategy.targetLeverageRatio() <= 1e18) return idleAssets;

        uint256 targetDebt = currentDebt - flashloanAvailable;
        uint256 targetEquity = (targetDebt * 1e18) / (strategy.targetLeverageRatio() - 1e18);
        uint256 withdrawableEquity = currentEquity > targetEquity ? currentEquity - targetEquity : 0;

        return idleAssets + withdrawableEquity;
    }

    function test_setupStrategyOK() public virtual {
        console2.log("address of strategy", address(strategy));
        assertTrue(address(0) != address(strategy));
        assertEq(strategy.asset(), address(asset));
        assertEq(strategy.management(), management);
        assertEq(strategy.performanceFeeRecipient(), performanceFeeRecipient);
        assertEq(strategy.keeper(), keeper);
        // Collateral token should be set (specific token checked in derived tests if needed)
        assertTrue(strategy.collateralToken() != address(0), "!collateralToken");

        // Check leverage params
        assertEq(strategy.targetLeverageRatio(), 3e18, "!targetLeverageRatio");
        assertEq(strategy.leverageBuffer(), 0.25e18, "!leverageBuffer");
    }

    function test_operation(
        uint256 _amount
    ) public virtual {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);
        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        // Deploy funds via tend (since _deployFunds is empty to prevent sandwich attacks)
        vm.prank(keeper);
        strategy.tend();

        logStrategyStatus("After deposit");

        assertGt(strategy.totalAssets(), 0, "!totalAssets");

        // Earn Interest
        accrueYield(_amount);

        vm.prank(management);
        strategy.setLossLimitRatio(100);

        // Report profit
        vm.prank(keeper);
        strategy.report();

        skip(strategy.profitMaxUnlockTime());

        logStrategyStatus("After profit max unlock time");

        uint256 balanceBefore = asset.balanceOf(user);

        // Advance a block so the withdraw's internal repay is not gated by Flex's same-block debt guard.
        skip(1 seconds);

        // Withdraw all funds
        vm.prank(user);
        strategy.redeem(_amount, user, user);

        assertGe(asset.balanceOf(user), balanceBefore, "!final balance");
    }

    function test_profitableReport(
        uint256 _amount
    ) public virtual {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        mintAndDepositIntoStrategy(strategy, user, _amount);

        // Deploy funds via tend
        vm.prank(keeper);
        strategy.tend();

        accrueYield(_amount);

        uint256 pricePerShareBefore = strategy.pricePerShare();

        vm.prank(keeper);
        (uint256 profit, uint256 loss) = strategy.report();

        assertGt(profit, 0, "!profit");
        assertGt(profit, loss, "!net profit");

        skip(strategy.profitMaxUnlockTime());
        assertGt(strategy.pricePerShare(), pricePerShareBefore, "!pps");
    }

    function test_report_aboveWarningLTV_onlyDelevers() public {
        uint256 equity = _baseTestAmount();
        _createAboveWarningLTVPosition(equity);

        uint256 ltvBefore = strategy.getCurrentLTV();
        uint256 debtBefore = strategy.balanceOfDebt();
        uint256 lastTendBefore = strategy.lastTend();

        skip(1);

        vm.prank(management);
        strategy.setDoHealthCheck(false);

        vm.prank(keeper);
        strategy.report();

        uint256 ltvAfter = strategy.getCurrentLTV();
        uint256 debtAfter = strategy.balanceOfDebt();

        assertLt(ltvAfter, ltvBefore, "!should delever on report");
        assertLt(debtAfter, debtBefore, "!debt should decrease on report");
        assertGt(strategy.lastTend(), lastTendBefore, "!lastTend should update");
        assertEq(strategy.lastTend(), block.timestamp, "!lastTend timestamp");
    }

    function test_report_overTargetBelowWarning_doesNotDelever() public {
        uint256 equity = _baseTestAmount();
        _createOverLeveragedPosition(equity);

        uint256 idleAmount = _baseIdleAmount();
        airdrop(asset, address(strategy), idleAmount);

        uint256 warningLTV = _warningLTV();
        uint256 upperBound = strategy.targetLeverageRatio() + strategy.leverageBuffer();
        uint256 lastTendBefore = strategy.lastTend();

        assertLe(strategy.getCurrentLTV(), warningLTV, "!should be below warning ltv");
        assertGt(strategy.getCurrentLeverageRatio(), upperBound, "!should be above target band");

        skip(1);

        vm.prank(management);
        strategy.setDoHealthCheck(false);

        vm.prank(keeper);
        strategy.report();

        assertGt(strategy.balanceOfAsset(), 0, "!idle asset should remain");
        assertEq(strategy.lastTend(), lastTendBefore, "!lastTend should not move");
        assertLe(strategy.getCurrentLTV(), warningLTV, "!should stay below warning ltv");
    }

    function test_report_underLeveraged_doesNotLeverUp() public {
        uint256 equity = _baseTestAmount();
        _createUnderLeveragedPosition(equity);

        uint256 idleAmount = _baseIdleAmount();
        airdrop(asset, address(strategy), idleAmount);

        uint256 lowerBound = strategy.targetLeverageRatio() - strategy.leverageBuffer();
        uint256 lastTendBefore = strategy.lastTend();

        skip(1);

        vm.prank(management);
        strategy.setDoHealthCheck(false);

        vm.prank(keeper);
        strategy.report();

        uint256 leverageAfter = strategy.getCurrentLeverageRatio();
        assertLt(leverageAfter, lowerBound, "!should stay under-leveraged");
        assertGt(strategy.balanceOfAsset(), 0, "!idle asset should remain");
        assertEq(strategy.lastTend(), lastTendBefore, "!lastTend should not move");
    }

    function test_tendTrigger(
        uint256 _amount
    ) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        (bool trigger,) = strategy.tendTrigger();
        assertTrue(!trigger);

        mintAndDepositIntoStrategy(strategy, user, _amount);

        // After deposit with idle funds, tend should NOT auto-trigger.
        (trigger,) = strategy.tendTrigger();
        assertFalse(trigger, "tend should not auto-trigger after deposit");

        // Deploy funds via tend
        vm.prank(keeper);
        strategy.tend();

        // After tend, should no longer need to tend (within buffer)
        (trigger,) = strategy.tendTrigger();
        assertTrue(!trigger, "tend should not be triggered after tending");
    }

    function test_leverageRatio(
        uint256 _amount
    ) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // Before deposit, the seed trove already sits near 2x (Flex seed position).
        uint256 leverageBefore = strategy.getCurrentLeverageRatio();
        assertApproxEqRel(leverageBefore, 2e18, 0.05e18, "!leverage before deposit should be ~2x seed");

        mintAndDepositIntoStrategy(strategy, user, _amount);

        // After deposit but before tend, the new funds are idle so leverage is unchanged from seed.
        uint256 leverageAfterDeposit = strategy.getCurrentLeverageRatio();
        assertLe(leverageAfterDeposit, leverageBefore, "!leverage after deposit should not increase while idle");

        // Deploy funds via tend
        vm.prank(keeper);
        strategy.tend();

        // After tend, should be near target leverage
        uint256 leverageAfter = strategy.getCurrentLeverageRatio();
        uint256 targetLeverage = strategy.targetLeverageRatio();
        uint256 buffer = strategy.leverageBuffer();

        // Should be within buffer of target
        assertGe(leverageAfter, targetLeverage - buffer, "!leverage too low");
        assertLe(leverageAfter, targetLeverage + buffer, "!leverage too high");
    }

    function test_maxFlashloan() public {
        uint256 maxFL = strategy.maxFlashloan();
        assertGt(maxFL, 0, "!maxFlashloan should be > 0");
        console2.log("Max flashloan available:", maxFL);
    }

    function test_setLeverageParams() public {
        vm.startPrank(management);

        strategy.setLeverageParams(2.5e18, 0.15e18, 5e18);
        assertEq(strategy.targetLeverageRatio(), 2.5e18, "!new target");
        assertEq(strategy.leverageBuffer(), 0.15e18, "!new buffer");
        assertEq(strategy.maxLeverageRatio(), 5e18, "!new max");

        vm.expectRevert("leverage < 1x");
        strategy.setLeverageParams(0.5e18, 0.1e18, 5e18);

        vm.expectRevert("buffer too small");
        strategy.setLeverageParams(2e18, 0.001e18, 5e18);

        vm.expectRevert("exceeds LLTV");
        strategy.setLeverageParams(3e18, 1e18, 40e18);

        vm.expectRevert("max leverage < target + buffer");
        strategy.setLeverageParams(2e18, 0.1e18, 1e18);

        vm.stopPrank();
    }

    function test_setLeverageParams_keeperCanTuneWithoutChangingMax() public {
        uint256 buffer = strategy.leverageBuffer();

        vm.prank(keeper);
        strategy.setLeverageParams(2.25e18);

        assertEq(strategy.targetLeverageRatio(), 2.25e18, "!new target");
        assertEq(strategy.leverageBuffer(), buffer, "!buffer");
        assertEq(strategy.maxLeverageRatio(), 4e18, "!max should stay unchanged");
    }

    function test_setLeverageParams_keeperZeroTargetClearsBuffer() public {
        vm.prank(keeper);
        strategy.setLeverageParams(0);

        assertEq(strategy.targetLeverageRatio(), 0, "!target");
        assertEq(strategy.leverageBuffer(), 0, "!buffer");
        assertEq(strategy.maxLeverageRatio(), 4e18, "!max should stay unchanged");
    }

    function test_setLeverageParams_keeperSetter_rejectsNonKeeper() public {
        vm.prank(user);
        vm.expectRevert("!keeper");
        strategy.setLeverageParams(2.25e18);
    }

    function test_manualFullUnwind(
        uint256 _amount
    ) public {
        // N/A on Flex: a full unwind to ~zero collateral requires closing the trove
        // (emergencyWithdraw -> _handleClose). The BaseLooper delever path can't drop debt below
        // MIN_DEBT, so it trips MCR. Flex full-close is covered by the Shutdown suite.
        vm.skip(true);
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        mintAndDepositIntoStrategy(strategy, user, _amount);

        // Deploy funds via tend
        vm.prank(keeper);
        strategy.tend();

        assertGt(strategy.totalAssets(), 0, "!totalAssets");
        uint256 collateralBeforeUnwind = strategy.balanceOfCollateral();
        assertGt(collateralBeforeUnwind, 0, "!collateral should be > 0 before unwind");

        // Advance a block so the unwind's debt op is not gated by Flex's same-block debt guard.
        skip(1 seconds);

        // Full unwind via flashloan
        vm.prank(management);
        strategy.manualFullUnwind();

        // Position should be closed
        assertLe(
            strategy.balanceOfCollateral(),
            _maxUnwindCollateralDust(collateralBeforeUnwind),
            "!collateral dust too high"
        );
    }

    function test_manualPrimitives(
        uint256 _amount
    ) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // Airdrop asset to strategy for manual operations
        airdrop(asset, address(strategy), _amount);

        vm.prank(management);
        strategy.convertAssetToCollateral(type(uint256).max);

        // Advance a block so the first collateral/debt op clears Flex's same-block guard
        // (seed trove's last debt update was during setup).
        skip(1 seconds);

        // Manual supply collateral
        vm.prank(management);
        strategy.manualSupplyCollateral(type(uint256).max);

        uint256 collateral = strategy.balanceOfCollateral();
        assertGt(collateral, 0, "!collateral after supply");

        // Advance a block before the next debt-touching op (Flex same-block guard).
        skip(1 seconds);

        // Manual borrow
        uint256 borrowAmount = _amount / 2;
        vm.prank(management);
        strategy.manualBorrow(borrowAmount);

        uint256 debt = strategy.balanceOfDebt();
        assertGt(debt, 0, "!debt after borrow");

        // Advance a block before the repay (Flex same-block guard).
        skip(1 seconds);

        // Manual repay
        vm.prank(management);
        strategy.manualRepay(type(uint256).max);

        uint256 debtAfterRepay = strategy.balanceOfDebt();
        assertLt(debtAfterRepay, debt, "!debt should decrease after repay");

        // Advance a block before withdrawing collateral (Flex same-block guard).
        skip(1 seconds);

        // Manual withdraw collateral
        vm.prank(management);
        strategy.manualWithdrawCollateral(collateral / 2);

        uint256 collateralAfter = strategy.balanceOfCollateral();
        assertLt(collateralAfter, collateral, "!collateral should decrease");
    }

    function test_leverageBoundsValidation() public {
        uint256 lltv = strategy.getLiquidateCollateralFactor();
        console2.log("LLTV:", lltv);

        // Calculate max safe leverage from LLTV
        // LTV = 1 - 1/leverage => leverage = 1 / (1 - LTV)
        uint256 maxSafeLeverage = (1e18 * 1e18) / (1e18 - lltv);
        console2.log("Max safe leverage:", maxSafeLeverage);

        // Should be able to set leverage up to but not exceeding the safe max
        vm.startPrank(management);

        // This should succeed - set to a moderate leverage
        strategy.setLeverageParams(3e18, 0.5e18, 5e18);
        assertEq(strategy.targetLeverageRatio(), 3e18);

        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                    SETTERS TESTS
    //////////////////////////////////////////////////////////////*/

    function test_setMaxAmountToSwap() public {
        // Verify configured default value.
        assertEq(strategy.maxAmountToSwap(), _defaultMaxAmountToSwap(), "!default maxAmountToSwap");

        // Test setting a new value
        vm.prank(management);
        strategy.setMaxAmountToSwap(_assetAmount(1000));
        assertEq(strategy.maxAmountToSwap(), _assetAmount(1000), "!new maxAmountToSwap");

        // Test setting to 0
        vm.prank(management);
        strategy.setMaxAmountToSwap(0);
        assertEq(strategy.maxAmountToSwap(), 0, "!zero maxAmountToSwap");

        // Test setting back to max
        vm.prank(management);
        strategy.setMaxAmountToSwap(type(uint256).max);
        assertEq(strategy.maxAmountToSwap(), type(uint256).max, "!max maxAmountToSwap");
    }

    function test_setMaxAmountToSwap_onlyManagement() public {
        // Non-management should not be able to set
        vm.prank(user);
        vm.expectRevert("!management");
        strategy.setMaxAmountToSwap(_assetAmount(1000));

        // Keeper should not be able to set
        vm.prank(keeper);
        vm.expectRevert("!management");
        strategy.setMaxAmountToSwap(_assetAmount(1000));
    }

    function test_setMinTendInterval() public {
        // Verify default value is 2 hours
        assertEq(strategy.minTendInterval(), 2 hours, "!default minTendInterval");

        // Test setting a new value
        vm.prank(management);
        strategy.setMinTendInterval(1 hours);
        assertEq(strategy.minTendInterval(), 1 hours, "!new minTendInterval");

        // Test setting to 0
        vm.prank(management);
        strategy.setMinTendInterval(0);
        assertEq(strategy.minTendInterval(), 0, "!zero minTendInterval");

        // Test setting to a large value
        vm.prank(management);
        strategy.setMinTendInterval(7 days);
        assertEq(strategy.minTendInterval(), 7 days, "!7days minTendInterval");
    }

    function test_setMinTendInterval_onlyManagement() public {
        // Non-management should not be able to set
        vm.prank(user);
        vm.expectRevert("!management");
        strategy.setMinTendInterval(1 hours);

        // Keeper should not be able to set
        vm.prank(keeper);
        vm.expectRevert("!management");
        strategy.setMinTendInterval(1 hours);
    }

    /*//////////////////////////////////////////////////////////////
                    AVAILABLE DEPOSIT LIMIT TESTS
    //////////////////////////////////////////////////////////////*/

    function test_availableDepositLimit_zeroWhenLeverageBelowOne() public {
        // Set leverage ratio to exactly 1x (no leverage)
        vm.prank(management);
        strategy.setLeverageParams(1e18, 0.01e18, 5e18);

        // Available deposit limit should be 0 when targetLeverageRatio <= WAD
        uint256 limit = strategy.availableDepositLimit(user);
        assertGt(limit, 0, "!limit should be > 0 when leverage = 1x");

        vm.prank(management);
        strategy.setLeverageParams(0, 0, 5e18);

        limit = strategy.availableDepositLimit(user);
        assertEq(limit, 0, "!limit should be 0 when leverage < 1x");
    }

    function test_availableDepositLimit_respectsTargetLeverageRatio(
        uint256 _amount
    ) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // Get deposit limit at default 3x leverage
        uint256 limit3x = strategy.availableDepositLimit(user);
        assertGt(limit3x, 0, "!limit3x should be > 0");

        // Change to 2x leverage - should allow more deposits per unit of collateral capacity
        vm.prank(management);
        strategy.setLeverageParams(2e18, 0.25e18, 5e18);

        uint256 limit2x = strategy.availableDepositLimit(user);
        assertGt(limit2x, 0, "!limit2x should be > 0");

        // At lower leverage, same collateral capacity allows more deposits
        // deposit = collateral / L, so 2x leverage allows more than 3x
        // This may not always be true depending on borrow capacity constraints
        // So we just verify both are positive
    }

    function test_availableDepositLimit_zeroForNonAllowedAddress() public {
        address notAllowed = address(0x1234);
        assertFalse(strategy.allowed(notAllowed), "!should not be allowed");

        uint256 limit = strategy.availableDepositLimit(notAllowed);
        assertEq(limit, 0, "!limit should be 0 for non-allowed address");
    }

    function test_availableDepositLimit_respectsDepositLimit(
        uint256 _amount
    ) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // Account for the pre-opened seed trove's assets: availableDepositLimit is
        // depositLimit - totalAssets, so set the cap above the seed to leave exactly
        // `_amount` of fresh headroom for the user.
        uint256 taBefore = strategy.totalAssets();

        // Set a low deposit limit (seed-aware)
        vm.prank(management);
        strategy.setDepositLimit(_amount + taBefore);

        uint256 limit = strategy.availableDepositLimit(user);
        assertLe(limit, _amount, "!limit should not exceed deposit limit");

        // After depositing, limit should decrease
        mintAndDepositIntoStrategy(strategy, user, _amount / 2);

        uint256 limitAfter = strategy.availableDepositLimit(user);
        assertLe(limitAfter, _amount / 2 + 1, "!limit should decrease after deposit");
    }

    /*//////////////////////////////////////////////////////////////
                    AVAILABLE WITHDRAW LIMIT TESTS
    //////////////////////////////////////////////////////////////*/

    function test_availableWithdrawLimit_returnsIdleWhenNoPosition() public {
        // At the start of the test we are still in the same block as the seed trove's setup
        // debt update, so Flex gates the withdraw limit to idle-only (no delever this block).
        uint256 limit = strategy.availableWithdrawLimit(user);
        assertEq(limit, strategy.balanceOfAsset(), "!idle only");

        // The seed leaves residual idle in the strategy, so baseline it rather than assuming 0.
        uint256 idleBefore = strategy.balanceOfAsset();
        uint256 idleAmount = _baseIdleAmount();
        airdrop(asset, address(strategy), idleAmount);

        // Still same block as setup: limit stays idle-only and rises by exactly the airdrop.
        assertEq(strategy.availableWithdrawLimit(user), idleBefore + idleAmount, "!idle limit");
    }

    function test_availableWithdrawLimit_equityPlusIdleWhenFlashloanCoversDebt(
        uint256 _amount
    ) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // Create a position
        mintAndDepositIntoStrategy(strategy, user, _amount);
        vm.prank(keeper);
        strategy.tend();

        // Advance a block: in the same block as the tend's debt update Flex gates the
        // withdraw limit to idle-only. The next block exposes the full delever-able amount.
        skip(1 seconds);

        // Get current debt
        uint256 debt = strategy.balanceOfDebt();
        uint256 flashloan = strategy.maxFlashloan();

        // If flashloan >= debt, limit should be idle assets plus position equity.
        if (flashloan >= debt) {
            uint256 limit = strategy.availableWithdrawLimit(user);
            (uint256 collateralValue,) = strategy.position();
            uint256 expected = strategy.balanceOfAsset() + (collateralValue > debt ? collateralValue - debt : 0);

            assertEq(limit, expected, "!limit should be idle plus equity when flashloan covers debt");
        }
    }

    function test_availableWithdrawLimit_calculatesCorrectlyWhenFlashloanLimited() public {
        // This test verifies the math when flashloan < debt
        // We need to create a scenario where maxFlashloan < balanceOfDebt
        // This is hard to simulate in a real fork, so we verify the formula:
        //   targetDebt = currentDebt - flashloanAvailable
        //   targetEquity = targetDebt * WAD / (L - WAD)
        //   maxWithdraw = idleAssets + currentEquity - targetEquity

        uint256 _amount = _baseTestAmount();
        mintAndDepositIntoStrategy(strategy, user, _amount);
        vm.prank(keeper);
        strategy.tend();

        // Advance a block: in the same block as the tend's debt update Flex gates the
        // withdraw limit to idle-only, which would not match the full formula below.
        skip(1 seconds);

        uint256 currentDebt = strategy.balanceOfDebt();
        uint256 flashloanAvailable = strategy.maxFlashloan();
        uint256 targetLeverage = strategy.targetLeverageRatio();
        uint256 expectedLimit = _expectedAvailableWithdrawLimit();

        assertEq(strategy.availableWithdrawLimit(user), expectedLimit, "!withdraw limit calculation mismatch");

        if (flashloanAvailable < currentDebt && currentDebt > 0 && targetLeverage > 1e18) {
            uint256 idleAssets = strategy.balanceOfAsset();
            uint256 targetDebt = currentDebt - flashloanAvailable;
            uint256 targetEquity = (targetDebt * 1e18) / (targetLeverage - 1e18);

            (uint256 collateralValue,) = strategy.position();
            uint256 currentEquity = collateralValue > currentDebt ? collateralValue - currentDebt : 0;
            uint256 withdrawableEquity = currentEquity > targetEquity ? currentEquity - targetEquity : 0;

            assertEq(expectedLimit, idleAssets + withdrawableEquity, "!limited formula");
        }
    }

    function test_availableWithdrawLimit_noDebtReturnsIdlePlusEquity() public {
        vm.skip(true);
        // N/A on Flex: MIN_DEBT floor forbids debtless collateral (seed trove always holds >= MIN_DEBT)
        uint256 amount = _baseTestAmount();
        mintAndDepositIntoStrategy(strategy, user, amount);

        assertEq(strategy.balanceOfDebt(), 0, "!debt");
        assertEq(strategy.availableWithdrawLimit(user), strategy.balanceOfAsset(), "!idle plus equity");
        assertEq(strategy.maxRedeem(user), amount, "!max redeem");
    }

    /*//////////////////////////////////////////////////////////////
                    MIN TEND INTERVAL TESTS
    //////////////////////////////////////////////////////////////*/

    function test_tendTrigger_respectsMinTendInterval(
        uint256 _amount
    ) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // Set a longer min tend interval
        vm.prank(management);
        strategy.setMinTendInterval(1 hours);

        // Deposit and first tend
        mintAndDepositIntoStrategy(strategy, user, _amount);
        vm.prank(keeper);
        strategy.tend();

        // Immediately after tend, trigger should be false (even with idle funds)
        // unless there's an emergency condition
        airdrop(asset, address(strategy), _amount / 30);

        // Check tend trigger - should be false due to interval
        (bool trigger,) = strategy.tendTrigger();
        assertFalse(trigger, "!tend should not trigger within min interval");

        // Skip past the interval
        skip(1 hours + 1);

        // Still false after interval because idle assets no longer auto-trigger.
        (trigger,) = strategy.tendTrigger();
        assertFalse(trigger, "!tend should remain false after interval passed");
    }

    function test_tendTrigger_bypassesIntervalForEmergency(
        uint256 _amount
    ) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // Set a long min tend interval
        vm.prank(management);
        strategy.setMinTendInterval(7 days);

        // Deposit and first tend
        mintAndDepositIntoStrategy(strategy, user, _amount);
        vm.prank(keeper);
        strategy.tend();

        // Get current leverage
        uint256 currentLeverage = strategy.getCurrentLeverageRatio();
        uint256 maxLeverage = strategy.maxLeverageRatio();

        // If we're above max leverage, tend should trigger regardless of interval
        // This requires manipulating the position to be above max
        // For now, verify that the interval check comes after emergency checks
        (bool trigger,) = strategy.tendTrigger();
        // Should be false because we're within buffer and interval hasn't passed
        assertFalse(trigger, "!tend should respect interval when not emergency");
    }

    function test_lastTend_updatesAfterTend(
        uint256 _amount
    ) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // Verify lastTend starts at 0
        uint256 lastTendBefore = strategy.lastTend();
        assertEq(lastTendBefore, 0, "!lastTend should start at 0");

        // Deposit and tend
        mintAndDepositIntoStrategy(strategy, user, _amount);
        vm.prank(keeper);
        strategy.tend();

        // lastTend should be updated to current timestamp
        uint256 lastTendAfter = strategy.lastTend();
        assertEq(lastTendAfter, block.timestamp, "!lastTend should update");

        // Skip to a new timestamp and tend again.
        skip(1);
        airdrop(asset, address(strategy), _amount / 30);
        vm.prank(keeper);
        strategy.tend();

        // lastTend should update again
        assertEq(strategy.lastTend(), block.timestamp, "!lastTend should update again");
    }

    /*//////////////////////////////////////////////////////////////
                    TEND TRIGGER CAPACITY EDGE CASE TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Helper to create an over-leveraged position by changing target after build
    /// @param equity The equity amount to use for the position
    function _createOverLeveragedPosition(
        uint256 equity
    ) internal {
        // 1. Deposit and tend to build position at current target (3x)
        mintAndDepositIntoStrategy(strategy, user, equity);
        vm.prank(keeper);
        strategy.tend();

        // 2. Lower the target so current position becomes over-leveraged
        // Current: 3x target, 0.25 buffer => bounds [2.75, 3.25]
        // New: 2x target, 0.25 buffer => bounds [1.75, 2.25]
        // Position at ~3x will be above 2.25 upper bound
        vm.prank(management);
        strategy.setLeverageParams(2e18, 0.25e18, 5e18);

        // Verify position is now over-leveraged
        uint256 currentLeverage = strategy.getCurrentLeverageRatio();
        uint256 upperBound = strategy.targetLeverageRatio() + strategy.leverageBuffer();
        assertGt(currentLeverage, upperBound, "position should be over-leveraged");
        assertLe(strategy.getCurrentLTV(), _warningLTV(), "position should be below warning ltv");
    }

    /// @notice Helper to create a position above the warning LTV by lowering max leverage after build
    /// @param equity The equity amount to use for the position
    function _createAboveWarningLTVPosition(
        uint256 equity
    ) internal {
        vm.prank(management);
        strategy.setLeverageParams(4e18, 0.25e18, 5e18);

        mintAndDepositIntoStrategy(strategy, user, equity);
        vm.prank(keeper);
        strategy.tend();

        vm.prank(management);
        strategy.setLeverageParams(3e18, 0.25e18, 3.5e18);

        assertGt(strategy.getCurrentLTV(), _warningLTV(), "position should be above warning ltv");
    }

    /// @notice Helper to create an under-leveraged position by changing target after build
    /// @param equity The equity amount to use for the position
    function _createUnderLeveragedPosition(
        uint256 equity
    ) internal {
        // 1. First set a lower target
        vm.prank(management);
        strategy.setLeverageParams(2e18, 0.25e18, 5e18);

        // 2. Deposit and tend to build position at 2x target
        mintAndDepositIntoStrategy(strategy, user, equity);
        vm.prank(keeper);
        strategy.tend();

        // 3. Raise the target so current position becomes under-leveraged
        // Current: 2x target, 0.25 buffer => bounds [1.75, 2.25]
        // New: 4x target, 0.5 buffer => bounds [3.5, 4.5]
        // Position at ~2x will be below 3.5 lower bound
        vm.prank(management);
        strategy.setLeverageParams(4e18, 0.5e18, 6e18);

        // Verify position is now under-leveraged
        uint256 currentLeverage = strategy.getCurrentLeverageRatio();
        uint256 lowerBound = strategy.targetLeverageRatio() - strategy.leverageBuffer();
        assertLt(currentLeverage, lowerBound, "position should be under-leveraged");
    }

    /// @notice Test 1: Over-leveraged with idle assets should trigger tend
    /// @dev When over-leveraged (> upperBound) and has idle assets (balanceOfAsset > 0),
    ///      tendTrigger should return true as we can use idle assets to repay debt.
    function test_tendTrigger_overLeveragedWithIdleAssets() public {
        uint256 equity = _baseTestAmount();

        // Create over-leveraged position
        _createOverLeveragedPosition(equity);

        // Skip past minTendInterval
        skip(strategy.minTendInterval() + 1);

        // Airdrop idle assets to the strategy
        uint256 idleAmount = _baseIdleAmount();
        airdrop(asset, address(strategy), idleAmount);

        // Verify we have idle assets
        assertGt(strategy.balanceOfAsset(), 0, "should have idle assets");

        // Verify over-leveraged
        uint256 currentLeverage = strategy.getCurrentLeverageRatio();
        uint256 upperBound = strategy.targetLeverageRatio() + strategy.leverageBuffer();
        assertGt(currentLeverage, upperBound, "should be over-leveraged");

        // tendTrigger should return true
        (bool trigger,) = strategy.tendTrigger();
        assertTrue(trigger, "tendTrigger should return true when over-leveraged with idle assets");
    }

    /// @notice Test 2: Over-leveraged with no idle but can withdraw should trigger
    /// @dev When over-leveraged and no idle assets, but maxWithdraw > 0 (can delever via flashloan),
    ///      tendTrigger should return true.
    function test_tendTrigger_overLeveragedCanWithdraw() public {
        uint256 equity = _baseTestAmount();

        // Create over-leveraged position
        _createOverLeveragedPosition(equity);

        // Skip past minTendInterval
        skip(strategy.minTendInterval() + 1);

        // Ensure NO idle assets
        assertEq(strategy.balanceOfAsset(), 0, "should have no idle assets");

        // Verify we can withdraw (flashloan available)
        uint256 maxWithdraw = strategy.availableWithdrawLimit(address(strategy));
        assertGt(maxWithdraw, 0, "should be able to withdraw");

        // Verify over-leveraged
        uint256 currentLeverage = strategy.getCurrentLeverageRatio();
        uint256 upperBound = strategy.targetLeverageRatio() + strategy.leverageBuffer();
        assertGt(currentLeverage, upperBound, "should be over-leveraged");

        // tendTrigger should return true
        (bool trigger,) = strategy.tendTrigger();
        assertTrue(trigger, "tendTrigger should return true when over-leveraged and can withdraw");
    }

    /// @notice Test 3: Over-leveraged but cannot withdraw should NOT trigger
    /// @dev When over-leveraged, no idle assets, AND maxWithdraw = 0,
    ///      tendTrigger should return false as there's no way to delever.
    /// @dev This is a difficult scenario to create in a real fork since flashloan
    ///      is usually available. We test by setting deposit limit to 0 which
    ///      affects availableDepositLimit but not withdraw. For a true test,
    ///      we'd need to mock the protocol.
    function test_tendTrigger_overLeveragedCantWithdraw() public {
        // This test verifies the logic path where:
        // - currentLeverage > upperBound (over-leveraged)
        // - balanceOfAsset() == 0 (no idle)
        // - maxWithdraw == 0 (can't withdraw)
        // Result: return false

        // Since it's hard to make maxWithdraw = 0 in a real fork (flashloan usually available),
        // we verify the logic by checking that when over-leveraged with no idle but CAN withdraw,
        // it returns true (test 2 above). The code path for returning false when can't withdraw
        // is tested implicitly.

        uint256 equity = _baseTestAmount();

        // Create over-leveraged position
        _createOverLeveragedPosition(equity);

        // Skip past minTendInterval
        skip(strategy.minTendInterval() + 1);

        // Ensure NO idle assets
        assertEq(strategy.balanceOfAsset(), 0, "should have no idle assets");

        // In a real scenario with flashloan available, we can withdraw
        // The test confirms the positive case; the negative case (can't withdraw)
        // would require mocking the flashloan to be 0
        uint256 maxWithdraw = strategy.availableWithdrawLimit(address(strategy));

        if (maxWithdraw == 0) {
            // If somehow maxWithdraw is 0, tendTrigger should be false
            (bool trigger,) = strategy.tendTrigger();
            assertFalse(trigger, "tendTrigger should return false when over-leveraged but can't withdraw");
        } else {
            // Normal case: can withdraw, so trigger is true
            (bool trigger,) = strategy.tendTrigger();
            assertTrue(trigger, "tendTrigger should return true when can withdraw");
        }
    }

    /// @notice Test 4: Under-leveraged and can deposit should NOT auto-trigger
    /// @dev Under the new behavior, under-leveraged states are not auto-levered by tendTrigger.
    function test_tendTrigger_underLeveragedCanDeposit_noAutoTrigger() public virtual {
        uint256 equity = _baseTestAmount();

        // Create under-leveraged position
        _createUnderLeveragedPosition(equity);

        // Skip past minTendInterval
        skip(strategy.minTendInterval() + 1);

        // Verify under-leveraged
        uint256 currentLeverage = strategy.getCurrentLeverageRatio();
        uint256 lowerBound = strategy.targetLeverageRatio() - strategy.leverageBuffer();
        assertLt(currentLeverage, lowerBound, "should be under-leveraged");

        // Verify deposit capacity is available
        uint256 maxDeposit = strategy.availableDepositLimit(address(strategy));
        uint256 minBorrow = strategy.minAmountToBorrow();
        assertGt(maxDeposit, minBorrow, "should have deposit capacity");

        // tendTrigger should return false (no auto lever-up when under-leveraged)
        (bool trigger,) = strategy.tendTrigger();
        assertFalse(trigger, "tendTrigger should return false when under-leveraged");
    }

    /// @notice Test 5: Under-leveraged but cannot deposit should NOT trigger
    /// @dev When under-leveraged but maxDeposit = 0 (no deposit capacity),
    ///      tendTrigger should return false.
    function test_tendTrigger_underLeveragedCantDeposit() public virtual {
        uint256 equity = _baseTestAmount();

        // Create under-leveraged position
        _createUnderLeveragedPosition(equity);

        // Skip past minTendInterval
        skip(strategy.minTendInterval() + 1);

        // Set deposit limit to 0 to simulate no deposit capacity
        // This makes availableDepositLimit return 0
        vm.prank(management);
        strategy.setDepositLimit(0);

        // Verify deposit capacity is now 0
        uint256 maxDeposit = strategy.availableDepositLimit(address(strategy));
        assertEq(maxDeposit, 0, "deposit capacity should be 0");

        // Verify still under-leveraged
        uint256 currentLeverage = strategy.getCurrentLeverageRatio();
        uint256 lowerBound = strategy.targetLeverageRatio() - strategy.leverageBuffer();
        assertLt(currentLeverage, lowerBound, "should still be under-leveraged");

        // tendTrigger should return false (can't deposit to fix under-leverage)
        (bool trigger,) = strategy.tendTrigger();
        assertFalse(trigger, "tendTrigger should return false when under-leveraged but can't deposit");
    }

    /// @notice Test 6: Meaningful idle assets do NOT auto-trigger tend
    /// @dev Under the new behavior, idle assets are not auto-deployed by tendTrigger.
    function test_tendTrigger_idleAssetsCanDeposit_noAutoTrigger() public {
        uint256 equity = _baseTestAmount();

        // Create a position at target
        mintAndDepositIntoStrategy(strategy, user, equity);
        vm.prank(keeper);
        strategy.tend();

        // Skip past minTendInterval
        skip(strategy.minTendInterval() + 1);

        // Airdrop meaningful idle assets
        // At 3x leverage, idle * (L - 1) / 1 = idle * 2 should be > minAmountToBorrow
        // With minAmountToBorrow = 0 (default for InfinifiMorphoLooper), any idle triggers
        uint256 idleAmount = _baseIdleAmount();
        airdrop(asset, address(strategy), idleAmount);

        // Verify we have idle assets
        assertGt(strategy.balanceOfAsset(), 0, "should have idle assets");

        // Verify within buffer (not over or under leveraged)
        uint256 currentLeverage = strategy.getCurrentLeverageRatio();
        uint256 target = strategy.targetLeverageRatio();
        uint256 buffer = strategy.leverageBuffer();
        _assertLeverageWithinTestBuffer(
            currentLeverage, target, buffer, "should be within lower buffer", "should be within upper buffer"
        );

        // Verify deposit capacity
        uint256 maxDeposit = strategy.availableDepositLimit(address(strategy));
        assertGt(maxDeposit, strategy.minAmountToBorrow(), "should have deposit capacity");

        // tendTrigger should return false (no idle auto-deploy)
        (bool trigger,) = strategy.tendTrigger();
        assertFalse(trigger, "tendTrigger should return false with idle assets and deposit capacity");
    }

    /// @notice Test 7: Has meaningful idle assets but cannot deposit should NOT trigger
    /// @dev When has idle assets but maxDeposit = 0, tendTrigger should return false.
    function test_tendTrigger_idleAssetsCantDeposit() public {
        uint256 equity = _baseTestAmount();

        // Create a position at target
        mintAndDepositIntoStrategy(strategy, user, equity);
        vm.prank(keeper);
        strategy.tend();

        // Skip past minTendInterval
        skip(strategy.minTendInterval() + 1);

        // Airdrop meaningful idle assets
        uint256 idleAmount = _baseIdleAmount();
        airdrop(asset, address(strategy), idleAmount);

        // Set deposit limit to 0 to simulate no deposit capacity
        vm.prank(management);
        strategy.setDepositLimit(0);

        // Verify we have idle assets
        assertGt(strategy.balanceOfAsset(), 0, "should have idle assets");

        // Verify deposit capacity is 0
        uint256 maxDeposit = strategy.availableDepositLimit(address(strategy));
        assertEq(maxDeposit, 0, "deposit capacity should be 0");

        // tendTrigger should return false (can't deploy idle assets)
        (bool trigger,) = strategy.tendTrigger();
        assertFalse(trigger, "tendTrigger should return false with idle assets but no deposit capacity");
    }

    /// @notice Test 8: Tiny idle assets should NOT trigger
    /// @dev When idle assets are so small that debt generated would be < minAmountToBorrow,
    ///      tendTrigger should return false.
    function test_tendTrigger_tinyIdleAssetsNoTrigger() public {
        uint256 equity = _baseTestAmount();

        // Create a position at target
        mintAndDepositIntoStrategy(strategy, user, equity);
        vm.prank(keeper);
        strategy.tend();

        // Skip past minTendInterval
        skip(strategy.minTendInterval() + 1);

        // Set a high minAmountToBorrow
        vm.prank(management);
        strategy.setMinAmountToBorrow(_baseIdleAmount() * 5);

        // Airdrop tiny idle assets that won't generate enough debt
        // At 3x leverage: idle * (L - 1) / 1 = idle * 2
        // For debt > 1000e6, we need idle > 500e6
        // So idle of 100e6 should generate debt of 200e6 < 1000e6 minAmountToBorrow
        uint256 tinyIdle = _baseIdleAmount() / 5;
        if (tinyIdle == 0) tinyIdle = 1;
        airdrop(asset, address(strategy), tinyIdle);

        // Verify we have idle assets
        uint256 idle = strategy.balanceOfAsset();
        assertGt(idle, 0, "should have idle assets");

        // Verify the debt that would be generated is less than minAmountToBorrow
        uint256 target = strategy.targetLeverageRatio();
        uint256 potentialDebt = (idle * (target - 1e18)) / 1e18;
        uint256 minBorrow = strategy.minAmountToBorrow();
        assertLt(potentialDebt, minBorrow, "potential debt should be less than minAmountToBorrow");

        // Verify within buffer (not under-leveraged which would override the idle check)
        uint256 currentLeverage = strategy.getCurrentLeverageRatio();
        uint256 buffer = strategy.leverageBuffer();
        _assertLeverageWithinTestBuffer(
            currentLeverage, target, buffer, "should be within lower buffer", "should be within upper buffer"
        );

        // tendTrigger should return false (idle assets too small to matter)
        (bool trigger,) = strategy.tendTrigger();
        assertFalse(trigger, "tendTrigger should return false with tiny idle assets");
    }

    /// @notice Test 9: Within buffer and no idle assets should NOT trigger
    /// @dev When within the leverage buffer range and no idle assets to deploy,
    ///      tendTrigger should return false.
    function test_tendTrigger_withinBufferNoIdle() public {
        uint256 equity = _baseTestAmount();

        // Create a position at target
        mintAndDepositIntoStrategy(strategy, user, equity);
        vm.prank(keeper);
        strategy.tend();

        // Skip past minTendInterval
        skip(strategy.minTendInterval() + 1);

        // Verify NO idle assets
        assertEq(strategy.balanceOfAsset(), 0, "should have no idle assets");

        // Verify within buffer
        uint256 currentLeverage = strategy.getCurrentLeverageRatio();
        uint256 target = strategy.targetLeverageRatio();
        uint256 buffer = strategy.leverageBuffer();
        _assertLeverageWithinTestBuffer(
            currentLeverage, target, buffer, "should be within lower buffer", "should be within upper buffer"
        );

        // tendTrigger should return false (within buffer, nothing to do)
        (bool trigger,) = strategy.tendTrigger();
        assertFalse(trigger, "tendTrigger should return false when within buffer with no idle");
    }

    /*//////////////////////////////////////////////////////////////
                        SLIPPAGE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_setSlippage_onlyManagement() public {
        vm.prank(user);
        vm.expectRevert("!management");
        strategy.setSlippage(10);

        vm.prank(keeper);
        vm.expectRevert("!management");
        strategy.setSlippage(10);
    }

    function test_setSlippage_boundsValidation() public {
        vm.startPrank(management);

        vm.expectRevert("slippage");
        strategy.setSlippage(MAX_BPS);

        vm.expectRevert("slippage");
        strategy.setSlippage(MAX_BPS + 1);

        vm.expectRevert("slippage too high");
        strategy.setSlippage(100);

        strategy.setSlippage(99);
        assertEq(strategy.slippage(), 99, "!slippage should be 99");

        vm.stopPrank();
    }

    function test_setSlippage_allowsHigherAfterShutdown() public {
        vm.prank(emergencyAdmin);
        strategy.shutdownStrategy();

        vm.prank(management);
        strategy.setSlippage(MAX_BPS - 1);
        assertEq(strategy.slippage(), MAX_BPS - 1, "!slippage should be max");
    }

    /*//////////////////////////////////////////////////////////////
                    REPORT BUFFER TESTS
    //////////////////////////////////////////////////////////////*/

    function test_reportBuffer_lowersEstimatedTotalAssets(
        uint256 _amount
    ) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // Create a position with collateral
        mintAndDepositIntoStrategy(strategy, user, _amount);
        vm.prank(keeper);
        strategy.tend();

        // Get estimatedTotalAssets with default reportBuffer (0)
        uint256 estimatedAssetsDefault = strategy.estimatedTotalAssets();
        assertGt(estimatedAssetsDefault, 0, "!estimatedAssets should be > 0");

        // Set reportBuffer to 100 BPS (1%)
        vm.prank(management);
        strategy.setReportBuffer(100);
        assertEq(strategy.reportBuffer(), 100, "!reportBuffer should be 100");

        // Get estimatedTotalAssets with reportBuffer = 100
        uint256 estimatedAssetsWithBuffer = strategy.estimatedTotalAssets();

        // estimatedTotalAssets should be lower with higher reportBuffer
        assertLt(
            estimatedAssetsWithBuffer, estimatedAssetsDefault, "!estimatedAssets should be lower with reportBuffer"
        );

        // Set reportBuffer to 500 BPS (5%)
        vm.prank(management);
        strategy.setReportBuffer(500);
        assertEq(strategy.reportBuffer(), 500, "!reportBuffer should be 500");

        // Get estimatedTotalAssets with reportBuffer = 500
        uint256 estimatedAssetsWithHigherBuffer = strategy.estimatedTotalAssets();

        // Should be even lower with higher reportBuffer
        assertLt(
            estimatedAssetsWithHigherBuffer,
            estimatedAssetsWithBuffer,
            "!estimatedAssets should be lower with higher reportBuffer"
        );
        assertLt(
            estimatedAssetsWithHigherBuffer, estimatedAssetsDefault, "!estimatedAssets should be lower than default"
        );
    }

    function test_reportBuffer_onlyManagement() public {
        // Non-management should not be able to set
        vm.prank(user);
        vm.expectRevert("!management");
        strategy.setReportBuffer(100);

        // Keeper should not be able to set
        vm.prank(keeper);
        vm.expectRevert("!management");
        strategy.setReportBuffer(100);
    }

    function test_reportBuffer_boundsValidation() public {
        vm.startPrank(management);

        // Should fail if reportBuffer >= MAX_BPS
        vm.expectRevert("buffer");
        strategy.setReportBuffer(MAX_BPS);

        vm.expectRevert("buffer");
        strategy.setReportBuffer(MAX_BPS + 1);

        // Should succeed with valid values
        strategy.setReportBuffer(0);
        assertEq(strategy.reportBuffer(), 0, "!reportBuffer should be 0");

        strategy.setReportBuffer(MAX_BPS - 1);
        assertEq(strategy.reportBuffer(), MAX_BPS - 1, "!reportBuffer should be MAX_BPS - 1");

        vm.stopPrank();
    }

}
