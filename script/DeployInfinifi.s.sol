// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.23;

import {IStrategyInterface} from "../src/interfaces/IStrategyInterface.sol";

import {InfinifiFlexLooperStrategy} from "../src/integrations/InfinifiStrategy.sol";
import {InfinifiAprOracle} from "../src/periphery/InfinifiAprOracle.sol";

import "forge-std/Script.sol";

interface IAprOracle {

    function setOracle(
        address _strategy,
        address _oracle
    ) external;

}

// ---- Usage ----
// forge script script/DeployInfinifi.s.sol:DeployInfinifi --verify --slow -g 150 --etherscan-api-key $KEY --rpc-url $ETH_RPC_URL --broadcast

// verify:
// --constructor-args $(cast abi-encode "constructor(string,address,bool,address)" "siUSD/USDC Flex Looper" 0x0D50e97b521D62E1509Ca408ADE621658c367bed true 0xFEB4acf3df3cDEA7399794D0869ef76A6EfAff52)

contract DeployInfinifi is Script {

    address private constant TROVE_MANAGER = 0x0D50e97b521D62E1509Ca408ADE621658c367bed; // siUSD/USDC market

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
            new InfinifiFlexLooperStrategy(
                "siUSD/USDC Flex Looper", // name
                TROVE_MANAGER, // troveManager
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
        address _aprOracle = address(new InfinifiAprOracle());
        CENTRAL_APR_ORACLE.setOracle(_strategy, _aprOracle);

        strategy.setPendingManagement(SMS);

        vm.stopBroadcast();

        console.log("-----------------------------");
        console.log("Strategy deployed at: ", _strategy);
        console.log("APR oracle deployed at: ", _aprOracle);
        console.log("-----------------------------");
    }

}
