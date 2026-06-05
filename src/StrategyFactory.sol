// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.18;

import {Strategy, ERC20} from "./Strategy.sol";
import {IStrategyInterface} from "./interfaces/IStrategyInterface.sol";

contract StrategyFactory {
    event NewStrategy(address indexed strategy, address indexed asset);

    address public immutable emergencyAdmin;

    address public management;
    address public performanceFeeRecipient;
    address public keeper;

    /// @notice Track the deployments. troveManager (market) => strategy
    mapping(address => address) public deployments;

    constructor(address _management, address _performanceFeeRecipient, address _keeper, address _emergencyAdmin) {
        management = _management;
        performanceFeeRecipient = _performanceFeeRecipient;
        keeper = _keeper;
        emergencyAdmin = _emergencyAdmin;
    }

    /**
     * @notice Deploy a new Strategy.
     * @param _asset The underlying asset (the market's borrow token, e.g. USDC).
     * @param _collateralToken The market's collateral token.
     * @param _name The name for the strategy.
     * @param _troveManager The Flex Trove Manager (the market) to loop on.
     * @param _exchange The exchange used for collateral <--> asset swaps.
     * @param _debtInFrontHelper The Flex Debt-In-Front Helper.
     * @param _allowRedemption Whether borrows may redeem (vault-redeem markets only).
     * @return . The address of the new strategy.
     */
    function newStrategy(
        address _asset,
        address _collateralToken,
        string calldata _name,
        address _troveManager,
        address _exchange,
        address _debtInFrontHelper,
        bool _allowRedemption
    ) external virtual returns (address) {
        // tokenized strategies available setters.
        IStrategyInterface _newStrategy = IStrategyInterface(
            address(
                new Strategy(
                    _asset,
                    _collateralToken,
                    _name,
                    _troveManager,
                    _exchange,
                    _debtInFrontHelper,
                    _allowRedemption,
                    management // governance
                )
            )
        );

        _newStrategy.setPerformanceFeeRecipient(performanceFeeRecipient);

        _newStrategy.setKeeper(keeper);

        _newStrategy.setPendingManagement(management);

        _newStrategy.setEmergencyAdmin(emergencyAdmin);

        emit NewStrategy(address(_newStrategy), _asset);

        // Keyed by Trove Manager: one strategy per market (an asset can back several markets).
        deployments[_troveManager] = address(_newStrategy);
        return address(_newStrategy);
    }

    function setAddresses(address _management, address _performanceFeeRecipient, address _keeper) external {
        require(msg.sender == management, "!management");
        management = _management;
        performanceFeeRecipient = _performanceFeeRecipient;
        keeper = _keeper;
    }

    function isDeployedStrategy(address _strategy) external view returns (bool) {
        address _troveManager = IStrategyInterface(_strategy).TROVE_MANAGER();
        return deployments[_troveManager] == _strategy;
    }
}
