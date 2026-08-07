// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

// Adapted from tokenized-looper base tests for the Flex CDP looper: block
// advances for Flex's same-block debt guard, seed-trove-aware baselines, and
// MIN_DEBT-floor handling.

import "forge-std/console2.sol";
import {Setup} from "../utils/Setup.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title LeverScenariosTest
/// @notice Comprehensive tests for the _lever function in BaseLooper.sol
/// @dev Tests all scenarios: leveraging up, deleveraging, at-target, above-max, and edge cases
abstract contract BaseLeverScenariosTest is Setup {

    uint256 internal constant WAD = 1e18;
    uint256 internal constant LEVER_UNWIND_COLLATERAL_DUST_BPS = 2; // 0.02%
    uint256 internal constant MIN_LEVER_UNWIND_COLLATERAL_DUST = 1;

    function setUp() public virtual override {
        super.setUp();
    }

    /*//////////////////////////////////////////////////////////////
                            HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Setup a position at `targetLeverage` using the strategy's
    ///         real lever-up path.
    /// @dev Temporarily reconfigures `setLeverageParams` so the strategy's own
    ///      `tend()` flashloan path is what gets the position to the desired
    ///      leverage — equity is preserved, and the strategy lands with no
    ///      idle asset (just like in production). Original params are restored
    ///      before returning, so the test sees `targetLeverage` as off-target
    ///      relative to the strategy's normal config.
    /// @param depositAmount The amount to deposit
    /// @param targetLeverage The desired leverage ratio (WAD scale)
    function _setupPositionWithLeverage(
        uint256 depositAmount,
        uint256 targetLeverage
    ) internal {
        require(targetLeverage >= WAD, "targetLeverage < 1x");

        uint256 origTarget = strategy.targetLeverageRatio();
        uint256 origBuffer = strategy.leverageBuffer();
        uint256 origMax = strategy.maxLeverageRatio();

        bool reconfigure = targetLeverage != origTarget;

        if (reconfigure) {
            uint256 maxLev = targetLeverage + origBuffer + 0.5e18;
            if (maxLev < origMax) maxLev = origMax;
            vm.prank(management);
            strategy.setLeverageParams(targetLeverage, origBuffer, maxLev);
        }

        mintAndDepositIntoStrategy(strategy, user, depositAmount);

        vm.prank(keeper);
        strategy.tend();

        // Flex same-block debt guard: advance the block so the NEXT
        // trove-touching action by the caller does not revert "same block".
        skip(REPAY_COOLDOWN + 1);

        if (reconfigure) {
            vm.prank(management);
            strategy.setLeverageParams(origTarget, origBuffer, origMax);
        }

        // Real production tends drain idle. If a setup leaves loose asset
        // behind, the underlying strategy is masking a bug and we should not
        // hide it by silently tolerating idle here.
        assertLe(strategy.balanceOfAsset(), 1, "setup left idle asset; routing or strategy config is the issue");
    }

    /// @notice Setup an under-leveraged position (below target - buffer)
    /// @dev Creates a position that's below the lower buffer bound by:
    ///      1. First depositing and tending to get a 3x position
    ///      2. Then repaying debt to reduce leverage
    /// @param equity The equity amount to use for the position
    /// @return collateral The collateral value created
    /// @return debt The debt amount created
    function _setupUnderLeveragedPosition(
        uint256 equity
    ) internal returns (uint256 collateral, uint256 debt) {
        // 1. Deposit and tend to get a 3x position
        mintAndDepositIntoStrategy(strategy, user, equity);
        vm.prank(keeper);
        strategy.tend();

        // 2. Repay some debt to reduce leverage
        // At 3x: collateral = 3*equity, debt = 2*equity
        // To get under-leveraged, repay 25-30% of debt
        (uint256 currentCollateral, uint256 currentDebt) = strategy.position();
        uint256 repayAmount = currentDebt / 4; // Repay 25% of debt (more conservative)

        // Airdrop asset to repay (simpler than withdrawing collateral)
        airdrop(asset, address(strategy), repayAmount);

        // Flex same-block debt guard: advance the block before the manual repay,
        // which touches the trove after the setup tend above.
        skip(REPAY_COOLDOWN + 1);

        vm.startPrank(management);
        // Repay the debt with the airdropped asset
        strategy.manualRepay(repayAmount);
        vm.stopPrank();

        // Advance again so the caller's next trove-touching tend is in a fresh
        // block relative to this manual repay.
        skip(REPAY_COOLDOWN + 1);

        (collateral, debt) = strategy.position();
    }

    /// @notice Setup an over-leveraged position (above target + buffer)
    /// @param equity The equity amount to use for the position
    /// @return collateral The collateral value created
    /// @return debt The debt amount created
    function _setupOverLeveragedPosition(
        uint256 equity
    ) internal returns (uint256 collateral, uint256 debt) {
        uint256 targetLeverage = strategy.targetLeverageRatio();
        uint256 buffer = strategy.leverageBuffer();
        uint256 overLeverage = targetLeverage + buffer + 0.3e18; // Above upper bound

        _setupPositionWithLeverage(equity, overLeverage);

        (collateral, debt) = strategy.position();
    }

    /// @notice Setup an over-leveraged position with idle loose asset.
    /// @dev Specifically targets the case where a tend would otherwise take
    ///      the simple-path repay (`_amount >= debtToRepay`) — used to drive
    ///      tests through the residual flashloan branch where dust precision
    ///      matters. Mirrors what would happen if the strategy borrowed but
    ///      had not yet supplied collateral.
    function _setupOverLeveragedPositionWithIdle(
        uint256 equity
    ) internal returns (uint256 collateral, uint256 debt) {
        _setupOverLeveragedPosition(equity);

        (uint256 currentCollateral, uint256 currentDebt) = strategy.position();
        uint256 currentEquity = currentCollateral - currentDebt;
        (, uint256 targetDebt) = _getTargetPosition(currentEquity);
        require(currentDebt > targetDebt, "setup not over-leveraged");

        // Leave loose idle that covers part, but not all, of the delever
        // amount. This hits Case 2's residual flashloan branch without using
        // manualBorrow to push the position above max leverage.
        uint256 debtToRepay = currentDebt - targetDebt;
        uint256 targetLeverage = strategy.targetLeverageRatio();
        uint256 idleAmount = (debtToRepay * WAD) / (targetLeverage * 2);
        uint256 residualDebtToRepay = debtToRepay - (idleAmount * (targetLeverage - WAD)) / WAD;
        vm.assume(idleAmount > 0);
        vm.assume(residualDebtToRepay > idleAmount);
        vm.assume(residualDebtToRepay - idleAmount > strategy.minAmountToBorrow());
        airdrop(asset, address(strategy), idleAmount);

        assertGt(strategy.balanceOfAsset(), 0, "expected loose idle asset");

        (collateral, debt) = strategy.position();
    }

    /// @notice Setup a position at exactly target leverage
    /// @param equity The equity amount to use for the position
    /// @return collateral The collateral value created
    /// @return debt The debt amount created
    function _setupAtTargetPosition(
        uint256 equity
    ) internal returns (uint256 collateral, uint256 debt) {
        uint256 targetLeverage = strategy.targetLeverageRatio();

        _setupPositionWithLeverage(equity, targetLeverage);

        (collateral, debt) = strategy.position();
    }

    /// @notice Setup a position above max leverage (emergency territory)
    /// @param equity The equity amount to use for the position
    /// @return collateral The collateral value created
    /// @return debt The debt amount created
    function _setupAboveMaxLeveragePosition(
        uint256 equity
    ) internal returns (uint256 collateral, uint256 debt) {
        uint256 maxLeverage = strategy.maxLeverageRatio();
        uint256 emergencyLeverage = maxLeverage + 0.5e18; // Above max

        _setupPositionWithLeverage(equity, emergencyLeverage);

        (collateral, debt) = strategy.position();
    }

    /// @notice Assert that leverage is within target buffer
    function _assertLeverageWithinBuffer() internal view {
        uint256 leverage = strategy.getCurrentLeverageRatio();
        uint256 target = strategy.targetLeverageRatio();
        uint256 buffer = strategy.leverageBuffer();

        _assertLeverageWithinTestBuffer(leverage, target, buffer, "leverage too low", "leverage too high");
    }

    /// @notice Assert that leverage is at or below a specific value
    function _assertLeverageAtOrBelow(
        uint256 maxLeverage
    ) internal view {
        uint256 leverage = strategy.getCurrentLeverageRatio();
        assertLe(leverage, maxLeverage, "leverage exceeds max");
    }

    function _upperBoundarySetupBuffer() internal pure virtual returns (uint256) {
        return 0;
    }

    /// @notice Calculate the debt needed to achieve a specific leverage given equity
    function _calculateDebtForLeverage(
        uint256 equity,
        uint256 leverage
    ) internal pure returns (uint256) {
        uint256 collateral = (equity * leverage) / WAD;
        return collateral - equity;
    }

    /// @notice Get the minimum amount that would trigger a flashloan
    function _getMinFlashloanAmount() internal view returns (uint256) {
        return strategy.minAmountToBorrow();
    }

    function _leverScenarioBaseAmount() internal view returns (uint256) {
        uint256 min = minFuzzAmount;
        uint256 max = maxFuzzAmount;
        if (max <= min) return min;

        uint256 mid = (min + max) / 2;
        return mid > min ? mid : min;
    }

    function _maxLeverUnwindCollateralDust(
        uint256 collateralBeforeUnwind
    ) internal pure virtual returns (uint256) {
        uint256 relativeDust = collateralBeforeUnwind / (10_000 / LEVER_UNWIND_COLLATERAL_DUST_BPS);
        return relativeDust > MIN_LEVER_UNWIND_COLLATERAL_DUST ? relativeDust : MIN_LEVER_UNWIND_COLLATERAL_DUST;
    }

    /// @notice Calculate target position for a given equity
    /// @dev Mirrors BaseLooper.getTargetPosition()
    function _getTargetPosition(
        uint256 equity
    ) internal view returns (uint256 collateral, uint256 debt) {
        uint256 targetCollateral = (equity * strategy.targetLeverageRatio()) / WAD;
        uint256 targetDebt = targetCollateral - equity;
        return (targetCollateral, targetDebt);
    }

    /*//////////////////////////////////////////////////////////////
                    GROUP 1: CASE 1 (NEED MORE DEBT - LEVER UP)
    //////////////////////////////////////////////////////////////*/

    /// @notice Test Case 1: First deposit, leverage up via flashloan
    function test_lever_noPosition_normalAmount(
        uint256 _amount
    ) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // Flex seed trove: the strategy starts with the seed position, so the
        // "no position" baseline is the seed (not literal zero).
        (uint256 collateralBefore, uint256 debtBefore) = strategy.position();

        // 1. Setup: No user position yet, deposit funds
        mintAndDepositIntoStrategy(strategy, user, _amount);

        // 2. Verify position before tend is still just the seed (deposit is idle)
        (uint256 collateralPreTend, uint256 debtPreTend) = strategy.position();
        assertEq(collateralPreTend, collateralBefore, "collateral should be unchanged before tend (seed only)");
        assertEq(debtPreTend, debtBefore, "debt should be unchanged before tend (seed only)");

        // 3. Execute tend (which calls _lever)
        vm.prank(keeper);
        strategy.tend();

        // 4. Verify position grew beyond the seed baseline with leverage
        (uint256 collateralAfter, uint256 debtAfter) = strategy.position();
        assertGt(collateralAfter, collateralBefore, "should have more collateral after");
        assertGt(debtAfter, debtBefore, "should have more debt after");

        // 5. Verify leverage is within target buffer
        _assertLeverageWithinBuffer();
    }

    /// @notice Case 1: when the required flashloan would land below
    ///         `minAmountToBorrow`, lever-up does not take debt and the
    ///         supply-only fallback is also gated by `minAmountToBorrow` —
    ///         so a tend with a small deposit and a high min is a no-op.
    function test_lever_noPosition_smallAmount_belowMin_skipsTend() public {
        // Flex: the seed trove starts under target (~2x), so first lever it to target and
        // advance the block. Otherwise any tend levers the seed up regardless of the tiny
        // user deposit, and the min-borrow gate cannot be isolated.
        vm.prank(keeper);
        strategy.tend();
        skip(REPAY_COOLDOWN + 1);

        // Raise the min-borrow gate above the would-be flashloan for a tiny deposit.
        vm.prank(management);
        strategy.setMinAmountToBorrow(_assetAmount(1000));

        // Baseline at target.
        uint256 baseDebt = strategy.balanceOfDebt();
        uint256 baseCollateral = strategy.balanceOfCollateral();

        uint256 smallAmount = _assetAmount(100);
        mintAndDepositIntoStrategy(strategy, user, smallAmount);

        vm.prank(keeper);
        strategy.tend();

        // Flashloan (~2x the deposit) <= min, so the case-1 small-flashloan branch falls back
        // to _convertAndSupplyCollateral(_amount); _amount is <= min too, so it returns early.
        // Net effect: no new debt, no new collateral, the deposit stays loose idle.
        assertEq(strategy.balanceOfDebt(), baseDebt, "no new debt should be taken");
        assertEq(strategy.balanceOfCollateral(), baseCollateral, "no new collateral should be supplied");
        assertEq(strategy.balanceOfAsset(), smallAmount, "idle should stay loose");
    }

    /// @notice Test Case 1: Existing under-leveraged position, add funds and lever up
    function test_lever_underLeveraged_normalAmount(
        uint256 _amount
    ) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // 1. Setup: Create under-leveraged position
        uint256 equity = _leverScenarioBaseAmount();
        (uint256 initialCollateral, uint256 initialDebt) = _setupUnderLeveragedPosition(equity);

        // 2. Verify under-leveraged (below target, ideally below lower buffer)
        uint256 leverageBefore = strategy.getCurrentLeverageRatio();
        uint256 target = strategy.targetLeverageRatio();
        uint256 buffer = strategy.leverageBuffer();
        // The setup should create a position significantly below target
        assertLt(leverageBefore, target, "should be under-leveraged (below target)");

        // 3. Add new funds
        airdrop(asset, address(strategy), _amount);

        // 4. Execute tend
        vm.prank(keeper);
        strategy.tend();

        // 5. Verify leverage moved toward target
        _assertLeverageWithinBuffer();

        // 6. Verify debt increased (leveraged up)
        uint256 debtAfter = strategy.balanceOfDebt();
        assertGt(debtAfter, initialDebt, "debt should increase when levering up");
    }

    /// @notice Test Case 1b: Small addition to under-leveraged position when flashloan threshold is high
    /// @dev When the flashloan amount would be below minAmountToBorrow, the strategy
    ///      just repays min(_amount, balanceOfDebt) instead of doing a flashloan.
    function test_lever_underLeveraged_smallAmount() public {
        // Set high min flashloan threshold
        vm.prank(management);
        strategy.setMinAmountToBorrow(_assetAmount(1000));

        // 1. Setup: Create under-leveraged position
        uint256 equity = _assetAmount(10_000);
        _setupUnderLeveragedPosition(equity);

        // 2. Verify under-leveraged
        uint256 leverageBefore = strategy.getCurrentLeverageRatio();
        uint256 target = strategy.targetLeverageRatio();
        uint256 buffer = strategy.leverageBuffer();
        assertLt(leverageBefore, target, "should be under-leveraged (below target)");

        // 3. Get debt before adding funds
        uint256 debtBefore = strategy.balanceOfDebt();

        // 4. Add small amount (below flashloan threshold, so resulting flashloan amount would be small)
        uint256 smallAmount = _assetAmount(50);
        airdrop(asset, address(strategy), smallAmount);

        // 5. Execute tend
        vm.prank(keeper);
        strategy.tend();

        // 6. Since the required flashloan amount is below minAmountToBorrow,
        // the code enters Case 1b: just _repay(min(_amount, balanceOfDebt))
        // This should repay some debt with the small amount
        uint256 debtAfter = strategy.balanceOfDebt();

        // The debt should be reduced by approximately the small amount repaid
        // (or debt stays same if debt was 0, or increases if different case hit)
        // The key behavior: no flashloan was executed, so position was not leveraged up
        // The leverage should still be under-leveraged or slightly changed
        uint256 leverageAfter = strategy.getCurrentLeverageRatio();
        assertLt(leverageAfter, target + buffer, "leverage should not exceed upper bound");
    }

    /// @notice Test Case 1: Rebalance under-leveraged position with no new funds
    function test_lever_underLeveraged_zeroAmount(
        uint256 equityAmount
    ) public {
        vm.assume(equityAmount > minFuzzAmount && equityAmount < maxFuzzAmount);

        // 1. Setup: Create under-leveraged position
        _setupUnderLeveragedPosition(equityAmount);

        // 2. Verify under-leveraged
        uint256 leverageBefore = strategy.getCurrentLeverageRatio();
        uint256 target = strategy.targetLeverageRatio();
        uint256 buffer = strategy.leverageBuffer();
        assertLt(leverageBefore, target, "should be under-leveraged (below target)");

        // 3. Execute tend with no new funds (rebalance only)
        vm.prank(keeper);
        strategy.tend();

        // 4. Verify leverage moved toward target
        _assertLeverageWithinBuffer();
    }

    /*//////////////////////////////////////////////////////////////
                    GROUP 2: CASE 2 (NEED LESS DEBT - DELEVER)
    //////////////////////////////////////////////////////////////*/

    /// @notice Test Case 2: Delever via flashloan only (no new funds)
    /// @dev When over-leveraged with no new funds, the strategy deleverage to reach target.
    ///      This is Case 2b in _lever: flashloan to repay debt, withdraw collateral to cover.
    function test_lever_overLeveraged_zeroAmount(
        uint256 equityAmount
    ) public {
        vm.assume(equityAmount > minFuzzAmount && equityAmount < maxFuzzAmount);

        // 1. Setup: Create over-leveraged position
        _setupOverLeveragedPosition(equityAmount);

        // 2. Verify over-leveraged
        uint256 leverageBefore = strategy.getCurrentLeverageRatio();
        uint256 target = strategy.targetLeverageRatio();
        uint256 buffer = strategy.leverageBuffer();
        assertGt(leverageBefore, target + buffer, "should be over-leveraged");

        // 3. Get position state before tend
        (, uint256 debtBefore) = strategy.position();

        // 4. Execute tend with no new funds
        vm.prank(keeper);
        strategy.tend();

        // 5. Verify leverage moved toward target (primary assertion)
        _assertLeverageWithinBuffer();

        // 6. Verify debt decreased relative to the before-tend state
        // (deleveraging should reduce debt to reach target)
        uint256 debtAfter = strategy.balanceOfDebt();
        assertLt(debtAfter, debtBefore, "debt should decrease when deleveraging from over-leveraged state");
    }

    /// @notice Test Case 2b: Delever with small _amount helping repay
    /// @dev When over-leveraged and adding a small amount, the _lever function:
    ///      1. Calculates new equity = collateral - debt + _amount
    ///      2. Calculates target debt based on new equity
    ///      3. Uses flashloan to reach target (Case 2b: repay _amount first, then flashloan rest)
    function test_lever_overLeveraged_smallAmount(
        uint256 equityAmount
    ) public {
        vm.assume(equityAmount > minFuzzAmount && equityAmount < maxFuzzAmount);

        // 1. Setup: Create over-leveraged position
        _setupOverLeveragedPosition(equityAmount);

        // 2. Verify over-leveraged
        uint256 leverageBefore = strategy.getCurrentLeverageRatio();
        uint256 target = strategy.targetLeverageRatio();
        uint256 buffer = strategy.leverageBuffer();
        assertGt(leverageBefore, target + buffer, "should be over-leveraged");

        // 3. Get position state BEFORE adding new funds
        (uint256 collateralBefore, uint256 debtBefore) = strategy.position();
        uint256 equityBefore = collateralBefore - debtBefore;

        // 4. Calculate small amount: should be less than what would be needed to reach target
        // without flashloan (i.e., less than debtToRepay based on current equity)
        (, uint256 targetDebtBeforeNewFunds) = _getTargetPosition(equityBefore);
        uint256 debtToRepayWithoutNewFunds = debtBefore - targetDebtBeforeNewFunds;
        uint256 smallAmount = debtToRepayWithoutNewFunds / 4; // 25% of what's needed

        // 5. Add small amount
        airdrop(asset, address(strategy), smallAmount);

        // 6. Execute tend
        vm.prank(keeper);
        strategy.tend();

        // 7. Verify leverage moved toward target (this is the key assertion)
        _assertLeverageWithinBuffer();

        // 8. Verify the position was adjusted: with a small amount added,
        // the new target accounts for the added equity, so we expect
        // the final leverage to be within buffer
        uint256 leverageAfter = strategy.getCurrentLeverageRatio();
        assertGe(leverageAfter, target - buffer, "leverage should be at or above lower bound");
        assertLe(leverageAfter, target + buffer, "leverage should be at or below upper bound");
    }

    /// @notice Test Case 2a: _amount covers full repayment + remainder supplied
    function test_lever_overLeveraged_largeAmount(
        uint256 equityAmount
    ) public {
        vm.assume(equityAmount > minFuzzAmount && equityAmount < maxFuzzAmount);

        // 1. Setup: Create over-leveraged position
        (uint256 initialCollateral, uint256 initialDebt) = _setupOverLeveragedPosition(equityAmount);

        // 2. Verify over-leveraged
        uint256 leverageBefore = strategy.getCurrentLeverageRatio();
        uint256 target = strategy.targetLeverageRatio();
        uint256 buffer = strategy.leverageBuffer();
        assertGt(leverageBefore, target + buffer, "should be over-leveraged");

        // 3. Calculate debt to repay
        (uint256 currentCollateral, uint256 currentDebt) = strategy.position();
        uint256 currentEquity = currentCollateral - currentDebt;
        (, uint256 targetDebt) = _getTargetPosition(currentEquity);
        uint256 debtToRepay = currentDebt - targetDebt;

        // 4. Add large amount (more than debtToRepay)
        uint256 largeAmount = debtToRepay * 2; // 2x what's needed
        airdrop(asset, address(strategy), largeAmount);

        // 5. Execute tend
        vm.prank(keeper);
        strategy.tend();

        // 6. Verify leverage is within buffer
        // Note: with large amount, the new equity changes target position
        _assertLeverageWithinBuffer();

        // 7. Verify collateral increased (remainder was supplied)
        (uint256 collateralAfter,) = strategy.position();
        assertGt(collateralAfter, initialCollateral, "collateral should increase");
    }

    /// @notice Test Case 2 boundary: _amount exactly equals debtToRepay
    function test_lever_overLeveraged_exactDebtToRepay(
        uint256 equityAmount
    ) public {
        vm.assume(equityAmount > minFuzzAmount && equityAmount < maxFuzzAmount);

        // 1. Setup: Create over-leveraged position
        (uint256 initialCollateral, uint256 initialDebt) = _setupOverLeveragedPosition(equityAmount);

        // 2. Verify over-leveraged
        uint256 leverageBefore = strategy.getCurrentLeverageRatio();
        uint256 target = strategy.targetLeverageRatio();
        uint256 buffer = strategy.leverageBuffer();
        assertGt(leverageBefore, target + buffer, "should be over-leveraged");

        // 3. Calculate exact debt to repay to reach target
        (uint256 currentCollateral, uint256 currentDebt) = strategy.position();
        uint256 currentEquity = currentCollateral - currentDebt;
        (, uint256 targetDebt) = _getTargetPosition(currentEquity);
        uint256 debtToRepay = currentDebt - targetDebt;

        // 4. Add exactly debtToRepay
        airdrop(asset, address(strategy), debtToRepay);

        // 5. Execute tend
        vm.prank(keeper);
        strategy.tend();

        // 6. Verify final state - should be very close to target
        uint256 leverageAfter = strategy.getCurrentLeverageRatio();
        // Allow some tolerance due to the equity being recalculated with added amount
        assertLe(leverageAfter, target + buffer + 0.1e18, "leverage should be near target");
    }

    /// @notice Case 2b should cap deleveraging flashloan size by maxAmountToSwap
    function test_lever_overLeveraged_maxAmountToSwap_capsDeleverage(
        uint256 equityAmount
    ) public virtual {
        vm.assume(equityAmount > minFuzzAmount && equityAmount < maxFuzzAmount);

        (uint256 collateralBefore, uint256 debtBefore) = _setupOverLeveragedPosition(equityAmount);

        uint256 target = strategy.targetLeverageRatio();
        uint256 buffer = strategy.leverageBuffer();
        uint256 leverageBefore = strategy.getCurrentLeverageRatio();
        assertGt(leverageBefore, target + buffer, "should be over-leveraged");

        uint256 currentEquity = collateralBefore - debtBefore;
        (, uint256 targetDebt) = _getTargetPosition(currentEquity);
        uint256 debtToRepay = debtBefore - targetDebt;
        vm.assume(debtToRepay > 0);

        uint256 maxSwap = debtToRepay / 4;
        vm.assume(maxSwap > 0);

        vm.prank(management);
        strategy.setMaxAmountToSwap(maxSwap);

        vm.prank(keeper);
        strategy.tend();

        uint256 debtAfter = strategy.balanceOfDebt();
        uint256 leverageAfter = strategy.getCurrentLeverageRatio();
        uint256 debtReduction = debtBefore - debtAfter;

        assertGt(debtReduction, 0, "should repay some debt");
        assertLe(debtReduction, maxSwap, "delever should respect maxAmountToSwap");
        assertLt(leverageAfter, leverageBefore, "leverage should improve");
        assertGt(leverageAfter, target + buffer, "position should still be over target");
    }

    /// @notice Case 2b should do nothing when maxAmountToSwap is zero
    function test_lever_overLeveraged_zeroMaxAmountToSwap_skipsDeleverage(
        uint256 equityAmount
    ) public {
        vm.assume(equityAmount > minFuzzAmount && equityAmount < maxFuzzAmount);

        _setupOverLeveragedPosition(equityAmount);

        uint256 target = strategy.targetLeverageRatio();
        uint256 buffer = strategy.leverageBuffer();
        uint256 collateralBefore = strategy.balanceOfCollateral();
        uint256 debtBefore = strategy.balanceOfDebt();
        uint256 leverageBefore = strategy.getCurrentLeverageRatio();
        assertGt(leverageBefore, target + buffer, "should be over-leveraged");

        vm.prank(management);
        strategy.setMaxAmountToSwap(0);

        vm.prank(keeper);
        strategy.tend();

        assertEq(strategy.balanceOfCollateral(), collateralBefore, "!collateral");
        assertEq(strategy.balanceOfDebt(), debtBefore, "!debt");
        assertEq(strategy.getCurrentLeverageRatio(), leverageBefore, "!leverage");
        assertGt(strategy.getCurrentLeverageRatio(), target + buffer, "should stay over-leveraged");
    }

    /// @notice Over-leveraged with loose idle that almost-but-not-quite covers
    ///         the over-leverage delta. Exercises Case 2's residual flashloan
    ///         branch (`_amount > 0`, `_amount < debtToRepay`).
    /// @dev `_setupOverLeveragedPositionWithIdle` is the only setup that
    ///      leaves loose asset behind on purpose — every other setup helper
    ///      drains idle so we don't hide this exact path. The path is
    ///      vulnerable to a dust-flashloan revert when `debtToRepay - _amount`
    ///      is small enough that swap-router rounding can't deliver enough
    ///      asset to repay the flashloan; this test should catch that.
    function test_lever_overLeveraged_withIdle_residualFlashloan(
        uint256 equityAmount
    ) public {
        vm.assume(equityAmount > minFuzzAmount && equityAmount < maxFuzzAmount);

        (, uint256 debtBefore) = _setupOverLeveragedPositionWithIdle(equityAmount);

        uint256 target = strategy.targetLeverageRatio();
        uint256 buffer = strategy.leverageBuffer();
        uint256 leverageBefore = strategy.getCurrentLeverageRatio();
        assertGt(leverageBefore, target + buffer, "!over-leveraged precondition");
        assertGt(strategy.balanceOfAsset(), 0, "!idle precondition");

        // Must not revert — the residual flashloan path is real production
        // behavior and should never depend on swap-router dust luck.
        vm.prank(keeper);
        strategy.tend();

        _assertLeverageWithinBuffer();
        assertLt(strategy.balanceOfDebt(), debtBefore, "debt should fall after delever");
    }

    /*//////////////////////////////////////////////////////////////
                        GROUP 3: CASE 3 (AT TARGET)
    //////////////////////////////////////////////////////////////*/

    /// @notice Test: When at target and adding significant funds, lever up to maintain target
    /// @dev When at target leverage and adding funds, the new equity increases the target debt,
    ///      which triggers Case 1 (need more debt) to maintain the target leverage ratio.
    ///      This is different from Case 3 which only triggers when _amount is tiny.
    function test_lever_withinBuffer_normalAmount(
        uint256 equityAmount
    ) public {
        vm.assume(equityAmount > minFuzzAmount && equityAmount < maxFuzzAmount);

        // 1. Setup: Create position at target leverage
        (uint256 initialCollateral, uint256 initialDebt) = _setupAtTargetPosition(equityAmount);

        // 2. Verify at target
        uint256 leverageBefore = strategy.getCurrentLeverageRatio();
        uint256 target = strategy.targetLeverageRatio();
        uint256 buffer = strategy.leverageBuffer();
        _assertLeverageWithinTestBuffer(
            leverageBefore, target, buffer, "should be within buffer (low)", "should be within buffer (high)"
        );

        // 3. Add normal amount of funds
        uint256 newAmount = equityAmount / 2;
        airdrop(asset, address(strategy), newAmount);

        // 4. Execute tend
        vm.prank(keeper);
        strategy.tend();

        // 5. Verify still within buffer (should lever up to maintain target)
        _assertLeverageWithinBuffer();

        // 6. Verify position grew - both collateral and debt should increase
        // because we're levering up with the new funds
        (uint256 collateralAfter,) = strategy.position();
        uint256 debtAfter = strategy.balanceOfDebt();
        assertGt(collateralAfter, initialCollateral, "collateral should increase");
        assertGt(debtAfter, initialDebt, "debt should increase (levered up with new funds)");
    }

    /// @notice Test Case 3: No-op when at target with no funds
    /// @dev When already at target leverage and no new funds to deploy,
    ///      the position should remain essentially unchanged.
    function test_lever_withinBuffer_zeroAmount(
        uint256 equityAmount
    ) public {
        vm.assume(equityAmount > minFuzzAmount && equityAmount < maxFuzzAmount);

        // 1. Setup: Create position at target leverage
        _setupAtTargetPosition(equityAmount);

        // 2. Verify at target
        uint256 leverageBefore = strategy.getCurrentLeverageRatio();
        uint256 target = strategy.targetLeverageRatio();
        uint256 buffer = strategy.leverageBuffer();
        _assertLeverageWithinTestBuffer(
            leverageBefore, target, buffer, "should be within buffer (low)", "should be within buffer (high)"
        );

        // 4. Execute tend with no new funds
        vm.prank(keeper);
        strategy.tend();

        // 5. Verify leverage is still within buffer (main assertion)
        _assertLeverageWithinBuffer();

        // 6. Verify position remained stable
        // Note: Due to interest accrual and oracle price changes, there may be small changes
        // The key assertion is that leverage remains within buffer
        uint256 leverageAfter = strategy.getCurrentLeverageRatio();
        _assertLeverageWithinTestBuffer(
            leverageAfter,
            target,
            buffer,
            "leverage should remain within buffer (low)",
            "leverage should remain within buffer (high)"
        );
    }

    /*//////////////////////////////////////////////////////////////
                    GROUP 4: ABOVE MAX LEVERAGE (EMERGENCY)
    //////////////////////////////////////////////////////////////*/

    /// @notice Test: Emergency delever when above max leverage with no funds
    function test_lever_aboveMax_zeroAmount(
        uint256 equityAmount
    ) public {
        vm.assume(equityAmount > minFuzzAmount && equityAmount < maxFuzzAmount);

        // 1. Setup: Create position above max leverage
        _setupAboveMaxLeveragePosition(equityAmount);

        // 2. Verify above max
        uint256 leverageBefore = strategy.getCurrentLeverageRatio();
        uint256 maxLeverage = strategy.maxLeverageRatio();
        assertGt(leverageBefore, maxLeverage, "should be above max leverage");

        // 3. Execute tend (should trigger emergency delever)
        vm.prank(keeper);
        strategy.tend();

        // 4. Verify leverage came down
        uint256 leverageAfter = strategy.getCurrentLeverageRatio();
        assertLt(leverageAfter, leverageBefore, "leverage should decrease");

        // 5. Verify within acceptable range
        _assertLeverageWithinBuffer();
    }

    /// @notice Test: Emergency delever when above max leverage with normal funds
    function test_lever_aboveMax_normalAmount(
        uint256 equityAmount
    ) public {
        vm.assume(equityAmount > minFuzzAmount && equityAmount < maxFuzzAmount);

        // 1. Setup: Create position above max leverage
        _setupAboveMaxLeveragePosition(equityAmount);

        // 2. Verify above max
        uint256 leverageBefore = strategy.getCurrentLeverageRatio();
        uint256 maxLeverage = strategy.maxLeverageRatio();
        assertGt(leverageBefore, maxLeverage, "should be above max leverage");

        // 3. Add funds
        uint256 newAmount = equityAmount / 2;
        airdrop(asset, address(strategy), newAmount);

        // 4. Execute tend
        vm.prank(keeper);
        strategy.tend();

        // 5. Verify leverage came down significantly
        uint256 leverageAfter = strategy.getCurrentLeverageRatio();
        assertLt(leverageAfter, leverageBefore, "leverage should decrease");

        // 6. Verify within buffer
        _assertLeverageWithinBuffer();
    }

    /*//////////////////////////////////////////////////////////////
                            GROUP 5: EDGE CASES
    //////////////////////////////////////////////////////////////*/

    /// @notice Test edge case: Very over-leveraged with medium amount
    /// This tests the specific case where _amount > debtToRepay but position is still Case 2
    function test_lever_veryOverLeveraged_mediumAmount(
        uint256 equityAmount
    ) public {
        vm.assume(equityAmount > minFuzzAmount && equityAmount < maxFuzzAmount);

        // 1. Setup: Create significantly over-leveraged position
        uint256 targetLeverage = strategy.targetLeverageRatio();
        uint256 buffer = strategy.leverageBuffer();
        uint256 veryOverLeverage = targetLeverage + buffer + 1e18; // Well above buffer

        _setupPositionWithLeverage(equityAmount, veryOverLeverage);

        // 2. Verify very over-leveraged
        uint256 leverageBefore = strategy.getCurrentLeverageRatio();
        assertGt(leverageBefore, targetLeverage + buffer, "should be very over-leveraged");

        // 3. Calculate debt to repay
        (uint256 currentCollateral, uint256 currentDebt) = strategy.position();
        uint256 currentEquity = currentCollateral - currentDebt;
        (, uint256 targetDebt) = _getTargetPosition(currentEquity);
        uint256 debtToRepay = currentDebt - targetDebt;

        // 4. Add medium amount (between debtToRepay/2 and debtToRepay)
        uint256 mediumAmount = (debtToRepay * 3) / 4;
        airdrop(asset, address(strategy), mediumAmount);

        // 5. Execute tend
        vm.prank(keeper);
        strategy.tend();

        // 6. Verify leverage moved toward target
        _assertLeverageWithinBuffer();
    }

    /// @notice Test boundary: Position near lower buffer boundary
    /// @dev Due to the complexity of precise leverage setup, we verify
    ///      that the position is reasonably close to the lower boundary
    function test_lever_atLowerBufferBoundary(
        uint256 equityAmount
    ) public {
        vm.assume(equityAmount > minFuzzAmount && equityAmount < maxFuzzAmount);

        // 1. Setup: Create position targeting lower buffer boundary
        uint256 targetLeverage = strategy.targetLeverageRatio();
        uint256 buffer = strategy.leverageBuffer();
        uint256 lowerBoundLeverage = targetLeverage - buffer;

        _setupPositionWithLeverage(equityAmount, lowerBoundLeverage);

        // 2. Verify position is around lower boundary (within 15% tolerance due to setup complexity)
        uint256 leverageBefore = strategy.getCurrentLeverageRatio();
        // Position should be reasonably close to target (actual position may vary due to debt adjustment mechanics)
        assertGt(leverageBefore, lowerBoundLeverage - 0.5e18, "leverage should be near lower bound");
        assertLt(leverageBefore, targetLeverage + buffer, "leverage should not exceed upper bound");

        // 3. Execute tend with no new funds
        vm.prank(keeper);
        strategy.tend();

        // 4. Verify leverage is within or moving toward buffer after tend
        _assertLeverageWithinBuffer();
    }

    /// @notice Test boundary: Exactly at upper buffer boundary
    function test_lever_atUpperBufferBoundary(
        uint256 equityAmount
    ) public {
        vm.assume(equityAmount > minFuzzAmount && equityAmount < maxFuzzAmount);

        // 1. Setup: Create position exactly at target + buffer
        uint256 targetLeverage = strategy.targetLeverageRatio();
        uint256 buffer = strategy.leverageBuffer();
        uint256 upperBoundLeverage = targetLeverage + buffer;

        _setupPositionWithLeverage(equityAmount, upperBoundLeverage);

        // 2. Verify at upper boundary
        uint256 leverageBefore = strategy.getCurrentLeverageRatio();
        _assertLeverageWithinTestBuffer(
            leverageBefore,
            upperBoundLeverage,
            _upperBoundarySetupBuffer(),
            "should be at upper bound",
            "should be at upper bound"
        );

        // 3. Execute tend with no new funds
        vm.prank(keeper);
        strategy.tend();

        // 4. Verify leverage stayed within buffer
        _assertLeverageWithinBuffer();
    }

    /*//////////////////////////////////////////////////////////////
                    ADDITIONAL EDGE CASE TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Test multiple sequential tends maintain leverage
    function test_lever_sequentialTends(
        uint256 _amount
    ) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // 1. Setup: Normal deposit and tend
        mintAndDepositIntoStrategy(strategy, user, _amount);

        vm.prank(keeper);
        strategy.tend();

        _assertLeverageWithinBuffer();

        uint256 leverageAfterFirstTend = strategy.getCurrentLeverageRatio();
        uint256 target = strategy.targetLeverageRatio();
        uint256 buffer = strategy.leverageBuffer();
        bool shouldSkipSecondTend =
            strategy.balanceOfAsset() <= 1 && _isWithinTestBuffer(leverageAfterFirstTend, target, buffer);

        // 2. Second tend should maintain leverage
        if (!shouldSkipSecondTend) {
            vm.prank(keeper);
            strategy.tend();

            _assertLeverageWithinBuffer();
        }

        // 3. Third tend after adding small funds
        uint256 smallAdd = _amount / 10;
        airdrop(asset, address(strategy), smallAdd);

        vm.prank(keeper);
        strategy.tend();

        _assertLeverageWithinBuffer();
    }

    /// @notice Test tend with minimum possible amount
    function test_lever_minimumAmount() public {
        // 1. Deposit absolute minimum
        uint256 minAmount = minFuzzAmount;
        mintAndDepositIntoStrategy(strategy, user, minAmount);

        // 2. Tend
        vm.prank(keeper);
        strategy.tend();

        // 3. Should either achieve target or be handled gracefully
        uint256 leverage = strategy.getCurrentLeverageRatio();
        // Either at target or position is too small to leverage
        assertTrue(
            leverage == WAD || (leverage >= strategy.targetLeverageRatio() - strategy.leverageBuffer()),
            "leverage should be valid"
        );
    }

    /// @notice Test tend with maximum amount
    function test_lever_maximumAmount() public {
        // 1. Deposit maximum test amount
        uint256 maxAmount = maxFuzzAmount;
        mintAndDepositIntoStrategy(strategy, user, maxAmount);

        // 2. Tend
        vm.prank(keeper);
        strategy.tend();

        // 3. Verify leverage
        _assertLeverageWithinBuffer();
    }

    /// @notice Test Case 2: When _amount exactly pays off all target debt reduction
    function test_lever_overLeveraged_amountCoversExactDebtReduction() public {
        uint256 equityAmount = _assetAmount(10_000);

        // 1. Setup: Create moderately over-leveraged position
        uint256 targetLeverage = strategy.targetLeverageRatio();
        uint256 buffer = strategy.leverageBuffer();
        uint256 overLeverage = targetLeverage + buffer + 0.2e18;

        _setupPositionWithLeverage(equityAmount, overLeverage);

        // 2. Calculate exact amount needed to cover debt reduction
        (uint256 currentCollateral, uint256 currentDebt) = strategy.position();
        uint256 currentEquity = currentCollateral - currentDebt;
        (, uint256 targetDebt) = _getTargetPosition(currentEquity);
        uint256 debtToRepay = currentDebt > targetDebt ? currentDebt - targetDebt : 0;

        // 3. Add exactly debtToRepay (triggers Case 2a in _lever)
        if (debtToRepay > 0) {
            airdrop(asset, address(strategy), debtToRepay);

            // 4. Execute tend
            vm.prank(keeper);
            strategy.tend();

            // 5. Verify - with exact repayment, position should be close to target
            // The new equity includes the added amount, so target recalculates
            _assertLeverageWithinBuffer();
        }
    }

    /// @notice Test that _getTargetPosition helper returns correct values
    function test_getTargetPosition(
        uint256 equity
    ) public view {
        vm.assume(equity > _assetAmount(1) && equity < maxFuzzAmount);

        (uint256 targetCollateral, uint256 targetDebt) = _getTargetPosition(equity);

        // Verify: targetCollateral = equity * targetLeverageRatio / WAD
        uint256 expectedCollateral = (equity * strategy.targetLeverageRatio()) / WAD;
        assertEq(targetCollateral, expectedCollateral, "!targetCollateral");

        // Verify: targetDebt = targetCollateral - equity
        uint256 expectedDebt = targetCollateral - equity;
        assertEq(targetDebt, expectedDebt, "!targetDebt");

        // Verify leverage ratio: collateral / (collateral - debt) = collateral / equity
        uint256 impliedLeverage = (targetCollateral * WAD) / equity;
        assertEq(impliedLeverage, strategy.targetLeverageRatio(), "!impliedLeverage");
    }

    /// @notice Test position() returns correct values
    function test_positionAccuracy(
        uint256 _amount
    ) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        mintAndDepositIntoStrategy(strategy, user, _amount);

        vm.prank(keeper);
        strategy.tend();

        (uint256 collateralValue, uint256 debt) = strategy.position();
        uint256 currentLTV = strategy.getCurrentLTV();

        // Verify collateral value > 0
        assertGt(collateralValue, 0, "!collateralValue");

        // Verify debt > 0 (we're leveraged)
        assertGt(debt, 0, "!debt");

        // Verify LTV calculation: LTV = debt / collateralValue
        uint256 expectedLTV = (debt * WAD) / collateralValue;
        assertEq(currentLTV, expectedLTV, "!currentLTV calculation");

        // Verify leverage = 1 / (1 - LTV) approximately equals getCurrentLeverageRatio
        uint256 leverage = strategy.getCurrentLeverageRatio();
        uint256 expectedLeverage = (collateralValue * WAD) / (collateralValue - debt);
        assertApproxEqRel(leverage, expectedLeverage, 0.001e18, "!leverage calculation");
    }

    /// @notice `minAmountToBorrow` is a hard floor on lever-up: when set above
    ///         the flashloan needed to reach target, an under-leveraged
    ///         position stays under-leveraged on tend.
    /// @dev Guards against a regression where someone removes the
    ///      `flashloanAmount <= minAmountToBorrow` skip in `_lever` Case 1.
    function test_lever_underLeveraged_belowMin_skipsTend() public {
        // 1. Build a real under-leveraged position with the default min
        //    (so the helper's internal tend reaches 3x normally before the
        //    25% repay drops it under target).
        uint256 equity = _assetAmount(5_000);
        _setupUnderLeveragedPosition(equity);

        uint256 target = strategy.targetLeverageRatio();
        uint256 buffer = strategy.leverageBuffer();
        uint256 leverageBefore = strategy.getCurrentLeverageRatio();
        assertLt(leverageBefore, target - buffer, "precondition: under-leveraged");

        uint256 debtBefore = strategy.balanceOfDebt();
        uint256 collateralBefore = strategy.balanceOfCollateral();

        // 2. Now set min high so any rebalance flashloan falls below it.
        vm.prank(management);
        strategy.setMinAmountToBorrow(_assetAmount(1_000_000));

        // 3. Tend should leave the position untouched: no flashloan executes,
        //    no idle to deploy, so this is a clean no-op.
        vm.prank(keeper);
        strategy.tend();

        assertEq(strategy.balanceOfDebt(), debtBefore, "debt should not change");
        assertEq(strategy.balanceOfCollateral(), collateralBefore, "collateral should not change");
        assertEq(strategy.getCurrentLeverageRatio(), leverageBefore, "leverage should not change");
        assertLt(strategy.getCurrentLeverageRatio(), target - buffer, "still under-leveraged");
    }

    /// @notice Test lever with zero target leverage edge case
    function test_lever_afterLeverageParamChange(
        uint256 _amount
    ) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // 1. Setup: Normal deposit and tend at 3x
        mintAndDepositIntoStrategy(strategy, user, _amount);

        vm.prank(keeper);
        strategy.tend();

        uint256 leverageBefore = strategy.getCurrentLeverageRatio();
        _assertLeverageWithinBuffer();

        // 2. Change target to lower leverage
        vm.prank(management);
        strategy.setLeverageParams(2e18, 0.3e18, 5e18);

        // 3. Now the position is over-leveraged relative to new target
        uint256 newTarget = strategy.targetLeverageRatio();
        uint256 newBuffer = strategy.leverageBuffer();
        assertGt(
            leverageBefore, _upperLeverageBound(newTarget, newBuffer), "should be over-leveraged after param change"
        );

        // 4. Tend should delever to new target
        // Flex same-block debt guard: advance the block before the second,
        // debt-touching tend (the first tend updated the trove this block).
        skip(REPAY_COOLDOWN + 1);
        vm.prank(keeper);
        strategy.tend();

        // 5. Verify at new target
        uint256 leverageAfter = strategy.getCurrentLeverageRatio();
        _assertLeverageWithinTestBuffer(
            leverageAfter, newTarget, newBuffer, "leverage too low for new target", "leverage too high for new target"
        );
    }

    /// @notice Regresses full-debt repay when target leverage is 1x.
    /// @dev `debtToRepay == currentDebt` should not withdraw all collateral
    ///      unless target leverage is zero.
    function test_lever_toOneX_repayAllDebtKeepsCollateral() public virtual {
        vm.skip(true);
        // N/A on Flex: MIN_DEBT floor forbids debtless collateral (seed trove always holds >= MIN_DEBT)
        uint256 amount = _leverScenarioBaseAmount();
        mintAndDepositIntoStrategy(strategy, user, amount);

        vm.prank(keeper);
        strategy.tend();

        uint256 collateralBefore = strategy.balanceOfCollateral();
        uint256 debtBefore = strategy.balanceOfDebt();
        assertGt(collateralBefore, 0, "!collateral before");
        assertGt(debtBefore, strategy.minAmountToBorrow(), "!debt before");
        _assertLeverageWithinBuffer();

        vm.prank(management);
        strategy.setLeverageParams(WAD, 0.01e18, 5e18);

        vm.prank(keeper);
        strategy.tend();

        uint256 collateralAfter = strategy.balanceOfCollateral();
        uint256 debtAfter = strategy.balanceOfDebt();

        assertLe(debtAfter, strategy.minAmountToBorrow(), "!debt after");
        assertGt(collateralAfter, _maxLeverUnwindCollateralDust(collateralBefore), "1x target should keep collateral");
        assertLt(collateralAfter, collateralBefore, "!collateral reduced");
        assertApproxEqAbs(strategy.getCurrentLeverageRatio(), WAD, _leverageDust(), "!1x leverage");
    }

    /// @notice Zero target leverage still fully exits collateral on tend.
    function test_lever_zeroTarget_tendWithdrawsAllCollateral() public virtual {
        vm.skip(true);
        // N/A on Flex: MIN_DEBT floor forbids debtless collateral (seed trove always holds >= MIN_DEBT)
        uint256 amount = _leverScenarioBaseAmount();
        mintAndDepositIntoStrategy(strategy, user, amount);

        vm.prank(keeper);
        strategy.tend();

        uint256 collateralBefore = strategy.balanceOfCollateral();
        assertGt(collateralBefore, 0, "!collateral before");
        assertGt(strategy.balanceOfDebt(), 0, "!debt before");

        vm.prank(management);
        strategy.setLeverageParams(0, 0, 5e18);

        vm.prank(keeper);
        strategy.tend();

        assertLe(strategy.balanceOfDebt(), strategy.minAmountToBorrow(), "!debt after");
        assertLe(strategy.balanceOfCollateral(), _maxLeverUnwindCollateralDust(collateralBefore), "!collateral dust");
        assertGt(strategy.balanceOfAsset(), 0, "!idle asset");
    }

    /// @notice Test lever with increasing target leverage
    function test_lever_afterIncreasingTargetLeverage(
        uint256 _amount
    ) public virtual {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // 1. Setup: Lower initial target
        vm.prank(management);
        strategy.setLeverageParams(2e18, 0.3e18, 5e18);

        mintAndDepositIntoStrategy(strategy, user, _amount);

        vm.prank(keeper);
        strategy.tend();

        uint256 leverageBefore = strategy.getCurrentLeverageRatio();
        assertGe(leverageBefore, 2e18 - 0.3e18, "should be at 2x target");
        assertLe(leverageBefore, 2e18 + 0.3e18, "should be at 2x target");

        // 2. Increase target leverage
        vm.prank(management);
        strategy.setLeverageParams(4e18, 0.5e18, 6e18);

        // 3. Now position is under-leveraged
        uint256 newTarget = strategy.targetLeverageRatio();
        uint256 newBuffer = strategy.leverageBuffer();
        assertLt(leverageBefore, newTarget - newBuffer, "should be under-leveraged after param change");

        // 4. Tend should lever up
        vm.prank(keeper);
        strategy.tend();

        // 5. Verify at new target
        uint256 leverageAfter = strategy.getCurrentLeverageRatio();
        assertGe(leverageAfter, newTarget - newBuffer, "leverage too low for new target");
        assertLe(leverageAfter, newTarget + newBuffer, "leverage too high for new target");
    }

    /*//////////////////////////////////////////////////////////////
                    GROUP 6: MAX AMOUNT TO SWAP TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Test Case 1 with maxAmountToSwap limiting the flashloan
    /// @dev When totalSwap (_amount + flashloanAmount) > maxAmountToSwap,
    ///      the flashloan should be reduced to stay within limits
    function test_lever_maxAmountToSwap_limitsFlashloan(
        uint256 _amount
    ) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // Set a maxAmountToSwap that will limit the position building
        uint256 maxSwap = _amount * 2; // Allow 2x the deposit as max swap
        vm.prank(management);
        strategy.setMaxAmountToSwap(maxSwap);

        // Deposit funds
        mintAndDepositIntoStrategy(strategy, user, _amount);

        // Tend should respect maxAmountToSwap
        vm.prank(keeper);
        strategy.tend();

        // Verify position was created but limited
        (uint256 collateralValue, uint256 debt) = strategy.position();
        assertGt(collateralValue, 0, "!should have collateral");

        // The total swap should be approximately maxSwap or less
        // Since totalSwap = _amount + flashloanAmount, and flashloanAmount ~ debt
        // The debt + _amount should be around maxSwap
        // Note: actual behavior depends on slippage and conversions
        assertLe(
            debt + _amount,
            maxSwap + (maxSwap / 10), // Allow 10% tolerance for slippage
            "!total swap should be limited"
        );
    }

    /// @notice Test Case 1 when _amount alone exceeds maxAmountToSwap
    /// @dev When _amount >= maxAmountToSwap, should just swap maxAmountToSwap and supply
    function test_lever_maxAmountToSwap_amountExceedsMax() public {
        uint256 depositAmount = _assetAmount(10_000);
        uint256 maxSwap = _assetAmount(5_000); // Less than deposit amount

        // Set maxAmountToSwap less than deposit
        vm.prank(management);
        strategy.setMaxAmountToSwap(maxSwap);

        // Flex seed trove: baseline debt is the seed (~MIN_DEBT), not zero.
        uint256 seedDebt = strategy.balanceOfDebt();
        uint256 seedCollateral = strategy.balanceOfCollateral();

        // Deposit funds
        mintAndDepositIntoStrategy(strategy, user, depositAmount);

        // Tend should only swap maxSwap worth
        vm.prank(keeper);
        strategy.tend();

        // Position should have limited collateral
        // No NEW debt should be taken since we hit the early return
        uint256 debt = strategy.balanceOfDebt();
        assertEq(debt, seedDebt, "!should take no new debt when _amount exceeds maxSwap");

        // Should have some new collateral from the maxSwap conversion
        uint256 collateral = strategy.balanceOfCollateral();
        assertGt(collateral, seedCollateral, "!should have some new collateral");

        // Should have leftover asset
        uint256 looseAsset = strategy.balanceOfAsset();
        assertGt(looseAsset, 0, "!should have leftover asset");
    }

    /// @notice Test Case 1 with maxAmountToSwap = 0 (edge case)
    /// @dev When maxAmountToSwap is 0, should not swap anything
    function test_lever_maxAmountToSwap_zero() public {
        uint256 depositAmount = _assetAmount(10_000);
        uint256 looseCollateralDust = 1;

        // Set maxAmountToSwap to 0
        vm.prank(management);
        strategy.setMaxAmountToSwap(0);

        // Deposit funds
        mintAndDepositIntoStrategy(strategy, user, depositAmount);

        // Seed loose collateral token dust. A zero-sized convert must not supply it.
        deal(strategy.collateralToken(), address(strategy), strategy.balanceOfCollateralToken() + looseCollateralDust);

        uint256 assetBefore = strategy.balanceOfAsset();
        uint256 collateralBefore = strategy.balanceOfCollateral();
        uint256 looseCollateralBefore = strategy.balanceOfCollateralToken();
        // Flex seed trove: baseline debt is the seed (~MIN_DEBT), not zero.
        uint256 debtBefore = strategy.balanceOfDebt();

        // Tend should swap 0 (early return path)
        vm.prank(keeper);
        strategy.tend();

        assertEq(strategy.balanceOfDebt(), debtBefore, "!should take no new debt");
        assertEq(strategy.balanceOfAsset(), assetBefore, "!asset changed");
        assertEq(strategy.balanceOfCollateral(), collateralBefore, "!collateral changed");
        assertEq(strategy.balanceOfCollateralToken(), looseCollateralBefore, "!loose collateral changed");
    }

    /// @notice Test Case 3 respects maxAmountToSwap
    /// @dev Case 3: At target debt, just deploy _amount. Should respect maxAmountToSwap.
    function test_lever_case3_maxAmountToSwap(
        uint256 _amount
    ) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // First create a position at target leverage
        mintAndDepositIntoStrategy(strategy, user, _amount);
        vm.prank(keeper);
        strategy.tend();

        // Verify at target
        _assertLeverageWithinBuffer();

        // Now set a small maxAmountToSwap
        uint256 smallMax = _amount / 10;
        vm.prank(management);
        strategy.setMaxAmountToSwap(smallMax);

        // Add more funds - this should trigger Case 3 (at target, just deploy)
        airdrop(asset, address(strategy), _amount);

        uint256 collateralBefore = strategy.balanceOfCollateral();

        // Tend should only swap smallMax worth
        vm.prank(keeper);
        strategy.tend();

        uint256 collateralAfter = strategy.balanceOfCollateral();

        // Collateral should increase by approximately smallMax worth
        // (accounting for oracle price differences)
        assertGt(collateralAfter, collateralBefore, "!collateral should increase");

        // Should have leftover asset since we couldn't swap everything
        uint256 looseAsset = strategy.balanceOfAsset();
        assertGt(looseAsset, 0, "!should have leftover asset");
    }

    /// @notice Test maxAmountToSwap with type(uint256).max (default - no limit)
    function test_lever_maxAmountToSwap_noLimit(
        uint256 _amount
    ) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        uint256 configuredDefault = _defaultMaxAmountToSwap();
        assertEq(strategy.maxAmountToSwap(), configuredDefault, "!default maxAmountToSwap");

        if (configuredDefault != type(uint256).max) {
            vm.prank(management);
            strategy.setMaxAmountToSwap(type(uint256).max);
        }

        // Normal deposit and tend should work without limits
        mintAndDepositIntoStrategy(strategy, user, _amount);
        vm.prank(keeper);
        strategy.tend();

        // Should achieve target leverage
        _assertLeverageWithinBuffer();

        // Should have minimal or no leftover asset
        uint256 looseAsset = strategy.balanceOfAsset();
        assertLt(looseAsset, minFuzzAmount / 10, "!should have minimal leftover asset");
    }

    /// @notice Test that reducing flashloan respects minAmountToBorrow
    /// @dev When flashloan is reduced but still above minAmountToBorrow, should proceed
    function test_lever_maxAmountToSwap_reducedFlashloanAboveMin(
        uint256 _amount
    ) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // Set minAmountToBorrow
        uint256 minBorrow = _assetAmount(100);
        vm.prank(management);
        strategy.setMinAmountToBorrow(minBorrow);

        // Set maxAmountToSwap to allow some flashloan but not full target
        // At 3x leverage: flashloan = 2 * _amount, total = 3 * _amount
        // Set maxSwap to allow partial leverage
        uint256 maxSwap = (_amount * 3) / 2; // 1.5x deposit
        vm.prank(management);
        strategy.setMaxAmountToSwap(maxSwap);

        // Deposit
        mintAndDepositIntoStrategy(strategy, user, _amount);

        // Tend should execute with reduced flashloan
        vm.prank(keeper);
        strategy.tend();

        // Should have some debt (reduced flashloan was above minBorrow)
        uint256 debt = strategy.balanceOfDebt();
        if (_amount > minBorrow * 2) {
            // If _amount is large enough that reduced flashloan > minBorrow
            assertGt(debt, 0, "!should have some debt");
        }
    }

    /// @notice Test that reducing flashloan below minAmountToBorrow skips flashloan
    function test_lever_maxAmountToSwap_reducedFlashloanBelowMin() public {
        uint256 depositAmount = _assetAmount(1_000);

        // Set high minAmountToBorrow
        uint256 minBorrow = _assetAmount(2_000);
        vm.prank(management);
        strategy.setMinAmountToBorrow(minBorrow);

        // Set maxAmountToSwap that would reduce flashloan below minBorrow
        // Normal flashloan at 3x = 2 * 1000 = 2000
        // If we limit to 1500 total, flashloan = 500 which is < 2000 minBorrow
        uint256 maxSwap = _assetAmount(1_500);
        vm.prank(management);
        strategy.setMaxAmountToSwap(maxSwap);

        // Deposit
        mintAndDepositIntoStrategy(strategy, user, depositAmount);

        // Tend should skip flashloan (reduced amount below minBorrow)
        vm.prank(keeper);
        strategy.tend();

        // Flashloan skipped means Case 1b: just repay(min(_amount, debt))
        // Since no debt exists yet, this is essentially a no-op for debt
        // But maxAmountToSwap check happens before minAmountToBorrow check
        // So we might still get a supply without flashloan
    }

    /// @notice Test sequential tends with maxAmountToSwap gradually building position
    function test_lever_maxAmountToSwap_gradualBuild(
        uint256 _amount
    ) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // Set a small maxAmountToSwap to force multiple tends
        uint256 maxSwap = _amount / 3;
        vm.prank(management);
        strategy.setMaxAmountToSwap(maxSwap);

        // Deposit
        mintAndDepositIntoStrategy(strategy, user, _amount);

        // First tend - partial position
        vm.prank(keeper);
        strategy.tend();

        (uint256 collateral1, uint256 debt1) = strategy.position();
        uint256 leverage1 = strategy.getCurrentLeverageRatio();

        // Should have some position but not at full target
        assertGt(collateral1, 0, "!should have collateral after tend 1");

        // Remove maxAmountToSwap limit
        vm.prank(management);
        strategy.setMaxAmountToSwap(type(uint256).max);

        // Disable min tend interval for this test
        vm.prank(management);
        strategy.setMinTendInterval(0);

        // Second tend - should complete the position
        vm.prank(keeper);
        strategy.tend();

        (uint256 collateral2, uint256 debt2) = strategy.position();
        uint256 leverage2 = strategy.getCurrentLeverageRatio();

        // Position should be larger now
        assertGe(collateral2, collateral1, "!collateral should increase");

        // Should be closer to or at target leverage
        uint256 target = strategy.targetLeverageRatio();
        uint256 buffer = strategy.leverageBuffer();
        assertGe(leverage2, target - buffer, "!should reach target leverage");
    }

}
