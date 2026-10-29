// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {Setup, ERC20} from "./utils/Setup.sol";
import {IGatewayMint, ILiveRedeemController} from "./interfaces/IInfiniFi.sol";
import {InfinifiFlexLooperStrategy} from "../integrations/InfinifiStrategy.sol";
import {IInfiniFiGatewayV1} from "../interfaces/IInfiniFiGatewayV1.sol";
import {IDutchDesk} from "../interfaces/IDutchDesk.sol";
import {ITroveManager} from "../interfaces/ITroveManager.sol";

/// @notice InfiniFi specific tests: conversions through the Gateway, and the cooldown for InfiniFi's redemption queue
contract InfinifiTest is Setup {

    using SafeERC20 for ERC20;

    address public constant IUSD = 0x48f9e38f3070AD8945DFEae3FA70987722E3D89c;

    InfinifiFlexLooperStrategy public looper;

    function setUp() public virtual override {
        super.setUp();
        looper = InfinifiFlexLooperStrategy(address(strategy));
    }

    function test_setupStrategyOK_infinifi() public view {
        assertEq(address(looper.GATEWAY()), gateway, "!gateway");
        assertEq(looper.exchange(), address(0), "!exchange");
        assertEq(looper.slippage(), 1, "!slippage");
        assertEq(looper.queuedReceipts(), 0, "!queued");
        assertEq(looper.pendingRedemptions(), 0, "!pending");
        assertFalse(looper.ignorePending(), "!ignorePending");
        assertGt(asset.allowance(address(looper), gateway), type(uint128).max, "!asset allowance");
        assertGt(collateral.allowance(address(looper), gateway), type(uint128).max, "!collateral allowance");
        assertGt(ERC20(IUSD).allowance(address(looper), gateway), type(uint128).max, "!iusd allowance");
    }

    function test_initiateCooldown_instant(
        uint256 _amount
    ) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);
        uint256 _loose = _stageLooseCollateral(_amount);

        uint256 _expected = _collateralValue(_loose);
        uint256 _idleBefore = strategy.balanceOfAsset();

        // InfiniFi has liquidity, so it all redeems instantly
        vm.prank(emergencyAdmin);
        (uint256 _assetsOut, uint256 _pendingAssets) = looper.initiateCooldown(type(uint256).max, 0);

        // At least the oracle value, as unstaking accrues siUSD's vested yield first
        assertGe(_assetsOut, _expected, "!assetsOut low");
        assertApproxEqRel(_assetsOut, _expected, 1e14, "!assetsOut high");
        assertEq(_pendingAssets, 0, "!pendingAssets");
        assertEq(looper.queuedReceipts(), 0, "!queued");
        assertEq(strategy.balanceOfCollateralToken(), 0, "!loose");
        assertEq(strategy.balanceOfAsset(), _idleBefore + _assetsOut, "!idle");
    }

    function test_initiateCooldown_queued_blocksReportUntilClaimed(
        uint256 _amount
    ) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);

        // Lever up and earn
        mintAndDepositIntoStrategy(strategy, user, _amount);
        vm.prank(keeper);
        strategy.tend();
        accrueYield(_amount);

        // Shut down and close the Trove, which leaves the equity as loose siUSD
        skip(REPAY_COOLDOWN + 1);
        vm.startPrank(emergencyAdmin);
        strategy.shutdownStrategy();
        strategy.emergencyWithdraw(type(uint256).max);
        vm.stopPrank();
        assertGt(strategy.balanceOfCollateralToken(), 0, "!loose");

        // InfiniFi can't redeem instantly, so the cooldown queues it all
        ILiveRedeemController _controller = _prepareLiveRedeemController();
        uint256 _totalAssetsBefore = strategy.estimatedTotalAssets();

        vm.prank(emergencyAdmin);
        (uint256 _assetsOut, uint256 _pendingAssets) = looper.initiateCooldown(type(uint256).max, 0);

        assertEq(_assetsOut, 0, "!assetsOut");
        assertGt(_pendingAssets, 0, "!pendingAssets");
        assertGt(looper.queuedReceipts(), 0, "!queued");
        assertEq(looper.pendingRedemptions(), _pendingAssets, "!pending");
        assertEq(strategy.balanceOfCollateralToken(), 0, "!loose");
        assertApproxEqAbs(strategy.estimatedTotalAssets(), _totalAssetsBefore, 10, "!totalAssets");

        // Reports are blocked while redemptions are pending
        vm.prank(keeper);
        vm.expectRevert("!cooldown");
        strategy.report();

        // Unless management ignores them
        vm.prank(management);
        looper.setIgnorePending(true);
        vm.prank(keeper);
        strategy.report();
        vm.prank(management);
        looper.setIgnorePending(false);

        // InfiniFi funds the queue and we claim it
        _fundQueue(_controller, _pendingAssets);
        uint256 _idleBefore = strategy.balanceOfAsset();

        vm.prank(keeper);
        uint256 _claimed = looper.claimCooldown();

        assertApproxEqAbs(_claimed, _pendingAssets, 1, "!claimed");
        assertEq(strategy.balanceOfAsset(), _idleBefore + _claimed, "!idle");
        assertLe(looper.pendingRedemptions(), 1_000, "!pending cleared");

        // Reports go through again
        vm.prank(keeper);
        strategy.report();

        // Users exit with everything idle
        vm.startPrank(user);
        strategy.redeem(strategy.balanceOf(user), user, user);
        vm.stopPrank();
        assertGe(asset.balanceOf(user), _amount, "!user recovered");
    }

    function test_redeemQueued_onlyIdle(
        uint256 _amount,
        uint256 _keep
    ) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);
        _keep = bound(_keep, 0, _amount);
        uint256 _loose = _stageLooseCollateral(_amount);

        // Someone else is queued at InfiniFi, so every new redemption would queue too
        _enqueueOutsider();

        // Withdrawals are limited to idle
        assertEq(strategy.availableWithdrawLimit(user), strategy.balanceOfAsset(), "!withdraw limit");

        // Converting reverts rather than queueing
        vm.prank(emergencyAdmin);
        vm.expectRevert();
        strategy.convertCollateralToAsset(_loose);

        // Lever-ups borrow only the Lender's idle, without redeeming
        _drainLenderIdle(_keep);
        uint256 _nonceBefore = IDutchDesk(strategy.DUTCH_DESK()).nonce();
        uint256 _debtBefore = strategy.balanceOfDebt();

        mintAndDepositIntoStrategy(strategy, user, _amount);
        vm.prank(keeper);
        strategy.tend();

        assertEq(IDutchDesk(strategy.DUTCH_DESK()).nonce(), _nonceBefore, "!nonce");
        assertLe(strategy.balanceOfDebt() - _debtBefore, _keep + _keep / 100, "!debt");
    }

    function test_iusdDepeg_withdrawReverts(
        uint256 _amount
    ) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);

        mintAndDepositIntoStrategy(strategy, user, _amount);
        vm.prank(keeper);
        strategy.tend();
        skip(REPAY_COOLDOWN + 1);

        // InfiniFi marks iUSD down, but our oracle keeps it at 1 until Daddy approves the new price
        vm.mockCall(
            _redeemController().accounting(), abi.encodeWithSignature("price(address)", IUSD), abi.encode(0.99e18)
        );

        // Redeeming siUSD now loses 1%, so delevering reverts instead of taking the loss
        uint256 _shares = strategy.balanceOf(user);
        vm.prank(user);
        vm.expectRevert("!slippage");
        strategy.redeem(_shares, user, user);
    }

    function test_accessControl_infinifi() public {
        vm.prank(user);
        vm.expectRevert("!emergency authorized");
        looper.initiateCooldown(1, 0);

        vm.prank(user);
        vm.expectRevert("!keeper");
        looper.claimCooldown();

        vm.prank(user);
        vm.expectRevert("!management");
        looper.setIgnorePending(true);
    }

    function test_initiateCooldown_revertsWithoutShares() public {
        vm.prank(emergencyAdmin);
        vm.expectRevert("!shares");
        looper.initiateCooldown(type(uint256).max, 0);
    }

    function test_claimCooldown_revertsWithoutClaim() public {
        vm.prank(keeper);
        vm.expectRevert("!claim");
        looper.claimCooldown();
    }

    // ===============================================================
    // Helpers
    // ===============================================================

    /// @dev Lever up a deposit, then pull some collateral loose
    function _stageLooseCollateral(
        uint256 _amount
    ) internal returns (uint256 _loose) {
        mintAndDepositIntoStrategy(strategy, user, _amount);
        vm.prank(keeper);
        strategy.tend();
        skip(REPAY_COOLDOWN + 1);

        uint256 _withdraw = strategy.balanceOfCollateral() / 20;
        vm.prank(emergencyAdmin);
        strategy.manualWithdrawCollateral(_withdraw);

        _loose = strategy.balanceOfCollateralToken();
        assertGt(_loose, 0, "!loose");
    }

    /// @dev Queue an outsider's redemption at InfiniFi
    function _enqueueOutsider() internal {
        address _outsider = address(0xA11CE);
        uint256 _amount = 1_000e6;
        airdrop(asset, _outsider, _amount);

        // Mint before draining InfiniFi's liquidity, the mint may route liquidity back to the controller
        vm.startPrank(_outsider);
        asset.forceApprove(gateway, _amount);
        uint256 _receipts = IGatewayMint(gateway).mint(_outsider, _amount);
        vm.stopPrank();

        ILiveRedeemController _controller = _prepareLiveRedeemController();

        vm.startPrank(_outsider);
        ERC20(IUSD).forceApprove(gateway, _receipts);
        IInfiniFiGatewayV1(gateway).redeem(_outsider, _receipts, 0);
        vm.stopPrank();

        assertGt(_controller.queueLength(), 0, "!queued");
    }

    /// @dev Empty InfiniFi's queue, then remove the hook and liquidity so new redemptions queue
    function _prepareLiveRedeemController() internal returns (ILiveRedeemController _controller) {
        _controller = _redeemController();

        uint256 _queued = _controller.totalEnqueuedRedemptions();
        if (_queued > 0) _fundQueue(_controller, _controller.receiptToAsset(_queued));

        if (_controller.beforeRedeemHook() != address(0)) {
            vm.prank(_infinifiRole(_controller, "GOVERNOR"));
            _controller.setBeforeRedeemHook(address(0));
        }

        uint256 _liquidity = _controller.liquidity();
        if (_liquidity > 0) {
            vm.prank(_infinifiRole(_controller, "FARM_MANAGER"));
            _controller.withdraw(_liquidity, address(this));
        }

        assertEq(_controller.queueLength(), 0, "!queue");
        assertEq(_controller.liquidity(), 0, "!liquidity");
    }

    /// @dev Fund InfiniFi's queue with `_assets`
    function _fundQueue(
        ILiveRedeemController _controller,
        uint256 _assets
    ) internal {
        airdrop(asset, address(_controller), _assets);
        vm.prank(_infinifiRole(_controller, "FARM_MANAGER"));
        _controller.deposit();
    }

    function _collateralValue(
        uint256 _shares
    ) internal view returns (uint256) {
        return _shares * ITroveManager(troveManager).price_oracle().get_price() / 1e36;
    }

}
