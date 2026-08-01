// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import "forge-std/console2.sol";
import {Setup, ERC20, IStrategyInterface} from "./utils/Setup.sol";
import {ITroveManager} from "../interfaces/ITroveManager.sol";
import {IDutchDesk} from "../interfaces/IDutchDesk.sol";

contract NoRedemptionTest is Setup {

    function setUp() public virtual override {
        super.setUp();
    }

    function _allowRedemption() internal view override returns (bool) {
        return false;
    }

    function test_setupStrategyOK_noRedemption() public view {
        assertFalse(strategy.ALLOW_REDEMPTION(), "!allowRedemption");
        assertTrue(strategy.troveId() != 0, "!troveId");
        assertEq(ITroveManager(troveManager).troves(strategy.troveId()).status, 1, "!active");

        // Debt is the nominal MIN_DEBT plus only the upfront fee, no redemption dust
        uint256 minDebt = strategy.MIN_DEBT();
        assertGe(strategy.balanceOfDebt(), minDebt, "!debt");
        assertLt(strategy.balanceOfDebt(), minDebt + minDebt / 100, "!fee");
    }

    function test_operation_noRedemption(
        uint256 _amount
    ) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        uint256 nonceBefore = IDutchDesk(strategy.DUTCH_DESK()).nonce();

        // Deploy funds via tend (since _deployFunds is empty to prevent sandwich attacks)
        vm.prank(keeper);
        strategy.tend();

        logStrategyStatus("After deposit");

        assertGt(strategy.totalAssets(), 0, "!totalAssets");

        // Levered to target from idle liquidity alone, no auction kicked
        _assertAtTargetLeverage();
        assertEq(IDutchDesk(strategy.DUTCH_DESK()).nonce(), nonceBefore, "!nonce");

        // Earn Interest
        accrueYield(_amount);

        // Report profit
        vm.prank(keeper);
        strategy.report();

        logStrategyStatus("After profit max unlock time");

        uint256 balanceBefore = asset.balanceOf(user);

        // Skip time to avoid closing on the same block
        skip(REPAY_COOLDOWN + 1);

        // Withdraw all funds
        vm.prank(user);
        strategy.redeem(_amount, user, user);

        assertGe(asset.balanceOf(user), balanceBefore, "!final balance");

        // Remaining position still levered to target after the withdraw
        _assertAtTargetLeverage();
    }

    function test_operation_noRedemption_cappedByIdle(
        uint256 _amount,
        uint256 _keep
    ) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount / 10);
        _keep = bound(_keep, 0, _amount);

        // Deposit, then leave only `_keep` idle in the lender so the lever-up is capped
        mintAndDepositIntoStrategy(strategy, user, _amount);
        _drainLenderIdle(_keep);

        uint256 debtBefore = strategy.balanceOfDebt();
        uint256 nonceBefore = IDutchDesk(strategy.DUTCH_DESK()).nonce();

        // Deploy funds via tend (since _deployFunds is empty to prevent sandwich attacks)
        vm.prank(keeper);
        strategy.tend();

        logStrategyStatus("After tend");

        // Borrow was capped at the lender's idle: under target, no redemption attempted
        assertLt(
            strategy.getCurrentLeverageRatio(), strategy.targetLeverageRatio() - strategy.leverageBuffer(), "!capped"
        );
        assertEq(IDutchDesk(strategy.DUTCH_DESK()).nonce(), nonceBefore, "!nonce");

        // Debt grew by at most the idle we left, plus the upfront fee
        assertLe(strategy.balanceOfDebt() - debtBefore, _keep + _keep / 100, "!debt");

        uint256 balanceBefore = asset.balanceOf(user);

        // Skip time to avoid repaying on the same block
        skip(REPAY_COOLDOWN + 1);

        // Withdraw all funds
        vm.startPrank(user);
        strategy.redeem(strategy.balanceOf(user), user, user);
        vm.stopPrank();

        assertGe(asset.balanceOf(user), balanceBefore, "!final balance");
    }

    function test_openTrove_noRedemption_insufficientIdleReverts() public {
        // Fresh strategy with no trove, seeded like the one in setUp
        IStrategyInterface _strategy = _deployStrategy();
        uint256 _minDebt = ITroveManager(troveManager).min_debt();
        mintAndDepositIntoStrategy(_strategy, seeder, _minDebt * 2);

        // Leave less idle than the MIN_DEBT the open must deliver atomically
        _drainLenderIdle(_minDebt / 2);

        uint256 _rate = ITroveManager(troveManager).min_annual_interest_rate() * 100;

        vm.prank(management);
        vm.expectRevert("!min_borrow_out");
        _strategy.openTrove(_rate, 0, 0, type(uint256).max);
    }

}
