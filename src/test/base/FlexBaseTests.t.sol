// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import {BaseOperationTest} from "./Operation.t.sol";
import {BaseShutdownTest} from "./Shutdown.t.sol";
import {BaseLeverScenariosTest} from "./LeverScenarios.t.sol";

/// @notice Runs the vendored tokenized-looper base test suites against the Flex Setup.
///         The base contracts are abstract; these concrete runners wire them to our
///         Flex Setup (which opens the seed trove and seeds lender liquidity in setUp).
contract FlexBaseOperationTest is BaseOperationTest {

    function setUp() public override {
        super.setUp();
    }

}

contract FlexBaseShutdownTest is BaseShutdownTest {

    function setUp() public override {
        super.setUp();
    }

}

contract FlexBaseLeverScenariosTest is BaseLeverScenariosTest {

    function setUp() public override {
        super.setUp();
    }

}
