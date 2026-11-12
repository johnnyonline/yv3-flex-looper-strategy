// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {LidoFlexLooperStrategy} from "../../integrations/LidoStrategy.sol";
import {IStrategyInterface} from "../../interfaces/IStrategyInterface.sol";
import {ITroveManager} from "../../interfaces/ITroveManager.sol";

import {Setup, ERC20} from "./Setup.sol";

/// @notice Setup for the wstETH/WETH looper on the live market, converting through the live WETHWstETHExchange
abstract contract LidoSetup is Setup {

    address public constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address public constant WSTETH_TROVE_MANAGER = 0x5fF405CC51705D609F7F2CCc2Bb36a66675938fC; // wstETH/WETH market
    address public constant WETH_WSTETH_EXCHANGE = 0x706AA50385C51596b6d9cBcf97645C6a98940c03; // WETHWstETHExchange

    function setUp() public virtual override {
        vm.createSelectFork(vm.envString("ETH_RPC_URL"), 26_364_000);

        _setTokenAddrs();

        // Set asset / collateral
        asset = ERC20(tokenAddrs["WETH"]);
        collateral = ERC20(WSTETH);
        decimals = asset.decimals();

        // Fuzz from 1 WETH up to 1k WETH
        minFuzzAmount = 1e18;
        maxFuzzAmount = 1_000e18;

        troveManager = WSTETH_TROVE_MANAGER;
        lender = ITroveManager(troveManager).lender();

        // Without redemption the strategy only borrows the lender's idle, so seed plenty
        _seedLenderLiquidity(100_000e18);

        // Deploy strategy and set variables
        strategy = IStrategyInterface(_deployLidoStrategy());

        // Forge's first deploy address holds stray mainnet ETH, which `claimCooldown` would wrap as a gain
        vm.deal(address(strategy), 0);

        _openInitialTrove(strategy);

        factory = strategy.FACTORY();

        // label all the used addresses for traces
        vm.label(keeper, "keeper");
        vm.label(factory, "factory");
        vm.label(lender, "lender");
        vm.label(WSTETH, "collateral");
        vm.label(address(asset), "asset");
        vm.label(management, "management");
        vm.label(troveManager, "troveManager");
        vm.label(WETH_WSTETH_EXCHANGE, "wethWstethExchange");
        vm.label(address(strategy), "strategy");
        vm.label(performanceFeeRecipient, "performanceFeeRecipient");
    }

    function _deployLidoStrategy() internal returns (address) {
        // we save the strategy as a IStrategyInterface to give it the needed interface
        IStrategyInterface _strategy = IStrategyInterface(
            address(
                new LidoFlexLooperStrategy(
                    "wstETH/WETH Flex Looper", // _name
                    troveManager, // _troveManager
                    WETH_WSTETH_EXCHANGE, // _exchange
                    management // _governance
                )
            )
        );

        // Set the roles, as the deploy script does
        _strategy.setPerformanceFeeRecipient(performanceFeeRecipient);
        _strategy.setKeeper(keeper);
        _strategy.setPendingManagement(management);
        _strategy.setEmergencyAdmin(emergencyAdmin);

        vm.startPrank(management);
        _strategy.acceptManagement();
        _strategy.setAllowed(user, true);
        _strategy.setAllowed(seeder, true);
        _strategy.setMaxGasPriceToTend(type(uint256).max);
        _strategy.setProfitMaxUnlockTime(0);
        _strategy.setSlippage(10); // Deploy uses 2, which blocks Curve exits until SMS raises it
        vm.stopPrank();

        return address(_strategy);
    }

}
