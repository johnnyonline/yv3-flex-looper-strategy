// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import {Setup, ERC20, IStrategyInterface} from "./utils/Setup.sol";
import {ITroveManager} from "../interfaces/ITroveManager.sol";

import {ExchangeMock} from "./mocks/ExchangeMock.sol";

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
        vm.prank(keeper);
        strategy.adjustInterestRate(_newRate, 0, 0, type(uint256).max);

        assertEq(ITroveManager(troveManager).troves(_troveId).annualInterestRate, _newRate, "!rate");
        assertGe(strategy.balanceOfDebt(), _debtBefore, "!debt");
    }

    function test_adjustInterestRate_onlyKeepers() public {
        vm.expectRevert("!keeper");
        vm.prank(user);
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

        address _newExchange =
            address(new ExchangeMock(address(asset), yvusd, address(ITroveManager(troveManager).price_oracle())));

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

}
