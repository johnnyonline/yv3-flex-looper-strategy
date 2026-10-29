// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.23;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

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

        // Rewards stream at `rate` per second, capped by what's left to vest. Accruals reset the
        // elapsed time, so count at least a second to still read the rate in the block of an accrual
        (uint32 _lastAccrued, uint32 _lastClaimed, uint208 _rate) = _yieldSharing.point();
        uint256 _elapsed = block.timestamp - Math.max(_lastAccrued, _lastClaimed);
        uint256 _ratePerSecond = Math.min(_rate, _yieldSharing.vesting() / Math.max(_elapsed, 1));

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
