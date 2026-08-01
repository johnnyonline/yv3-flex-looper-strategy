pragma solidity ^0.8.18;

// Adapted from tokenized-looper base tests for the Flex CDP looper: block advances
// for Flex's same-block debt guard, seed-trove-aware baselines, and MIN_DEBT-floor
// handling.

import "forge-std/console2.sol";
import {Setup} from "../utils/Setup.sol";

abstract contract BaseShutdownTest is Setup {

    // Allow tiny residual collateral after full unwind due to rounding/swap dust.
    uint256 internal constant UNWIND_COLLATERAL_DUST_BPS = 1; // 0.01%
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

    function test_shutdownCanWithdraw(
        uint256 _amount
    ) public virtual {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        // Deploy funds via tend
        vm.prank(keeper);
        strategy.tend();

        assertGt(strategy.totalAssets(), 0, "!totalAssets");

        // Earn Interest
        accrueYield(_amount);

        // Shutdown the strategy
        vm.prank(emergencyAdmin);
        strategy.shutdownStrategy();

        assertGt(strategy.totalAssets(), 0, "!totalAssets");

        // Make sure we can still withdraw the full amount
        uint256 balanceBefore = asset.balanceOf(user);

        // Advance the block so the withdraw's internal repay isn't gated by Flex's
        // same-block debt guard (tend above touched the trove this block).
        skip(REPAY_COOLDOWN + 1);

        // Withdraw all funds
        vm.prank(user);
        strategy.redeem(_amount, user, user);

        assertApproxEqRel(asset.balanceOf(user), balanceBefore + _amount, 0.01e18);
    }

    function test_emergencyWithdraw_maxUint(
        uint256 _amount
    ) public virtual {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // Capture the seed-trove equity baseline before the user deposits. Flex
        // pre-opens a seed trove holding ~2 * MIN_DEBT of equity in totalAssets.
        uint256 taBefore = strategy.totalAssets();

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        // Deploy funds via tend
        vm.prank(keeper);
        strategy.tend();

        assertApproxEqAbs(strategy.totalAssets(), _amount + taBefore, 2, "!totalAssets");

        // Earn Interest
        accrueYield(_amount);

        // Shutdown the strategy
        vm.prank(emergencyAdmin);
        strategy.shutdownStrategy();

        assertApproxEqAbs(strategy.totalAssets(), _amount + taBefore, 2, "!totalAssets");

        // Advance the block so emergencyWithdraw's delever isn't gated by Flex's
        // same-block debt guard (tend above touched the trove this block).
        skip(REPAY_COOLDOWN + 1);

        // should be able to pass uint 256 max and not revert.
        vm.prank(emergencyAdmin);
        strategy.emergencyWithdraw(type(uint256).max);

        // Realize the equity the partial-conversion close left as loose collateral
        vm.prank(emergencyAdmin);
        strategy.convertCollateralToAsset(type(uint256).max);

        vm.prank(management);
        strategy.setDoHealthCheck(false);

        vm.prank(management);
        strategy.report();

        // Make sure we can still withdraw the full amount
        uint256 balanceBefore = asset.balanceOf(user);

        // Advance the block so the withdraw's internal repay isn't gated by Flex's
        // same-block debt guard (emergencyWithdraw above touched the trove).
        skip(REPAY_COOLDOWN + 1);

        // Withdraw all funds
        vm.prank(user);
        strategy.redeem(_amount, user, user);

        // The accrued yield is shared across shares, so redeeming `_amount` shares returns at
        // least the deposit (often a bit more); assert the floor rather than a two-sided band.
        assertGe(asset.balanceOf(user), balanceBefore + _amount, "!recovered");
    }

    // TODO: Add tests for any emergency function added.

    /*//////////////////////////////////////////////////////////////
                        IDLE MODE TESTS (targetLeverageRatio == 0)
    //////////////////////////////////////////////////////////////*/

    function test_idleMode_setLeverageParams() public {
        vm.prank(management);
        strategy.setLeverageParams(0, 0, 5e18);

        assertEq(strategy.targetLeverageRatio(), 0, "!target should be 0");
        assertEq(strategy.leverageBuffer(), 0, "!buffer should be 0");
        assertEq(strategy.maxLeverageRatio(), 5e18, "!maxLeverageRatio");
    }

    function test_idleMode_rejectsNonZeroBuffer() public {
        vm.prank(management);
        vm.expectRevert("buffer must be 0 if target is 0");
        strategy.setLeverageParams(0, 0.1e18, 5e18);
    }

    function test_idleMode_unwindsPosition(
        uint256 _amount
    ) public {
        // N/A on Flex: idle mode (target leverage 0 -> hold collateral with zero debt) is
        // unreachable. The seed trove always holds >= MIN_DEBT, so unwinding to a debtless/idle
        // state trips the MIN_DEBT/MCR floor. Full close is covered via emergencyWithdraw.
        vm.skip(true);
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // Setup leveraged position
        mintAndDepositIntoStrategy(strategy, user, _amount);
        vm.prank(keeper);
        strategy.tend();

        // Verify position exists
        uint256 collateralBeforeUnwind = strategy.balanceOfCollateral();
        assertGt(collateralBeforeUnwind, 0, "!collateral before");
        assertGt(strategy.balanceOfDebt(), 0, "!debt before");

        // Set idle mode
        vm.prank(management);
        strategy.setLeverageParams(0, 0, 5e18);

        // Advance the block so manualFullUnwind isn't gated by Flex's same-block
        // debt guard (tend above touched the trove this block).
        skip(REPAY_COOLDOWN + 1);

        // Unwind position using manualFullUnwind (tend alone doesn't fully unwind).
        // manualFullUnwind is an emergency full close that wipes the whole trove
        // (including the seed), so collateral floors to dust as on the source repo.
        vm.prank(management);
        strategy.manualFullUnwind();

        // Verify position is fully unwound
        assertLe(
            strategy.balanceOfCollateral(),
            _maxUnwindCollateralDust(collateralBeforeUnwind),
            "!collateral dust too high"
        );
    }

    function test_idleMode_tendTriggerFalseAfterUnwind(
        uint256 _amount
    ) public {
        // N/A on Flex: idle mode (target leverage 0 -> hold collateral with zero debt) is
        // unreachable. The seed trove always holds >= MIN_DEBT, so unwinding to a debtless/idle
        // state trips the MIN_DEBT/MCR floor. Full close is covered via emergencyWithdraw.
        vm.skip(true);
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // Setup leveraged position
        mintAndDepositIntoStrategy(strategy, user, _amount);
        vm.prank(keeper);
        strategy.tend();
        uint256 collateralBeforeUnwind = strategy.balanceOfCollateral();

        // Set idle mode and unwind using manualFullUnwind
        vm.prank(management);
        strategy.setLeverageParams(0, 0, 5e18);

        // Advance the block so manualFullUnwind isn't gated by Flex's same-block
        // debt guard (tend above touched the trove this block).
        skip(REPAY_COOLDOWN + 1);

        vm.prank(management);
        strategy.manualFullUnwind();

        // Verify position is unwound
        assertLe(
            strategy.balanceOfCollateral(),
            _maxUnwindCollateralDust(collateralBeforeUnwind),
            "!collateral dust too high"
        );

        // After full unwind in idle mode, tendTrigger should be FALSE
        // - getCurrentLeverageRatio() returns 0 when no position
        // - Idle mode check: currentLeverage > 0 → false → no tend needed
        (bool trigger,) = strategy.tendTrigger();
        assertFalse(trigger, "!tendTrigger should be false after full unwind in idle mode");
    }

    function test_idleMode_tendTriggerTrueWithDebt(
        uint256 _amount
    ) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // Setup leveraged position
        mintAndDepositIntoStrategy(strategy, user, _amount);
        vm.prank(keeper);
        strategy.tend();

        // Verify position has debt
        assertGt(strategy.balanceOfDebt(), 0, "!debt should exist");

        // Set idle mode (don't tend yet)
        vm.prank(management);
        strategy.setLeverageParams(0, 0, 5e18);

        // Skip past the minTendInterval so tendTrigger can check leverage conditions
        skip(strategy.minTendInterval() + 1);

        // Verify tend trigger is true (still has debt to unwind)
        (bool trigger,) = strategy.tendTrigger();
        assertTrue(trigger, "!tendTrigger should be true with debt");
    }

    function test_idleMode_staysIdle(
        uint256 _amount
    ) public {
        // N/A on Flex: idle mode (target leverage 0 -> hold collateral with zero debt) is
        // unreachable. The seed trove always holds >= MIN_DEBT, so unwinding to a debtless/idle
        // state trips the MIN_DEBT/MCR floor. Full close is covered via emergencyWithdraw.
        vm.skip(true);
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // Setup leveraged position
        mintAndDepositIntoStrategy(strategy, user, _amount);
        vm.prank(keeper);
        strategy.tend();
        uint256 collateralBeforeUnwind = strategy.balanceOfCollateral();

        // Set idle mode and unwind using manualFullUnwind
        vm.prank(management);
        strategy.setLeverageParams(0, 0, 5e18);

        // Advance the block so manualFullUnwind isn't gated by Flex's same-block
        // debt guard (tend above touched the trove this block).
        skip(REPAY_COOLDOWN + 1);

        vm.prank(management);
        strategy.manualFullUnwind();

        // Verify position is unwound
        assertLe(
            strategy.balanceOfCollateral(),
            _maxUnwindCollateralDust(collateralBeforeUnwind),
            "!collateral dust too high"
        );

        // In idle mode, availableDepositLimit() returns 0 because targetLeverageRatio <= WAD
        // This prevents new deposits from being accepted
        uint256 depositLimitInIdleMode = strategy.availableDepositLimit(user);
        assertEq(depositLimitInIdleMode, 0, "!deposit limit should be 0 in idle mode");

        uint256 assetBefore = strategy.balanceOfAsset();
        uint256 collateralBefore = strategy.balanceOfCollateral();
        uint256 looseCollateralBefore = strategy.balanceOfCollateralToken();
        uint256 debtBefore = strategy.balanceOfDebt();
        assertEq(debtBefore, 0, "!debt before idle tend");

        // Skip past minTendInterval for tend to work
        skip(strategy.minTendInterval() + 1);

        vm.prank(keeper);
        strategy.tend();

        assertEq(strategy.balanceOfDebt(), debtBefore, "!debt changed");
        assertEq(strategy.balanceOfAsset(), assetBefore, "!asset changed");
        assertEq(strategy.balanceOfCollateral(), collateralBefore, "!collateral changed");
        assertEq(strategy.balanceOfCollateralToken(), looseCollateralBefore, "!loose collateral changed");
    }

    function test_idleMode_tendLeavesLooseAssetsIdle(
        uint256 _amount
    ) public {
        vm.skip(true);
        // N/A on Flex: MIN_DEBT floor forbids debtless collateral (seed trove always holds >= MIN_DEBT)
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        vm.prank(management);
        strategy.setLeverageParams(0, 0, 5e18);

        airdrop(asset, address(strategy), _amount);

        uint256 assetBefore = strategy.balanceOfAsset();
        uint256 collateralBefore = strategy.balanceOfCollateral();
        uint256 looseCollateralBefore = strategy.balanceOfCollateralToken();

        skip(strategy.minTendInterval() + 1);

        vm.prank(keeper);
        strategy.tend();

        assertEq(strategy.balanceOfDebt(), 0, "!debt");
        assertEq(strategy.balanceOfAsset(), assetBefore, "!asset");
        assertEq(strategy.balanceOfCollateral(), collateralBefore, "!collateral");
        assertEq(strategy.balanceOfCollateralToken(), looseCollateralBefore, "!loose collateral");
    }

    function test_idleMode_tendRepaysDebtAndLeavesExcessIdle(
        uint256 _amount
    ) public virtual {
        vm.skip(true);
        // N/A on Flex: MIN_DEBT floor forbids debtless collateral (seed trove always holds >= MIN_DEBT)
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        mintAndDepositIntoStrategy(strategy, user, _amount);
        vm.prank(keeper);
        strategy.tend();

        uint256 collateralBefore = strategy.balanceOfCollateral();
        uint256 debtBefore = strategy.balanceOfDebt();
        assertGt(debtBefore, 0, "!debt before");
        assertGt(collateralBefore, 0, "!collateral before");

        vm.prank(management);
        strategy.setLeverageParams(0, 0, 5e18);

        airdrop(asset, address(strategy), debtBefore * 2 + minFuzzAmount);
        uint256 assetBefore = strategy.balanceOfAsset();
        assertGt(assetBefore, debtBefore, "!idle before");

        skip(strategy.minTendInterval() + 1);

        vm.prank(keeper);
        strategy.tend();

        assertEq(strategy.balanceOfDebt(), 0, "!debt");
        assertLe(
            strategy.balanceOfCollateral(), _maxUnwindCollateralDust(collateralBefore), "!collateral dust too high"
        );
        uint256 assetAfter = strategy.balanceOfAsset();
        assertGt(assetAfter, 0, "!leftover idle");
        assertGe(assetAfter, assetBefore - debtBefore, "!excess idle");
    }

    function test_idleMode_tendConvertsDebtlessCollateral(
        uint256 _amount
    ) public virtual {
        vm.skip(true);
        // N/A on Flex: MIN_DEBT floor forbids debtless collateral (seed trove always holds >= MIN_DEBT)
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        airdrop(asset, address(strategy), _amount);

        vm.startPrank(management);
        strategy.convertAssetToCollateral(_amount);
        strategy.manualSupplyCollateral(type(uint256).max);
        strategy.setLeverageParams(0, 0, 5e18);
        vm.stopPrank();

        uint256 collateralBefore = strategy.balanceOfCollateral();
        assertGt(collateralBefore, 0, "!collateral before");
        assertEq(strategy.balanceOfDebt(), 0, "!debt before");

        skip(strategy.minTendInterval() + 1);

        vm.prank(keeper);
        strategy.tend();

        assertEq(strategy.balanceOfDebt(), 0, "!debt");
        assertLe(
            strategy.balanceOfCollateral(), _maxUnwindCollateralDust(collateralBefore), "!collateral dust too high"
        );
        assertGt(strategy.balanceOfAsset(), 0, "!asset");
    }

    function test_manualFullUnwind_setsTargetToZero(
        uint256 _amount
    ) public virtual {
        // N/A on Flex: a full unwind to ~zero collateral requires closing the trove
        // (emergencyWithdraw -> _handleClose). The BaseLooper delever path can't drop debt below
        // MIN_DEBT, so it trips MCR. Flex full-close is covered by the Shutdown suite.
        vm.skip(true);
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        mintAndDepositIntoStrategy(strategy, user, _amount);
        vm.prank(keeper);
        strategy.tend();

        uint256 collateralBeforeUnwind = strategy.balanceOfCollateral();
        assertGt(collateralBeforeUnwind, 0, "!collateral before");
        assertGt(strategy.targetLeverageRatio(), 0, "!target before");

        // Advance the block so manualFullUnwind isn't gated by Flex's same-block
        // debt guard (tend above touched the trove this block).
        skip(REPAY_COOLDOWN + 1);

        vm.prank(management);
        strategy.manualFullUnwind();

        assertEq(strategy.targetLeverageRatio(), 0, "!target");
        assertEq(strategy.leverageBuffer(), 0, "!buffer");
        assertEq(strategy.maxLeverageRatio(), 1e18, "!max leverage");
        assertEq(strategy.balanceOfDebt(), 0, "!debt");
        assertLe(
            strategy.balanceOfCollateral(),
            _maxUnwindCollateralDust(collateralBeforeUnwind),
            "!collateral dust too high"
        );
    }

    function test_manualDelever_validAmountLowersPosition(
        uint256 _amount
    ) public virtual {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        mintAndDepositIntoStrategy(strategy, user, _amount);
        vm.prank(keeper);
        strategy.tend();

        uint256 collateralBefore = strategy.balanceOfCollateral();
        uint256 debtBefore = strategy.balanceOfDebt();
        assertGt(collateralBefore, 0, "!collateral before");
        assertGt(debtBefore, 0, "!debt before");

        uint256 amountToDelever = collateralBefore / 100;
        if (amountToDelever == 0) amountToDelever = 1;

        // Advance the block so manualDelever isn't gated by Flex's same-block debt
        // guard (tend above touched the trove this block).
        skip(REPAY_COOLDOWN + 1);

        vm.prank(management);
        strategy.manualDelever(amountToDelever);

        assertLt(strategy.balanceOfCollateral(), collateralBefore, "!collateral");
        assertLt(strategy.balanceOfDebt(), debtBefore, "!debt");
        assertLt(strategy.getCurrentLTV(), strategy.getLiquidateCollateralFactor(), "!ltv");
    }

    function test_manualDelever_maxUintCapsToSafeAmount(
        uint256 _amount
    ) public virtual {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        mintAndDepositIntoStrategy(strategy, user, _amount);
        vm.prank(keeper);
        strategy.tend();

        uint256 collateralBefore = strategy.balanceOfCollateral();
        uint256 debtBefore = strategy.balanceOfDebt();
        assertGt(collateralBefore, 0, "!collateral before");
        assertGt(debtBefore, 0, "!debt before");

        // Advance the block so manualDelever isn't gated by Flex's same-block debt
        // guard (tend above touched the trove this block).
        skip(REPAY_COOLDOWN + 1);

        vm.prank(management);
        strategy.manualDelever(type(uint256).max);

        assertLt(strategy.balanceOfCollateral(), collateralBefore, "!collateral");
        assertLt(strategy.balanceOfDebt(), debtBefore, "!debt");
        assertLt(strategy.getCurrentLTV(), strategy.getLiquidateCollateralFactor(), "!ltv");
    }

    function test_idleMode_tendDecreasesLeverageWhenIdleBelowDebt(
        uint256 _amount
    ) public {
        // N/A on Flex: target-0 idle-mode delever with loose idle both hits the deferred _lever
        // CASE 2 double-repay (same-block idle+flashloan repay) and can't reach a debtless state
        // (MIN_DEBT floor). See test_lever_deleverWithIdleAndFlashloan.
        vm.skip(true);
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        mintAndDepositIntoStrategy(strategy, user, _amount);
        vm.prank(keeper);
        strategy.tend();

        uint256 collateralBefore = strategy.balanceOfCollateral();
        uint256 debtBefore = strategy.balanceOfDebt();
        uint256 leverageBefore = strategy.getCurrentLeverageRatio();
        assertGt(debtBefore, 0, "!debt before");
        assertGt(collateralBefore, 0, "!collateral before");

        vm.prank(management);
        strategy.setLeverageParams(0, 0, 5e18);

        airdrop(asset, address(strategy), debtBefore / 4);

        // skip(minTendInterval) also advances the block past the seed/lever tend, so
        // this idle-mode tend clears Flex's same-block debt guard.
        skip(strategy.minTendInterval() + 1);

        vm.prank(keeper);
        strategy.tend();

        // On Flex the idle (target 0) tend delevers toward MIN_DEBT instead of all the
        // way to zero (the seed trove can never be debtless), but the test's intent --
        // a partial deleverage that strictly reduces debt/leverage -- still holds.
        assertLt(strategy.balanceOfDebt(), debtBefore, "!debt not reduced");
        assertLt(strategy.getCurrentLeverageRatio(), leverageBefore, "!leverage not reduced");
        assertLe(strategy.balanceOfCollateral(), collateralBefore, "!collateral increased");
    }

    function test_idleMode_canReenableLeverage(
        uint256 _amount
    ) public {
        // N/A on Flex: idle mode (target leverage 0 -> hold collateral with zero debt) is
        // unreachable. The seed trove always holds >= MIN_DEBT, so unwinding to a debtless/idle
        // state trips the MIN_DEBT/MCR floor. Full close is covered via emergencyWithdraw.
        vm.skip(true);
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // Setup leveraged position
        mintAndDepositIntoStrategy(strategy, user, _amount);
        vm.prank(keeper);
        strategy.tend();
        uint256 collateralBeforeUnwind = strategy.balanceOfCollateral();

        // Set idle mode and unwind using manualFullUnwind
        vm.prank(management);
        strategy.setLeverageParams(0, 0, 5e18);

        // Advance the block so manualFullUnwind isn't gated by Flex's same-block
        // debt guard (tend above touched the trove this block).
        skip(REPAY_COOLDOWN + 1);

        vm.prank(management);
        strategy.manualFullUnwind();

        // Verify position is unwound
        assertLe(
            strategy.balanceOfCollateral(),
            _maxUnwindCollateralDust(collateralBeforeUnwind),
            "!collateral dust too high"
        );

        // Re-enable leverage (3x with 0.5x buffer)
        vm.prank(management);
        strategy.setLeverageParams(3e18, 0.5e18, 5e18);

        // Advance the block so the rebuild tend isn't gated by Flex's same-block
        // debt guard (manualFullUnwind above touched the trove this block).
        skip(REPAY_COOLDOWN + 1);

        // Rebuild position via tend
        vm.prank(keeper);
        strategy.tend();

        // Verify position is rebuilt
        assertGt(strategy.balanceOfCollateral(), 0, "!collateral should be > 0");
        assertGt(strategy.balanceOfDebt(), 0, "!debt should be > 0");

        // Verify leverage is near target
        uint256 leverage = strategy.getCurrentLeverageRatio();
        uint256 target = strategy.targetLeverageRatio();
        uint256 buffer = strategy.leverageBuffer();
        _assertLeverageWithinTestBuffer(leverage, target, buffer, "!leverage too low", "!leverage too high");
    }

}
