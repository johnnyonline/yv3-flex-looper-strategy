// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.23;

import "forge-std/Script.sol";

import {ITroveManager} from "../src/interfaces/ITroveManager.sol";
import {IStrategyInterface} from "../src/interfaces/IStrategyInterface.sol";

interface IKeeper {

    function forwardCall(
        address target,
        bytes memory data
    ) external returns (bool success);

}

interface ISortedTroves {

    function find_insert_position(
        uint256 annualInterestRate,
        uint256 prevId,
        uint256 nextId
    ) external view returns (uint256 prevId_, uint256 nextId_);

}

// ---- Usage ----
// forge script script/AdjustRate.s.sol:AdjustRate --rpc-url $RPC_URL --broadcast

contract AdjustRate is Script {

    uint256 private constant MAX_BPS = 10_000;
    uint256 private constant SLIPPAGE_BPS = 100; // 1% headroom over the previewed upfront fee

    IKeeper private constant KEEPER = IKeeper(0x604e586F17cE106B64185A7a0d2c1Da5bAce711E); // yHaaS keeper
    IStrategyInterface private constant STRATEGY = IStrategyInterface(0x255f538312331e2921387Ea18D901c84a9614f90); // yvUSD/USDC Flex Looper

    // New annual interest rate in tenths of a percent (10 = 1%, 11 = 1.1%, 55 = 5.5%)
    uint256 private constant NEW_RATE = 50;

    function run() external {
        ITroveManager _troveManager = ITroveManager(STRATEGY.TROVE_MANAGER());
        uint256 _troveId = STRATEGY.troveId();

        // Flex scales rates by borrow-token precision (10**decimals = 100%); 1000 tenths-of-a-percent = 100%
        uint256 _newRate = NEW_RATE * (10 ** STRATEGY.decimals()) / 1000;

        // Sorted-troves insertion hints for the new rate (passing (0, 0) walks the list from ROOT)
        (uint256 _prevId, uint256 _nextId) = ISortedTroves(_troveManager.sorted_troves()).find_insert_position(_newRate, 0, 0);

        // Premature adjustments prepay interest on the current debt at the new rate; add a little headroom
        uint256 _debt = _troveManager.get_trove_debt_after_interest(_troveId);
        uint256 _maxUpfrontFee = _troveManager.get_upfront_fee(_debt, _newRate, true) * (MAX_BPS + SLIPPAGE_BPS) / MAX_BPS;

        console.log("rate before:", _troveManager.troves(_troveId).annualInterestRate);

        uint256 _privateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        vm.startBroadcast(_privateKey);

        // The keeper forwards the call, so msg.sender to the strategy is the keeper (onlyKeepers)
        bool _success = KEEPER.forwardCall(
            address(STRATEGY),
            abi.encodeWithSignature(
                "adjustInterestRate(uint256,uint256,uint256,uint256)", _newRate, _prevId, _nextId, _maxUpfrontFee
            )
        );
        require(_success, "!forwardCall");

        vm.stopBroadcast();

        console.log("rate after: ", _troveManager.troves(_troveId).annualInterestRate);
    }

}
