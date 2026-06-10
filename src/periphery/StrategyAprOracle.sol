// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.23;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {AprOracleBase} from "@periphery/AprOracle/AprOracleBase.sol";

import {IStrategyInterface} from "../interfaces/IStrategyInterface.sol";
import {ITroveManager} from "../interfaces/ITroveManager.sol";
import {IPriceOracle} from "../interfaces/IPriceOracle.sol";
import {ICentralAprOracle} from "../interfaces/ICentralAprOracle.sol";

contract StrategyAprOracle is AprOracleBase {

    // ===============================================================
    // Constants
    // ===============================================================

    /// @notice The WAD constant
    uint256 internal constant _WAD = 1e18;

    /// @notice Precision of the Flex price oracle
    uint256 internal constant _ORACLE_PRICE_SCALE = 1e36;

    /// @notice Yearn's central APR oracle, used for the collateral vault's APR
    ICentralAprOracle public constant CENTRAL_APR_ORACLE =
        ICentralAprOracle(0x1981AD9F44F2EA9aDd2dC4AD7D075c102C70aF92);

    // ===============================================================
    // Constructor
    // ===============================================================

    constructor() AprOracleBase("Flex Looper Strategy Apr Oracle", address(0)) {}

    // ===============================================================
    // APR oracle
    // ===============================================================

    /// @inheritdoc AprOracleBase
    function aprAfterDebtChange(
        address _strategy,
        int256 _delta
    ) external view override returns (uint256) {
        IStrategyInterface _looper = IStrategyInterface(_strategy);

        uint256 _leverage = _looper.targetLeverageRatio();
        if (_leverage == 0) return 0;

        // Collateral APR from the central oracle, after our levered delta in collateral units
        int256 _collateralDelta = _delta * int256(_leverage) / int256(_WAD) * int256(_ORACLE_PRICE_SCALE)
            / int256(IPriceOracle(_looper.ORACLE()).get_price());
        uint256 _collateralApr = CENTRAL_APR_ORACLE.getStrategyApr(_looper.collateralToken(), _collateralDelta);

        // Borrow APR is the Trove's own annual rate, unaffected by size.
        // Flex scales it by borrow-token precision, convert it to WAD
        uint256 _borrowApr = ITroveManager(_looper.TROVE_MANAGER()).troves(_looper.troveId()).annualInterestRate * _WAD
            / 10 ** IERC20Metadata(_looper.asset()).decimals();

        // Levered collateral yield minus the borrow cost on the borrowed share
        uint256 _gross = _leverage * _collateralApr / _WAD;
        uint256 _cost = (_leverage - _WAD) * _borrowApr / _WAD;
        return _gross > _cost ? _gross - _cost : 0;
    }

}
