// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.23;

import {IStrategyInterface} from "../src/interfaces/IStrategyInterface.sol";

import {LidoFlexLooperStrategy} from "../src/integrations/LidoStrategy.sol";
import {StrategyAprOracle} from "../src/periphery/StrategyAprOracle.sol";

import "forge-std/Script.sol";

interface IAprOracle {

    function setOracle(
        address _strategy,
        address _oracle
    ) external;

}

// ---- Usage ----
// forge script script/DeployLido.s.sol:DeployLido --verify --slow -g 150 --etherscan-api-key $KEY --rpc-url $ETH_RPC_URL --broadcast

// verify:
// --constructor-args $(cast abi-encode "constructor(string,address,address,address)" "wstETH/WETH Flex Looper" 0x5fF405CC51705D609F7F2CCc2Bb36a66675938fC 0x706AA50385C51596b6d9cBcf97645C6a98940c03 0xFEB4acf3df3cDEA7399794D0869ef76A6EfAff52)

contract DeployLido is Script {

    address private constant TROVE_MANAGER = 0x5fF405CC51705D609F7F2CCc2Bb36a66675938fC; // wstETH/WETH market
    address private constant EXCHANGE = 0x706AA50385C51596b6d9cBcf97645C6a98940c03; // WETHWstETHExchange

    address private constant DEPLOYER = 0x420ACF637D662b80cca8bEfb327AA24039E7e0Fa; // gm.johnnyonline.eth
    address private constant SMS = 0x16388463d60FFE0661Cf7F1f31a7D658aC790ff7; // sms mainnet
    address private constant KEEPER = 0x604e586F17cE106B64185A7a0d2c1Da5bAce711E; // yHaaS mainnet
    address private constant EMERGENCY_ADMIN = 0xe5e2Baf96198c56380dDD5E992D7d1ADa0e989c0; // sam mainnet
    address private constant PERFORMANCE_FEE_RECIPIENT = 0x5A74Cb32D36f2f517DB6f7b0A0591e09b22cDE69; // Accountant mainnet
    address private constant CHAD = 0xFEB4acf3df3cDEA7399794D0869ef76A6EfAff52; // Chad mainnet

    IAprOracle private constant CENTRAL_APR_ORACLE = IAprOracle(0x1981AD9F44F2EA9aDd2dC4AD7D075c102C70aF92);

    function run() external {
        uint256 _privateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address _deployer = vm.addr(_privateKey);
        require(_deployer == DEPLOYER, "!deployer");

        vm.startBroadcast(_privateKey);

        address _strategy = address(
            new LidoFlexLooperStrategy(
                "wstETH/WETH Flex Looper", // name
                TROVE_MANAGER, // troveManager
                EXCHANGE, // exchange
                CHAD // governance
            )
        );

        IStrategyInterface strategy = IStrategyInterface(_strategy);
        strategy.setLeverageParams(10e18, 0.5e18, 11e18); // 10x target, 0.5x buffer, 11x max (market MCR is 104% -> liquidates ~26x)
        strategy.setSlippage(2); // 0.02%, below Curve's ~2 bps cost, so SMS raises it before exits
        strategy.setAllowed(SMS, true);
        strategy.setKeeper(KEEPER);
        strategy.setPerformanceFeeRecipient(PERFORMANCE_FEE_RECIPIENT);
        strategy.setPerformanceFee(0);
        strategy.setProfitMaxUnlockTime(0);
        strategy.setEmergencyAdmin(EMERGENCY_ADMIN);

        // Deploy and register the looper APR oracle
        address _aprOracle = address(new StrategyAprOracle());
        CENTRAL_APR_ORACLE.setOracle(_strategy, _aprOracle);

        strategy.setPendingManagement(SMS);

        vm.stopBroadcast();

        console.log("-----------------------------");
        console.log("Strategy deployed at: ", _strategy);
        console.log("APR oracle deployed at: ", _aprOracle);
        console.log("-----------------------------");
    }

}
