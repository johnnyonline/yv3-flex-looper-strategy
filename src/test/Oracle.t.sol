pragma solidity ^0.8.18;

import "forge-std/console2.sol";
import {Setup} from "./utils/Setup.sol";
import {ITroveManager} from "../interfaces/ITroveManager.sol";

import {StrategyAprOracle} from "../periphery/StrategyAprOracle.sol";

contract OracleTest is Setup {

    StrategyAprOracle public oracle;

    function setUp() public override {
        super.setUp();
        oracle = new StrategyAprOracle();
    }

    function checkOracle(
        address _strategy,
        uint256 _delta
    ) public view {
        uint256 currentApr = oracle.aprAfterDebtChange(_strategy, 0);
        console2.log("Current APR:", currentApr);

        // Should be greater than 0 but likely less than 100%
        assertGt(currentApr, 0, "ZERO");
        assertLt(currentApr, 1e18, "+100%");

        // Depositing dilutes the collateral vault's APR, withdrawing concentrates it
        uint256 negativeDebtChangeApr = oracle.aprAfterDebtChange(_strategy, -int256(_delta));
        assertGe(negativeDebtChangeApr, currentApr, "negative change");

        uint256 positiveDebtChangeApr = oracle.aprAfterDebtChange(_strategy, int256(_delta));
        assertLe(positiveDebtChangeApr, currentApr, "positive change");
    }

    function test_oracle(
        uint256 _amount,
        uint16 _percentChange
    ) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);
        _percentChange = uint16(bound(uint256(_percentChange), 10, MAX_BPS));

        // At the seed Trove's high rate the loop carries negative, so the APR floors at 0
        assertEq(oracle.aprAfterDebtChange(address(strategy), 0), 0, "!negative carry");

        // Drop the Trove rate to the minimum so the loop earns a positive spread
        uint256 _minRate = ITroveManager(troveManager).min_annual_interest_rate();
        vm.prank(keeper);
        strategy.adjustInterestRate(_minRate, 0, 0, type(uint256).max);

        mintAndDepositIntoStrategy(strategy, user, _amount);

        uint256 _delta = (_amount * _percentChange) / MAX_BPS;

        checkOracle(address(strategy), _delta);
    }

}
