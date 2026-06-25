// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.23;

import {IStrategyInterface} from "../src/interfaces/IStrategyInterface.sol";

import {FlexLooperStrategy as Strategy} from "../src/Strategy.sol";
import {StrategyAprOracle} from "../src/periphery/StrategyAprOracle.sol";

import "forge-std/Script.sol";

interface IAprOracle {

    function setOracle(
        address _strategy,
        address _oracle
    ) external;

}

// ---- Usage ----
// forge script script/Deploy.s.sol:Deploy --verify --slow -g 150 --etherscan-api-key $KEY --rpc-url $RPC_URL --broadcast

// verify:
// --constructor-args $(cast abi-encode "constructor(address,address,string,address,address,bool,address)" 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48 0x696d02Db93291651ED510704c9b286841d506987 "yvUSD/USDC Flex Looper" 0xd82DB9893751E9C90E2a6C3bE31183048E8E2e49 0x13100bB6AB4e349A36EAa6bD4ab0536Bf72b3054 true 0xFEB4acf3df3cDEA7399794D0869ef76A6EfAff52)

contract Deploy is Script {

    address private constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48; // asset
    address private constant YVUSD = 0x696d02Db93291651ED510704c9b286841d506987; // collateral
    address private constant TROVE_MANAGER = 0xd82DB9893751E9C90E2a6C3bE31183048E8E2e49; // yvUSD/USDC market
    address private constant EXCHANGE = 0x13100bB6AB4e349A36EAa6bD4ab0536Bf72b3054; // ERC4626Exchange

    address private constant DEPLOYER = 0x420ACF637D662b80cca8bEfb327AA24039E7e0Fa; // gm.johnnyonline.eth
    address private constant SMS = 0x16388463d60FFE0661Cf7F1f31a7D658aC790ff7; // sms mainnet
    address private constant KEEPER = 0x604e586F17cE106B64185A7a0d2c1Da5bAce711E; // yHaaS mainnet
    address private constant EMERGENCY_ADMIN = SMS;
    address private constant PERFORMANCE_FEE_RECIPIENT = 0x5A74Cb32D36f2f517DB6f7b0A0591e09b22cDE69; // Accountant mainnet
    address private constant CHAD = 0xFEB4acf3df3cDEA7399794D0869ef76A6EfAff52; // Chad mainnet

    IAprOracle private constant CENTRAL_APR_ORACLE = IAprOracle(0x1981AD9F44F2EA9aDd2dC4AD7D075c102C70aF92);

    function run() external {
        uint256 _privateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address _deployer = vm.addr(_privateKey);
        require(_deployer == DEPLOYER, "!deployer");

        vm.startBroadcast(_privateKey);

        address _strategy = address(
            new Strategy(
                USDC, // asset
                YVUSD, // collateralToken
                "yvUSD/USDC Flex Looper", // name
                TROVE_MANAGER, // troveManager
                EXCHANGE, // exchange
                true, // allowRedemption
                CHAD // governance
            )
        );

        IStrategyInterface strategy = IStrategyInterface(_strategy);
        strategy.setLeverageParams(10e18, 0.1e18, 10.5e18); // 10x target, 0.1x buffer, 10.5x max (market MCR is 110% -> liquidates ~10.9x)
        strategy.setAllowed(_deployer, true);
        strategy.setAllowed(SMS, true);
        strategy.setKeeper(KEEPER);
        strategy.setPerformanceFeeRecipient(PERFORMANCE_FEE_RECIPIENT);
        strategy.setPerformanceFee(0);
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

// yvUSD/USDC Flex Looper:  0x255f538312331e2921387Ea18D901c84a9614f90
// APR oracle deployed at:  0x1eCcDF4e8792CBAa21D2983290dD8042E9d5c0D7
