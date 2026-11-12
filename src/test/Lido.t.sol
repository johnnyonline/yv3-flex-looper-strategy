// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import {stdStorage, StdStorage} from "forge-std/Test.sol";

import {LidoSetup} from "./utils/LidoSetup.sol";
import {BaseOperationTest} from "./base/Operation.t.sol";
import {BaseShutdownTest} from "./base/Shutdown.t.sol";
import {BaseLeverScenariosTest} from "./base/LeverScenarios.t.sol";
import {FunctionSignatureTest} from "./FunctionSignature.t.sol";
import {ILidoQueue, IStETH} from "./interfaces/ILido.sol";

import {LidoFlexLooperStrategy} from "../integrations/LidoStrategy.sol";
import {StrategyAprOracle} from "../periphery/StrategyAprOracle.sol";
import {ICentralAprOracle} from "../interfaces/ICentralAprOracle.sol";
import {IDutchDesk} from "../interfaces/IDutchDesk.sol";
import {ITroveManager} from "../interfaces/ITroveManager.sol";
import {ICurveFi, IwstETH} from "../interfaces/IStethInterfaces.sol";

/// @notice wstETH/WETH specific tests: conversions through the live venue, borrowing only the lender's idle,
///         and the cooldown through Lido's withdrawal queue
contract LidoTest is LidoSetup {

    using stdStorage for StdStorage;

    ICurveFi public constant CURVE_POOL = ICurveFi(0xDC24316b9AE028F1497c275EB9192a3Ea0f67022);
    ICentralAprOracle public constant CENTRAL_APR_ORACLE =
        ICentralAprOracle(0x1981AD9F44F2EA9aDd2dC4AD7D075c102C70aF92);

    LidoFlexLooperStrategy public looper;

    function setUp() public virtual override {
        super.setUp();
        looper = LidoFlexLooperStrategy(payable(address(strategy)));
    }

    function test_setupStrategyOK_lido() public view {
        assertEq(strategy.collateralToken(), WSTETH, "!collateral");
        assertEq(strategy.TROVE_MANAGER(), troveManager, "!troveManager");
        assertEq(strategy.exchange(), WETH_WSTETH_EXCHANGE, "!exchange");
        assertFalse(strategy.ALLOW_REDEMPTION(), "!allowRedemption");
        assertEq(strategy.slippage(), 10, "!slippage");
        assertGt(asset.allowance(address(strategy), WETH_WSTETH_EXCHANGE), type(uint128).max, "!asset allowance");
        assertGt(
            collateral.allowance(address(strategy), WETH_WSTETH_EXCHANGE), type(uint128).max, "!collateral allowance"
        );
        assertEq(
            looper.STETH().allowance(address(looper), address(looper.WITHDRAWAL_QUEUE())),
            type(uint256).max,
            "!queue allowance"
        );
        assertEq(looper.pendingRedemptions(), 0, "!pending");
        assertFalse(looper.ignorePending(), "!ignorePending");
    }

    function test_convertAssetToCollateral(
        uint256 _amount
    ) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);
        airdrop(asset, address(strategy), _amount);

        uint256 _idleBefore = strategy.balanceOfAsset() - _amount;
        uint256 _looseBefore = strategy.balanceOfCollateralToken();

        vm.prank(emergencyAdmin);
        strategy.convertAssetToCollateral(_amount);

        // Lido mints at the oracle rate, and Curve is only used when it gives more
        uint256 _received = strategy.balanceOfCollateralToken() - _looseBefore;
        assertGe(_collateralValue(_received) + 1e4, _amount, "!value");
        assertLe(_collateralValue(_received), _amount * 1001 / 1000, "!value high");
        assertEq(strategy.balanceOfAsset(), _idleBefore, "!idle");
    }

    function test_convertCollateralToAsset(
        uint256 _amount
    ) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);
        uint256 _shares = _amount * 1e36 / _price();
        airdrop(collateral, address(strategy), _shares);

        uint256 _expected = _collateralValue(_shares);
        uint256 _quote = CURVE_POOL.get_dy(1, 0, IwstETH(WSTETH).getStETHByWstETH(_shares));
        uint256 _idleBefore = strategy.balanceOfAsset();
        uint256 _lossBefore = strategy.slippagePeriodLoss();

        vm.prank(emergencyAdmin);
        strategy.convertCollateralToAsset(_shares);

        // Out through Curve, within slippage of the oracle value, and the shortfall is recorded as loss
        uint256 _received = strategy.balanceOfAsset() - _idleBefore;
        assertEq(_received, _quote, "!curve");
        assertGe(_received, _expected * (MAX_BPS - strategy.slippage()) / MAX_BPS, "!slippage");
        assertEq(strategy.slippagePeriodLoss() - _lossBefore, _expected - _received, "!loss");
        assertEq(strategy.balanceOfCollateralToken(), 0, "!loose");
    }

    function test_convertCollateralToAsset_revertsOverSlippage() public {
        airdrop(collateral, address(strategy), 100e18);

        // Curve costs more than 1 bps
        vm.prank(management);
        strategy.setSlippage(1);

        vm.expectRevert("!slippage");
        vm.prank(emergencyAdmin);
        strategy.convertCollateralToAsset(100e18);
    }

    function test_lever_cappedByLenderIdle(
        uint256 _amount
    ) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);
        mintAndDepositIntoStrategy(strategy, user, _amount);

        // Leave the lender with less idle than the lever-up wants
        uint256 _idle = _amount / 2;
        _drainLenderIdle(_idle);

        uint256 _debtBefore = strategy.balanceOfDebt();
        uint256 _nonceBefore = IDutchDesk(strategy.DUTCH_DESK()).nonce();

        vm.prank(keeper);
        strategy.tend();

        // Borrowed all of the idle, without redeeming any Trove
        assertEq(asset.balanceOf(lender), 0, "!lender idle");
        assertGe(strategy.balanceOfDebt() - _debtBefore, _idle, "!borrowed");
        assertEq(IDutchDesk(strategy.DUTCH_DESK()).nonce(), _nonceBefore, "!redeemed");
        assertLt(
            strategy.getCurrentLeverageRatio(),
            strategy.targetLeverageRatio() - strategy.leverageBuffer(),
            "!under target"
        );
    }

    function test_operation_lido(
        uint256 _amount
    ) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);
        mintAndDepositIntoStrategy(strategy, user, _amount);

        uint256 _upfrontFee = _tendAndGetUpfrontFee();
        _assertAtTargetLeverage();

        vm.startPrank(management);
        strategy.setLossLimitRatio(100);
        vm.stopPrank();

        vm.prank(keeper);
        strategy.report();

        skip(REPAY_COOLDOWN + 1);

        uint256 _balanceBefore = asset.balanceOf(user);
        uint256 _shares = strategy.balanceOf(user);
        vm.prank(user);
        strategy.redeem(_shares, user, user);

        // Lost at most the upfront fee, plus Curve on the way out
        assertGe(asset.balanceOf(user) - _balanceBefore + _upfrontFee + _maxSwapLoss(_amount), _amount, "!loss");
    }

    function test_emergencyWithdraw_lido(
        uint256 _amount
    ) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);
        mintAndDepositIntoStrategy(strategy, user, _amount);

        uint256 _upfrontFee = _tendAndGetUpfrontFee();

        // Shut down and close the Trove, which leaves the equity as loose wstETH
        skip(REPAY_COOLDOWN + 1);
        vm.startPrank(emergencyAdmin);
        strategy.shutdownStrategy();
        strategy.emergencyWithdraw(type(uint256).max);
        vm.stopPrank();
        assertEq(strategy.balanceOfDebt(), 0, "!debt");
        assertGt(strategy.balanceOfCollateralToken(), 0, "!loose");

        // Sell it through Curve
        vm.prank(emergencyAdmin);
        strategy.convertCollateralToAsset(type(uint256).max);
        assertEq(strategy.balanceOfCollateralToken(), 0, "!converted");

        vm.startPrank(management);
        strategy.setLossLimitRatio(100);
        strategy.report();
        vm.stopPrank();

        uint256 _balanceBefore = asset.balanceOf(user);
        uint256 _shares = strategy.balanceOf(user);
        vm.prank(user);
        strategy.redeem(_shares, user, user);

        // Lost at most the upfront fee, plus Curve on the way out
        assertGe(asset.balanceOf(user) - _balanceBefore + _upfrontFee + _maxSwapLoss(_amount), _amount, "!loss");
    }

    function test_aprOracle_lido() public {
        StrategyAprOracle _oracle = new StrategyAprOracle();

        // At the seed Trove's high rate the loop carries negative, so the APR floors at 0
        assertEq(_oracle.aprAfterDebtChange(address(strategy), 0), 0, "!negative carry");

        // Drop the Trove rate to the minimum so the loop earns a positive spread
        uint256 _minRate = ITroveManager(troveManager).min_annual_interest_rate();
        vm.prank(emergencyAdmin);
        strategy.adjustInterestRate(_minRate, 0, 0, type(uint256).max);

        // Levered wstETH yield minus the borrow cost on the borrowed share
        uint256 _wstethApr = CENTRAL_APR_ORACLE.getStrategyApr(WSTETH, 0);
        uint256 _leverage = strategy.targetLeverageRatio();
        assertGt(_wstethApr, 0, "!wstETH apr");
        assertEq(
            _oracle.aprAfterDebtChange(address(strategy), 0),
            _leverage * _wstethApr / 1e18 - (_leverage - 1e18) * _minRate / 1e18,
            "!apr"
        );
    }

    function test_unwind_redeemsEquityThroughLido(
        uint256 _amount
    ) public {
        _amount = bound(_amount, minFuzzAmount, 900e18); // under Lido's 1000 stETH per-request cap
        mintAndDepositIntoStrategy(strategy, user, _amount);
        uint256 _upfrontFee = _tendAndGetUpfrontFee();

        vm.prank(management);
        strategy.setLossLimitRatio(100);

        // Close the Trove. Only the debt is sold, the equity is left as loose wstETH
        skip(REPAY_COOLDOWN + 1);
        uint256 _debt = strategy.balanceOfDebt();
        vm.prank(emergencyAdmin);
        strategy.manualFullUnwind();
        uint256 _loose = strategy.balanceOfCollateralToken();
        assertGt(_loose, 0, "!loose");

        // Queue it all with Lido. Its value only moves from loose to pending
        uint256 _totalAssetsBefore = strategy.estimatedTotalAssets();
        vm.prank(emergencyAdmin);
        uint256 _requestId = looper.initiateCooldown(type(uint256).max);
        uint256 _pending = looper.pendingRedemptions();
        assertEq(_pending, IwstETH(WSTETH).getStETHByWstETH(_loose), "!pending");
        assertEq(strategy.balanceOfCollateralToken(), 0, "!queued");
        assertApproxEqAbs(strategy.estimatedTotalAssets(), _totalAssetsBefore, 1e4, "!totalAssets");

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

        // Lido finalizes, and we claim 1:1
        _finalizeLidoRequest(_requestId);
        uint256 _idleBefore = strategy.balanceOfAsset();
        uint256 _claimed = _claimCooldown(_requestId);
        assertApproxEqAbs(_claimed, _pending, 2, "!claimed");
        assertEq(strategy.balanceOfAsset(), _idleBefore + _claimed, "!idle");
        assertEq(looper.pendingRedemptions(), 0, "!pending cleared");

        // Reports go through again
        vm.prank(keeper);
        strategy.report();

        // Users exit with everything idle. Only the debt went through Curve
        uint256 _shares = strategy.balanceOf(user);
        vm.prank(user);
        strategy.redeem(_shares, user, user);
        assertGe(asset.balanceOf(user) + _upfrontFee + _debt * strategy.slippage() / MAX_BPS, _amount, "!loss");
    }

    function test_initiateCooldown_twoRequests(
        uint256 _amount
    ) public {
        _amount = bound(_amount, minFuzzAmount, 900e18); // under Lido's 1000 stETH per-request cap
        uint256 _loose = _unwindToLoose(_amount);

        // Queue it in two requests
        vm.startPrank(emergencyAdmin);
        uint256 _firstId = looper.initiateCooldown(_loose / 2);
        uint256 _firstPending = looper.pendingRedemptions();
        uint256 _secondId = looper.initiateCooldown(type(uint256).max);
        vm.stopPrank();
        assertGt(_secondId, _firstId, "!ids");
        assertEq(strategy.balanceOfCollateralToken(), 0, "!queued");

        // Claiming the first still blocks reports
        _finalizeLidoRequest(_secondId);
        uint256 _secondPending = looper.pendingRedemptions() - _firstPending;
        _claimCooldown(_firstId);
        assertEq(looper.pendingRedemptions(), _secondPending, "!first");
        vm.prank(keeper);
        vm.expectRevert("!cooldown");
        strategy.report();

        // Claiming both unblocks them
        _claimCooldown(_secondId);
        assertEq(looper.pendingRedemptions(), 0, "!pending");
        vm.prank(management);
        strategy.setLossLimitRatio(100);
        vm.prank(keeper);
        strategy.report();
    }

    function test_claimCooldown_multipleRequests(
        uint256 _amount
    ) public {
        _amount = bound(_amount, minFuzzAmount, 900e18); // under Lido's 1000 stETH per-request cap
        uint256 _loose = _unwindToLoose(_amount);

        // Queue it in two requests, and Lido finalizes both
        uint256[] memory _requestIds = new uint256[](2);
        vm.startPrank(emergencyAdmin);
        _requestIds[0] = looper.initiateCooldown(_loose / 2);
        _requestIds[1] = looper.initiateCooldown(type(uint256).max);
        vm.stopPrank();
        uint256 _pending = looper.pendingRedemptions();
        _finalizeLidoRequest(_requestIds[1]);

        // Claim both at once, 1:1
        uint256 _idleBefore = strategy.balanceOfAsset();
        uint256 _claimed = _claimCooldown(_requestIds);
        assertApproxEqAbs(_claimed, _pending, 4, "!claimed");
        assertEq(strategy.balanceOfAsset(), _idleBefore + _claimed, "!idle");
        assertEq(looper.pendingRedemptions(), 0, "!pending");

        // Reports go through again
        vm.prank(management);
        strategy.setLossLimitRatio(100);
        vm.prank(keeper);
        strategy.report();
    }

    function test_zeroPendingRedemptions_clearsStuckPending(
        uint256 _amount
    ) public {
        _amount = bound(_amount, minFuzzAmount, 900e18); // under Lido's 1000 stETH per-request cap
        _unwindToLoose(_amount);

        // A request Lido hasn't finalized blocks reports
        vm.prank(emergencyAdmin);
        uint256 _requestId = looper.initiateCooldown(type(uint256).max);
        uint256 _pending = looper.pendingRedemptions();
        vm.prank(keeper);
        vm.expectRevert("!cooldown");
        strategy.report();

        // Management zeroes it, and reports go through, taking it as a loss
        uint256 _totalAssetsBefore = strategy.estimatedTotalAssets();
        vm.prank(management);
        looper.zeroPendingRedemptions();
        assertEq(looper.pendingRedemptions(), 0, "!pending");
        assertEq(strategy.estimatedTotalAssets(), _totalAssetsBefore - _pending, "!totalAssets");
        vm.prank(management);
        strategy.setDoHealthCheck(false);
        vm.prank(keeper);
        (, uint256 _loss) = strategy.report();
        assertGe(_loss, _pending, "!loss");

        // If the request is claimed after all, it comes back as profit
        _finalizeLidoRequest(_requestId);
        uint256 _claimed = _claimCooldown(_requestId);
        assertEq(looper.pendingRedemptions(), 0, "!still zero");
        vm.prank(management);
        strategy.setDoHealthCheck(false);
        vm.prank(keeper);
        (uint256 _profit,) = strategy.report();
        assertEq(_profit, _claimed, "!profit");
    }

    function test_report_ignoresPendingDust() public {
        // Up to 0.001 WETH queued doesn't block reports
        stdstore.target(address(looper)).sig("queuedSteth()").checked_write(1e15);
        vm.prank(keeper);
        strategy.report();

        // Anything above it does
        stdstore.target(address(looper)).sig("queuedSteth()").checked_write(1e15 + 1);
        vm.prank(keeper);
        vm.expectRevert("!cooldown");
        strategy.report();
    }

    function test_unsolicitedRequest_notPending(
        uint256 _amount
    ) public {
        _amount = bound(_amount, minFuzzAmount, 500e18); // under Lido's 1000 stETH per-request cap

        // An outsider queues a withdrawal request owned by the strategy
        address _outsider = address(0xA11CE);
        airdrop(collateral, _outsider, _amount);
        vm.startPrank(_outsider);
        uint256[] memory _amounts = new uint256[](1);
        _amounts[0] = IwstETH(WSTETH).unwrap(_amount);
        looper.STETH().approve(address(looper.WITHDRAWAL_QUEUE()), _amounts[0]);
        looper.WITHDRAWAL_QUEUE().requestWithdrawals(_amounts, address(strategy));
        vm.stopPrank();

        // It isn't pending and doesn't block reports
        assertEq(looper.pendingRedemptions(), 0, "!pending");
        vm.prank(keeper);
        strategy.report();
    }

    function test_accessControl_lido() public {
        vm.prank(user);
        vm.expectRevert("!emergency authorized");
        looper.initiateCooldown(1);

        vm.prank(user);
        vm.expectRevert("!emergency authorized");
        looper.claimCooldown(new uint256[](0), new uint256[](0));

        vm.prank(user);
        vm.expectRevert("!management");
        looper.setIgnorePending(true);

        // sam can't zero the queued stETH, only management
        vm.prank(emergencyAdmin);
        vm.expectRevert("!management");
        looper.zeroPendingRedemptions();
    }

    function test_initiateCooldown_revertsWithoutShares() public {
        vm.prank(emergencyAdmin);
        vm.expectRevert("!shares");
        looper.initiateCooldown(type(uint256).max);
    }

    function test_claimCooldown_revertsForUnknownRequest(
        uint256 _requestId
    ) public {
        uint256[] memory _requestIds = new uint256[](1);
        _requestIds[0] = _requestId;
        vm.prank(emergencyAdmin);
        vm.expectRevert();
        looper.claimCooldown(_requestIds, new uint256[](1));
    }

    /// @dev Tend, returning the upfront fee Flex added to the debt on top of what we borrowed
    function _tendAndGetUpfrontFee() internal returns (uint256) {
        uint256 _debtBefore = strategy.balanceOfDebt();
        uint256 _lenderIdleBefore = asset.balanceOf(lender);

        vm.prank(keeper);
        strategy.tend();

        return strategy.balanceOfDebt() - _debtBefore - (_lenderIdleBefore - asset.balanceOf(lender));
    }

    /// @dev Swaps are capped at `slippage` of the levered position
    function _maxSwapLoss(
        uint256 _amount
    ) internal view returns (uint256) {
        return _amount * strategy.targetLeverageRatio() / 1e18 * strategy.slippage() / MAX_BPS;
    }

    /// @dev Lever up a deposit, then close the Trove, which leaves the equity as loose wstETH
    function _unwindToLoose(
        uint256 _amount
    ) internal returns (uint256 _loose) {
        mintAndDepositIntoStrategy(strategy, user, _amount);
        vm.prank(keeper);
        strategy.tend();
        skip(REPAY_COOLDOWN + 1);

        vm.prank(emergencyAdmin);
        strategy.manualFullUnwind();

        _loose = strategy.balanceOfCollateralToken();
        assertGt(_loose, 0, "!loose");
    }

    /// @dev Claim a request as sam, with the checkpoint hint an off-chain caller would find
    function _claimCooldown(
        uint256 _requestId
    ) internal returns (uint256) {
        uint256[] memory _requestIds = new uint256[](1);
        _requestIds[0] = _requestId;
        return _claimCooldown(_requestIds);
    }

    /// @dev Claim requests as sam, with the checkpoint hints an off-chain caller would find
    function _claimCooldown(
        uint256[] memory _requestIds
    ) internal returns (uint256) {
        ILidoQueue _queue = ILidoQueue(address(looper.WITHDRAWAL_QUEUE()));
        uint256[] memory _hints = _queue.findCheckpointHints(_requestIds, 1, _queue.getLastCheckpointIndex());
        vm.prank(emergencyAdmin);
        return looper.claimCooldown(_requestIds, _hints);
    }

    /// @dev Finalize Lido withdrawal requests up to `_requestId` by pranking the stETH contract
    function _finalizeLidoRequest(
        uint256 _requestId
    ) internal {
        ILidoQueue _queue = ILidoQueue(address(looper.WITHDRAWAL_QUEUE()));
        address _steth = address(looper.STETH());
        uint256 _maxShareRate = IStETH(_steth).getPooledEthByShares(1e27);

        // Compute the ETH needed to finalize everything up to our request
        uint256[] memory _batches = new uint256[](1);
        _batches[0] = _requestId;
        (uint256 _ethToLock,) = _queue.prefinalize(_batches, _maxShareRate);

        // Finalize as Lido
        vm.deal(_steth, _steth.balance + _ethToLock);
        vm.prank(_steth);
        _queue.finalize{value: _ethToLock}(_requestId, _maxShareRate);
    }

    function _collateralValue(
        uint256 _shares
    ) internal view returns (uint256) {
        return _shares * _price() / 1e36;
    }

    function _price() internal view returns (uint256) {
        return ITroveManager(troveManager).price_oracle().get_price();
    }

}

/// @notice Runs the shared suites against the wstETH/WETH looper
contract LidoBaseOperationTest is BaseOperationTest, LidoSetup {

    function setUp() public override(BaseOperationTest, LidoSetup) {
        LidoSetup.setUp();
    }

}

contract LidoBaseShutdownTest is BaseShutdownTest, LidoSetup {

    function setUp() public override(BaseShutdownTest, LidoSetup) {
        LidoSetup.setUp();
    }

}

contract LidoBaseLeverScenariosTest is BaseLeverScenariosTest, LidoSetup {

    function setUp() public override(BaseLeverScenariosTest, LidoSetup) {
        LidoSetup.setUp();
    }

}

contract LidoFunctionSignatureTest is FunctionSignatureTest, LidoSetup {

    function setUp() public override(FunctionSignatureTest, LidoSetup) {
        LidoSetup.setUp();
    }

}
