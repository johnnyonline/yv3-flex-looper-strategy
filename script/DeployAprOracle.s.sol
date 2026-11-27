// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.23;

import {StrategyAprOracle} from "../src/periphery/StrategyAprOracle.sol";

import "forge-std/Script.sol";

// ---- Usage ----
// forge script script/DeployAprOracle.s.sol:DeployAprOracle --verify --slow -g 150 --etherscan-api-key $KEY --rpc-url $RPC_URL --broadcast

contract DeployAprOracle is Script {

    address private constant DEPLOYER = 0x420ACF637D662b80cca8bEfb327AA24039E7e0Fa; // gm.johnnyonline.eth

    function run() external {
        uint256 _privateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address _deployer = vm.addr(_privateKey);
        require(_deployer == DEPLOYER, "!deployer");

        vm.startBroadcast(_privateKey);

        address _aprOracle = address(new StrategyAprOracle());

        vm.stopBroadcast();

        console.log("-----------------------------");
        console.log("APR oracle deployed at: ", _aprOracle);
        console.log("-----------------------------");
    }

}
