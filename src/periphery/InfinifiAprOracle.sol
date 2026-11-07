// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.23;

import {IStakedToken} from "../interfaces/IStakedToken.sol";
import {IYieldSharingV2} from "../interfaces/IYieldSharingV2.sol";

import {StrategyAprOracle} from "./StrategyAprOracle.sol";

contract InfinifiAprOracle is StrategyAprOracle {

    // ===============================================================
    // Constants
    // ===============================================================

    /// @notice Seconds per year
    uint256 internal constant _SECONDS_PER_YEAR = 31_556_952;

    // ===============================================================
    // Internal views
    // ===============================================================

    /// @notice siUSD's APR from InfiniFi's yield sharing, the vesting rate over siUSD's assets after our delta
    /// @inheritdoc StrategyAprOracle
    function _getCollateralApr(
        address _collateral,
        int256 _collateralDelta
    ) internal view override returns (uint256) {
        IYieldSharingV2 _yieldSharing = IYieldSharingV2(IStakedToken(_collateral).yieldSharing());

        // Rewards stream at `rate` per second until the escrow has fully vested
        (,, uint208 _rate) = _yieldSharing.point();
        uint256 _ratePerSecond = _yieldSharing.vesting() > _yieldSharing.vested() ? _rate : 0;

        // Our delta in iUSD
        uint256 _absDelta = _collateralDelta < 0 ? uint256(-_collateralDelta) : uint256(_collateralDelta);
        uint256 _deltaAssets = IStakedToken(_collateral).convertToAssets(_absDelta);

        // siUSD's assets after our delta
        uint256 _assets = IStakedToken(_collateral).totalAssets() + _yieldSharing.vested();
        if (_collateralDelta < 0) _assets = _assets > _deltaAssets ? _assets - _deltaAssets : 0;
        else _assets += _deltaAssets;
        if (_assets == 0) return 0;

        return _ratePerSecond * _SECONDS_PER_YEAR * _WAD / _assets;
    }

}
