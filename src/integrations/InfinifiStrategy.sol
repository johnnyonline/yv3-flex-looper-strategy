// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.23;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IInfiniFiGatewayV1} from "../interfaces/IInfiniFiGatewayV1.sol";
import {IRedeemController} from "../interfaces/IRedeemController.sol";

import {BaseLooper, ERC20, FlexLooperStrategy, Math} from "../Strategy.sol";

contract InfinifiFlexLooperStrategy is FlexLooperStrategy {

    using SafeERC20 for ERC20;

    // ===============================================================
    // Storage
    // ===============================================================

    /// @notice iUSD queued in InfiniFi's redemption controller
    uint256 public queuedReceipts;

    /// @notice Whether reports ignore the pending redemptions, an escape hatch for management
    bool public ignorePending;

    // ===============================================================
    // Constants
    // ===============================================================

    /// @notice Pending amount below which reports are not blocked, for rounding dust InfiniFi leaves behind
    uint256 internal constant _PENDING_DUST = 1_000; // 0.001 USDC

    /// @notice USDC token
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    /// @notice siUSD token
    address public constant SIUSD = 0xDBDC1Ef57537E34680B898E1FEBD3D68c7389bCB;

    /// @notice iUSD receipt token
    address public constant IUSD = 0x48f9e38f3070AD8945DFEae3FA70987722E3D89c;

    /// @notice InfiniFi Gateway
    IInfiniFiGatewayV1 public constant GATEWAY = IInfiniFiGatewayV1(0x3f04b65Ddbd87f9CE0A2e7Eb24d80e7fb87625b5);

    // ===============================================================
    // Constructor
    // ===============================================================

    /// @param _name Strategy name
    /// @param _troveManager The Flex Trove Manager contract of a siUSD/USDC market
    /// @param _allowRedemption Whether borrows may trigger a collateral redemption
    /// @param _governance The address allowed to update exchange configuration
    constructor(
        string memory _name,
        address _troveManager,
        bool _allowRedemption,
        address _governance
    ) FlexLooperStrategy(USDC, SIUSD, _name, _troveManager, address(0), _allowRedemption, _governance) {
        // InfiniFi converts 1:1, slippage only covers rounding
        slippage = 1;

        // Max approve the Gateway to pull USDC (mint), siUSD (unstake), and iUSD (redeem)
        ERC20(USDC).forceApprove(address(GATEWAY), type(uint256).max);
        ERC20(SIUSD).forceApprove(address(GATEWAY), type(uint256).max);
        ERC20(IUSD).forceApprove(address(GATEWAY), type(uint256).max);
    }

    // ===============================================================
    // Conversions
    // ===============================================================

    /// @inheritdoc BaseLooper
    function _convertAssetToCollateral(
        uint256 _amount
    ) internal override returns (uint256 _amountOut) {
        if (_amount == 0) return 0;

        _updateSlippageLossLimit();

        // USDC --> iUSD --> siUSD
        uint256 _balanceBefore = balanceOfCollateralToken();
        GATEWAY.mintAndStake(address(this), _amount);
        _amountOut = balanceOfCollateralToken() - _balanceBefore;

        _recordSlippage(_amount, _collateralToAsset(_amountOut));
    }

    /// @inheritdoc BaseLooper
    function _convertCollateralToAsset(
        uint256 _amount
    ) internal override returns (uint256 _amountOut) {
        if (_amount == 0) return 0;

        _updateSlippageLossLimit();

        uint256 _expected = _collateralToAsset(_amount);

        // siUSD --> iUSD
        uint256 _receipts = GATEWAY.unstake(address(this), _amount);

        // iUSD --> USDC, all of it instantly or revert. Only `initiateCooldown()` may queue
        _amountOut = GATEWAY.redeem(address(this), _receipts, _redeemController().receiptToAsset(_receipts));

        _recordSlippage(_expected, _amountOut);
    }

    // ===============================================================
    // Accounting
    // ===============================================================

    /// @notice Asset value queued in InfiniFi's redemption controller
    function pendingRedemptions() public view returns (uint256) {
        uint256 _queuedReceipts = queuedReceipts;
        return _queuedReceipts == 0 ? 0 : _redeemController().receiptToAsset(_queuedReceipts);
    }

    /// @inheritdoc BaseLooper
    function estimatedTotalAssets() public view override returns (uint256) {
        return super.estimatedTotalAssets() + pendingRedemptions();
    }

    /// @inheritdoc BaseLooper
    function _harvestAndReport() internal override returns (uint256) {
        // Block reports until everything queued is back as asset, unless management says otherwise
        require(ignorePending || pendingRedemptions() <= _PENDING_DUST, "!cooldown");
        return super._harvestAndReport();
    }

    /// @inheritdoc BaseLooper
    function availableWithdrawLimit(
        address _owner
    ) public view override returns (uint256) {
        // Collateral can't be redeemed instantly while InfiniFi's queue is non-empty
        if (_isRedeemQueued()) return balanceOfAsset();
        return super.availableWithdrawLimit(_owner);
    }

    /// @inheritdoc BaseLooper
    function _maxBorrowAmount() internal view override returns (uint256) {
        // Redeemed collateral can't be converted back while InfiniFi's queue is non-empty
        if (_isRedeemQueued()) return asset.balanceOf(LENDER);
        return super._maxBorrowAmount();
    }

    // ===============================================================
    // Cooldown
    // ===============================================================

    /// @notice Set whether reports ignore the pending redemptions
    /// @param _ignorePending Whether to ignore the pending redemptions
    function setIgnorePending(
        bool _ignorePending
    ) external onlyManagement {
        ignorePending = _ignorePending;
    }

    /// @notice Unstake loose siUSD and redeem it for USDC, queueing whatever can't be redeemed instantly
    /// @param _shares The amount of siUSD to unwind, capped by the loose balance
    /// @param _minAssetsOut The minimum amount of USDC redeemed instantly
    /// @return _assetsOut The amount of USDC received instantly
    /// @return _pendingAssets The amount of USDC queued in InfiniFi's redemption controller
    function initiateCooldown(
        uint256 _shares,
        uint256 _minAssetsOut
    ) external onlyEmergencyAuthorized returns (uint256 _assetsOut, uint256 _pendingAssets) {
        _shares = Math.min(_shares, balanceOfCollateralToken());
        require(_shares > 0, "!shares");

        // siUSD --> iUSD
        uint256 _receipts = GATEWAY.unstake(address(this), _shares);

        // iUSD --> USDC. Anything not redeemed instantly is queued
        IRedeemController _redeemController_ = _redeemController();
        uint256 _queuedBefore = _redeemController_.totalEnqueuedRedemptions();
        _assetsOut = GATEWAY.redeem(address(this), _receipts, _minAssetsOut);

        // Record the queued iUSD, the queue only grows within our redemption
        uint256 _queued = _redeemController_.totalEnqueuedRedemptions() - _queuedBefore;
        queuedReceipts += _queued;
        _pendingAssets = _redeemController_.receiptToAsset(_queued);
    }

    /// @notice Claim queued redemptions from InfiniFi
    /// @return _assets The amount of USDC claimed
    function claimCooldown() external onlyKeepers returns (uint256 _assets) {
        IRedeemController _redeemController_ = _redeemController();
        require(_redeemController_.userPendingClaims(address(this)) > 0, "!claim");

        uint256 _balanceBefore = balanceOfAsset();
        GATEWAY.claimRedemption();
        _assets = balanceOfAsset() - _balanceBefore;

        // Settle the claimed iUSD, converted back at the controller's rate
        uint256 _receipts = _assets * WAD / _redeemController_.receiptToAsset(WAD);
        uint256 _queuedReceipts = queuedReceipts;
        queuedReceipts = _receipts >= _queuedReceipts ? 0 : _queuedReceipts - _receipts;
    }

    // ===============================================================
    // Internal views
    // ===============================================================

    /// @notice Whether InfiniFi's redemption queue is non-empty, which queues every new redemption
    function _isRedeemQueued() internal view returns (bool) {
        return _redeemController().queueLength() > 0;
    }

    /// @notice InfiniFi's redemption controller, read live in case it's replaced
    function _redeemController() internal view returns (IRedeemController) {
        return IRedeemController(GATEWAY.getAddress("redeemController"));
    }

}
