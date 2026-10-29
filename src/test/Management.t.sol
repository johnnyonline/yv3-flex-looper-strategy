// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import {Setup, ERC20, IStrategyInterface} from "./utils/Setup.sol";
import {ITroveManager} from "../interfaces/ITroveManager.sol";

contract ManagementTest is Setup {

    function setUp() public virtual override {
        super.setUp();
    }

    function test_openTrove_onlyManagement() public {
        vm.expectRevert("!management");
        vm.prank(user);
        strategy.openTrove(0, 0, 0, 0);
    }

    function test_openTrove_twiceReverts() public {
        vm.expectRevert("trove exists");
        vm.prank(management);
        strategy.openTrove(0, 0, 0, 0);
    }

    function test_openTrove_freshStrategy() public {
        IStrategyInterface fresh = _deployStrategy();
        assertEq(fresh.troveId(), 0, "!no trove");

        uint256 _seed = 2 * fresh.MIN_DEBT();
        mintAndDepositIntoStrategy(fresh, seeder, _seed);

        uint256 _rate = ITroveManager(troveManager).min_annual_interest_rate() * 100;
        vm.prank(management);
        fresh.openTrove(_rate, 0, 0, type(uint256).max);

        assertNotEq(fresh.troveId(), 0, "!troveId");
        ITroveManager.Trove memory _trove = ITroveManager(troveManager).troves(fresh.troveId());
        assertEq(_trove.status, 1, "!active");
        assertEq(_trove.owner, address(fresh), "!owner");
        assertGe(fresh.balanceOfDebt(), fresh.MIN_DEBT(), "!debt");
        assertGt(fresh.balanceOfCollateral(), 0, "!collateral");
        assertApproxEqRel(fresh.totalAssets(), _seed, 0.01e18, "!totalAssets");
    }

    function test_adjustInterestRate() public {
        uint256 _troveId = strategy.troveId();
        uint256 _rateBefore = ITroveManager(troveManager).troves(_troveId).annualInterestRate;
        uint256 _debtBefore = strategy.balanceOfDebt();

        // Adjusting within the cooldown charges an upfront fee, so allow the max
        uint256 _newRate = _rateBefore * 2;
        vm.prank(emergencyAdmin);
        strategy.adjustInterestRate(_newRate, 0, 0, type(uint256).max);

        assertEq(ITroveManager(troveManager).troves(_troveId).annualInterestRate, _newRate, "!rate");
        assertGe(strategy.balanceOfDebt(), _debtBefore, "!debt");
    }

    function test_adjustInterestRate_onlyEmergencyAuthorized() public {
        vm.expectRevert("!emergency authorized");
        vm.prank(keeper);
        strategy.adjustInterestRate(0, 0, 0, 0);
    }

    function test_setDebtInFrontHints(
        uint256 _amount
    ) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        vm.prank(keeper);
        strategy.setDebtInFrontHints(1, 2);

        assertEq(strategy.debtInFrontHintPrev(), 1, "!prev");
        assertEq(strategy.debtInFrontHintNext(), 2, "!next");

        // Bad hints cost gas, not correctness: the strategy still levers to target
        mintAndDepositIntoStrategy(strategy, user, _amount);
        vm.prank(keeper);
        strategy.tend();
        _assertAtTargetLeverage();
    }

    function test_setDebtInFrontHints_onlyKeepers() public {
        vm.expectRevert("!keeper");
        vm.prank(user);
        strategy.setDebtInFrontHints(1, 2);
    }

    function test_setExchange() public {
        assertEq(strategy.GOVERNANCE(), management, "!gov");

        // Conversions go through the InfiniFi Gateway, the exchange is only approved
        address _newExchange = address(0xBEEF);

        vm.expectRevert("!governance");
        vm.prank(user);
        strategy.setExchange(_newExchange);

        address _oldExchange = strategy.exchange();
        vm.prank(management);
        strategy.setExchange(_newExchange);

        // New exchange is set, allowances moved from the old exchange to the new one
        assertEq(strategy.exchange(), _newExchange, "!exchange");
        assertEq(asset.allowance(address(strategy), _oldExchange), 0, "!old asset");
        assertEq(collateral.allowance(address(strategy), _oldExchange), 0, "!old collateral");
        assertEq(asset.allowance(address(strategy), _newExchange), type(uint256).max, "!new asset");
        assertEq(collateral.allowance(address(strategy), _newExchange), type(uint256).max, "!new collateral");
    }

    function test_manualFullUnwind_closesAndReopens(
        uint256 _amount
    ) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);

        // Lever up a deposit
        mintAndDepositIntoStrategy(strategy, user, _amount);
        vm.prank(keeper);
        strategy.tend();
        _assertAtTargetLeverage();

        uint256 _oldTroveId = strategy.troveId();
        uint256 _totalAssetsBefore = strategy.estimatedTotalAssets();

        // Close the Trove without shutting down
        skip(REPAY_COOLDOWN + 1);
        vm.prank(emergencyAdmin);
        strategy.manualFullUnwind();

        assertEq(strategy.troveId(), 0, "!troveId");
        assertEq(ITroveManager(troveManager).troves(_oldTroveId).status, 4, "!closed");
        assertFalse(strategy.isShutdown(), "!shutdown");
        assertEq(strategy.targetLeverageRatio(), 0, "!target");
        assertEq(strategy.balanceOfDebt(), 0, "!debt");
        assertEq(strategy.balanceOfCollateral(), 0, "!collateral");
        assertApproxEqRel(strategy.estimatedTotalAssets(), _totalAssetsBefore, 0.001e18, "!totalAssets");

        // No deposits until management sets leverage again
        assertEq(strategy.availableDepositLimit(user), 0, "!deposits");

        // Realize the freed equity, then reopen in a later block (the owner index is the block number)
        vm.prank(emergencyAdmin);
        strategy.convertCollateralToAsset(type(uint256).max);
        vm.roll(block.number + 1);

        uint256 _rate = ITroveManager(troveManager).min_annual_interest_rate() * 100;
        vm.startPrank(management);
        strategy.openTrove(_rate, 0, 0, type(uint256).max);
        strategy.setLeverageParams(3e18, 0.25e18, 4e18);
        vm.stopPrank();

        assertNotEq(strategy.troveId(), _oldTroveId, "!new trove");
        assertEq(ITroveManager(troveManager).troves(strategy.troveId()).status, 1, "!active");

        // And lever back up
        vm.prank(keeper);
        strategy.tend();
        _assertAtTargetLeverage();
    }

    function test_manualFullUnwind_onlyEmergencyAuthorized() public {
        vm.expectRevert("!emergency authorized");
        vm.prank(keeper);
        strategy.manualFullUnwind();
    }

}
