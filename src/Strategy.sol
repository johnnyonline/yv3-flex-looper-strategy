// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.23;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ITroveManager} from "./interfaces/ITroveManager.sol";
import {IPriceOracle} from "./interfaces/IPriceOracle.sol";
import {IMorpho} from "./interfaces/IMorpho.sol";
import {IDutchDesk} from "./interfaces/IDutchDesk.sol";
import {IAuction} from "./interfaces/IAuction.sol";
import {IDebtInFrontHelper} from "./interfaces/IDebtInFrontHelper.sol";

import {BaseLooper} from "./BaseLooper.sol";

contract Strategy is BaseLooper {

    using SafeERC20 for ERC20;

    // ===============================================================
    // Storage
    // ===============================================================

    /// @notice Trove ID
    uint256 public troveId;

    /// @notice Sorted-troves insertion hints for the debt-in-front lookup in `_maxBorrowAmount()`
    uint256 public debtInFrontHintPrev;
    uint256 public debtInFrontHintNext;

    /// @notice Morpho callback reentrancy guard
    bool internal _isFlashloanActive;

    /// @notice True while we are taking a redemption auction
    bool internal _isTakingAuction;

    // ===============================================================
    // Constants
    // ===============================================================

    /// @notice The market's minimum debt
    uint256 public immutable MIN_DEBT;

    /// @notice The market's minimum collateral ratio
    uint256 public immutable MCR;

    /// @notice Dust added to a redemption borrow to absorb the redeemed-collateral round-trip rounding
    uint256 internal constant _REDEMPTION_DUST = 1e4;

    /// @notice Trove status values
    uint256 internal constant _STATUS_ACTIVE = 1;
    uint256 internal constant _STATUS_ZOMBIE = 2;

    /// @notice Whether borrows may redeem lower-rate Troves for liquidity beyond the
    ///         Lender's idle balance. Enable only for markets where the collateral is a
    ///         vault of the borrow token and the redeemed-collateral to asset swap is lossless.
    ///         Otherwise, keep it disabled and pre-fund the lender with idle liquidity
    bool public immutable ALLOW_REDEMPTION;

    /// @notice The Flex Lender contract
    address public immutable LENDER;

    /// @notice The Flex Trove Manager contract
    ITroveManager public immutable TROVE_MANAGER;

    /// @notice The Flex Dutch Desk contract
    IDutchDesk public immutable DUTCH_DESK;

    /// @notice The Flex Auction contract
    IAuction public immutable AUCTION;

    /// @notice The Flex collateral price oracle contract. 1e36-format, collateral priced in borrow token
    IPriceOracle public immutable ORACLE;

    /// @notice The Flex Debt-In-Front Helper contract
    IDebtInFrontHelper public constant DEBT_IN_FRONT_HELPER =
        IDebtInFrontHelper(0xA4119B541a2ebf411F3ED6201107fc1DA016EbD6);

    /// @notice The flash-loan provider
    IMorpho public constant MORPHO = IMorpho(0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb);

    // ===============================================================
    // Constructor
    // ===============================================================

    /// @param _asset The borrow token
    /// @param _collateraltoken The collateral token
    /// @param _name Strategy name
    /// @param _troveManager The Flex Trove Manager contract
    /// @param _exchange The exchange address for collateral <--> asset swaps
    /// @param _allowRedemption Whether borrows may trigger a collateral redemption
    /// @param _governance The address allowed to update exchange configuration
    constructor(
        address _asset,
        address _collateraltoken,
        string memory _name,
        address _troveManager,
        address _exchange,
        bool _allowRedemption,
        address _governance
    ) BaseLooper(_asset, _name, _collateraltoken, _governance, _exchange) {
        TROVE_MANAGER = ITroveManager(_troveManager);
        require(_asset == TROVE_MANAGER.borrow_token(), "!borrow");
        require(_collateraltoken == TROVE_MANAGER.collateral_token(), "!collateral");

        ALLOW_REDEMPTION = _allowRedemption;

        // Set Flex contract addresses from the Trove Manager
        LENDER = TROVE_MANAGER.lender();
        DUTCH_DESK = TROVE_MANAGER.dutch_desk();
        AUCTION = DUTCH_DESK.auction();
        ORACLE = TROVE_MANAGER.price_oracle();

        // Make sure the auction's starting price buffer is 0% if we allow redemptions
        if (ALLOW_REDEMPTION) require(DUTCH_DESK.starting_price_buffer_percentage() == WAD, "!buffer");

        // Set market parameters from the Trove Manager
        // Flex scales `minimum_collateral_ratio` by borrow-token precision, convert it to WAD
        MIN_DEBT = TROVE_MANAGER.min_debt();
        MCR = TROVE_MANAGER.minimum_collateral_ratio() * WAD / 10 ** IERC20Metadata(_asset).decimals();

        // Max approve Trove Manager to pull collateral (supply) and borrow token (repay/close)
        ERC20(_collateraltoken).forceApprove(_troveManager, type(uint256).max);
        ERC20(_asset).forceApprove(_troveManager, type(uint256).max);

        // Max approve Morpho to pull the flashloan repayment
        ERC20(_asset).forceApprove(address(MORPHO), type(uint256).max);
    }

    // ===============================================================
    // Trove operations
    // ===============================================================

    /// @inheritdoc BaseLooper
    function _supplyCollateral(
        uint256 _amount
    ) internal override {
        if (_amount == 0) return;
        TROVE_MANAGER.add_collateral(troveId, _amount);
    }

    /// @inheritdoc BaseLooper
    function _withdrawCollateral(
        uint256 _amount
    ) internal override {
        if (_amount == 0) return;
        TROVE_MANAGER.remove_collateral(troveId, _amount);
    }

    /// @inheritdoc BaseLooper
    function _borrow(
        uint256 _amount
    ) internal override {
        if (_amount == 0) return;

        // If redemption is disabled, we can only borrow up to the idle liquidity
        if (!ALLOW_REDEMPTION) {
            TROVE_MANAGER.borrow(troveId, _amount, type(uint256).max, _amount, 0);
            return;
        }

        (uint256 _borrowAmount, uint256 _minBorrowOut, uint256 _minCollateralOut) = _borrowMinOuts(_amount);

        uint256 _nonceBefore = DUTCH_DESK.nonce();
        TROVE_MANAGER.borrow(troveId, _borrowAmount, type(uint256).max, _minBorrowOut, _minCollateralOut);
        _takeAuctionIfKicked(_nonceBefore);
    }

    /// @inheritdoc BaseLooper
    function _repay(
        uint256 _amount
    ) internal override {
        if (_amount == 0) return;
        TROVE_MANAGER.repay(troveId, _amount);
    }

    // ===============================================================
    // Flash loan
    // ===============================================================

    /// @notice Morpho flashloan callback
    /// @dev Only callable by Morpho contract during flashLoan execution
    function onMorphoFlashLoan(
        uint256 _assets,
        bytes calldata _data
    ) external {
        require(msg.sender == address(MORPHO), "!morpho");
        require(_isFlashloanActive, "!active");

        // Emergency close passes empty data, lever/delever pass an encoded FlashLoanData struct
        _data.length == 0 ? _handleClose() : _onFlashloanReceived(_assets, _data);
    }

    /// @inheritdoc BaseLooper
    function _executeFlashloan(
        address _token,
        uint256 _amount,
        bytes memory _data
    ) internal override {
        _isFlashloanActive = true;
        MORPHO.flashLoan(_token, _amount, _data);
        _isFlashloanActive = false;
    }

    /// @inheritdoc BaseLooper
    function maxFlashloan() public view override returns (uint256) {
        return asset.balanceOf(address(MORPHO));
    }

    // ===============================================================
    // Protocol Views
    // ===============================================================

    /// @notice For a target borrow, get the amount to borrow and the minimum amounts out to enforce
    /// @dev On a redemption we increase the borrow by a dust amount to ensure we can repay
    ///      the flashloan and not fall short because of floor rounding when taking the auction
    /// @param _amount The amount we ultimately need delivered
    /// @return _borrowAmount The amount to borrow, including dust if it has to redeem
    /// @return _minBorrowOut The minimum borrow token delivered atomically from idle liquidity
    /// @return _minCollateralOut The minimum collateral the redemption must deliver
    function _borrowMinOuts(
        uint256 _amount
    ) internal view returns (uint256 _borrowAmount, uint256 _minBorrowOut, uint256 _minCollateralOut) {
        uint256 _idle = asset.balanceOf(LENDER);
        if (_amount <= _idle) return (_amount, _amount, 0);

        _borrowAmount = _amount + _REDEMPTION_DUST;
        _minBorrowOut = _idle;
        _minCollateralOut = _assetToCollateral(_borrowAmount - _idle) * (MAX_BPS - slippage) / MAX_BPS;
    }

    /// @notice Checks if the Trove is active or not yet opened (troveId == 0)
    /// @dev Returns True when not yet opened to allow for seed deposits
    /// @return True if the Trove is active or not yet opened, false if it is zombie, liquidated, or closed
    function _isTroveActive() internal view returns (bool) {
        uint256 _troveId = troveId;
        return _troveId == 0 || TROVE_MANAGER.troves(_troveId).status == _STATUS_ACTIVE;
    }

    /// @inheritdoc BaseLooper
    function availableWithdrawLimit(
        address _owner
    ) public view override returns (uint256) {
        if (!_isTroveActive() || TROVE_MANAGER.troves(troveId).lastDebtUpdateTime == block.timestamp) {
            return balanceOfAsset();
        }
        return super.availableWithdrawLimit(_owner);
    }

    /// @inheritdoc BaseLooper
    function balanceOfCollateral() public view override returns (uint256) {
        return TROVE_MANAGER.troves(troveId).collateral;
    }

    /// @inheritdoc BaseLooper
    function balanceOfDebt() public view override returns (uint256) {
        return TROVE_MANAGER.get_trove_debt_after_interest(troveId);
    }

    /// @inheritdoc BaseLooper
    function getLiquidateCollateralFactor() public view override returns (uint256) {
        return (WAD * WAD) / MCR;
    }

    /// @inheritdoc BaseLooper
    function _isLiquidatable() internal view override returns (bool) {
        (uint256 _collateralValue, uint256 _debt) = position();
        if (_debt == 0) return false;
        return (_collateralValue * WAD) / _debt < MCR;
    }

    /// @inheritdoc BaseLooper
    function _isSupplyPaused() internal view override returns (bool) {
        return !_isTroveActive();
    }

    /// @inheritdoc BaseLooper
    function _isBorrowPaused() internal view override returns (bool) {
        return !_isTroveActive();
    }

    /// @inheritdoc BaseLooper
    function _maxCollateralDeposit() internal pure override returns (uint256) {
        return type(uint256).max;
    }

    /// @inheritdoc BaseLooper
    function _maxBorrowAmount() internal view override returns (uint256) {
        uint256 _troveId = troveId;
        uint256 _idle = asset.balanceOf(LENDER);

        // If redemption is disabled, we can only borrow up to the idle liquidity
        if (!ALLOW_REDEMPTION) return _idle;

        // Debt of all Troves paying a lower rate than ours (i.e. what we can redeem)
        uint256 _redeemable = DEBT_IN_FRONT_HELPER.get_debt_in_front(
            address(TROVE_MANAGER), // troveManager
            0, // interestRateLow
            TROVE_MANAGER.troves(_troveId).annualInterestRate, // interestRateHigh
            _troveId, // stopAtTroveId
            debtInFrontHintPrev, // hintPrevId
            debtInFrontHintNext // hintNextId
        );

        // We can borrow up to the idle liquidity plus the redeemable debt
        uint256 _max = _idle + _redeemable;

        // Reserve the dust the redemption borrow grosses up by, so it never exceeds what's available
        return _max > _REDEMPTION_DUST ? _max - _REDEMPTION_DUST : 0;
    }

    // ===============================================================
    // Oracle
    // ===============================================================

    /// @inheritdoc BaseLooper
    function _getCollateralPrice() internal view override returns (uint256) {
        return ORACLE.get_price();
    }

    // ===============================================================
    // Rewards
    // ===============================================================

    /// @inheritdoc BaseLooper
    function _claimAndSellRewards() internal pure override {
        return; // no rewards
    }

    // ===============================================================
    // Emergency
    // ===============================================================

    /// @notice Handles the close in an emergency, with or without a preceding flashloan
    function _handleClose() internal {
        uint256 _troveId = troveId;
        uint256 _status = TROVE_MANAGER.troves(_troveId).status;
        if (_status == _STATUS_ACTIVE) TROVE_MANAGER.close_trove(_troveId);
        else if (_status == _STATUS_ZOMBIE) TROVE_MANAGER.close_zombie_trove(_troveId);
        _convertCollateralToAsset(balanceOfCollateralToken());
    }

    /// @inheritdoc BaseLooper
    function _emergencyWithdraw(
        uint256 /*_amount*/
    ) internal override {
        uint256 _status = TROVE_MANAGER.troves(troveId).status;
        // A closeable Trove (ACTIVE or ZOMBIE) with debt must repay it on close, so
        // flashloan the debt and finish in `_handleClose()`. Anything else (zombie with
        // no debt or already liquidated/closed) just needs loose collateral swapped,
        // done directly via `_handleClose()`
        (_status == _STATUS_ACTIVE || _status == _STATUS_ZOMBIE) && balanceOfDebt() > 0
            ? _executeFlashloan(address(asset), balanceOfDebt(), "")
            : _handleClose();
    }

    // ===============================================================
    // Manage Trove
    // ===============================================================

    /// @notice Open the Trove. Must be done by management to initialize the strategy
    /// @dev Swaps idle asset into collateral and opens the Trove at `MIN_DEBT` (plus redemption
    ///      dust if the open has to redeem). If redemption is enabled, takes the kicked auction atomically
    /// @param _annualInterestRate The initial annual interest rate for the Trove
    /// @param _prevId Sorted-troves insertion hint (computed offchain)
    /// @param _nextId Sorted-troves insertion hint (computed offchain)
    /// @param _maxUpfrontFee The maximum upfront fee to pay to open the Trove
    function openTrove(
        uint256 _annualInterestRate,
        uint256 _prevId,
        uint256 _nextId,
        uint256 _maxUpfrontFee
    ) external onlyManagement {
        require(troveId == 0, "trove exists");

        uint256 _debt = MIN_DEBT;
        uint256 _minBorrowOut = MIN_DEBT;
        uint256 _minCollateralOut = 0;
        if (ALLOW_REDEMPTION) (_debt, _minBorrowOut, _minCollateralOut) = _borrowMinOuts(MIN_DEBT);

        uint256 _nonceBefore = DUTCH_DESK.nonce();
        troveId = TROVE_MANAGER.open_trove(
            420, // ownerIndex
            _convertAssetToCollateral(balanceOfAsset()), // collateralAmount
            _debt, // debtAmount
            _prevId, // prevId
            _nextId, // nextId
            _annualInterestRate, // annualInterestRate
            _maxUpfrontFee, // maxUpfrontFee
            _minBorrowOut, // minBorrowOut
            _minCollateralOut, // minCollateralOut
            address(this) // owner
        );
        if (ALLOW_REDEMPTION) _takeAuctionIfKicked(_nonceBefore);
    }

    /// @notice Adjust the Trove's annual interest rate
    /// @param _newAnnualInterestRate The new annual interest rate to set
    /// @param _prevId Sorted-troves insertion hint (computed offchain)
    /// @param _nextId Sorted-troves insertion hint (computed offchain)
    /// @param _maxUpfrontFee The maximum upfront fee to pay for the adjustment
    function adjustInterestRate(
        uint256 _newAnnualInterestRate,
        uint256 _prevId,
        uint256 _nextId,
        uint256 _maxUpfrontFee
    ) external onlyKeepers {
        TROVE_MANAGER.adjust_interest_rate(troveId, _newAnnualInterestRate, _prevId, _nextId, _maxUpfrontFee);
    }

    /// @notice Update the sorted-troves hints used by the debt-in-front lookup in
    ///         `_maxBorrowAmount`, keeping that lookup cheap as the list changes
    /// @dev Stale/bad hints only cost extra gas (the helper falls back to a linear
    ///      search), never correctness, so they're safe to leave to the keeper
    function setDebtInFrontHints(
        uint256 _hintPrev,
        uint256 _hintNext
    ) external onlyKeepers {
        debtInFrontHintPrev = _hintPrev;
        debtInFrontHintNext = _hintNext;
    }

    // ===============================================================
    // Redemption auction taking
    // ===============================================================

    /// @notice Callback function for the auction when taking a redemption
    /// @param _taker The address of the taker
    /// @param _amountTaken The amount of collateral taken by the auction
    /// @param _neededAmount The amount of asset needed to pay the auction
    function takeCallback(
        uint256, /*auctionId*/
        address _taker,
        uint256 _amountTaken,
        uint256 _neededAmount,
        bytes calldata /*data*/
    ) external {
        require(_isTakingAuction && msg.sender == address(AUCTION), "!auction");
        require(_taker == address(this), "!taker");

        _convertCollateralToAsset(_amountTaken);
        asset.forceApprove(address(AUCTION), _neededAmount);
    }

    /// @notice Take the redemption auction if it was kicked by the preceding borrow
    /// @param _nonceBefore The nonce of the Dutch Desk before the borrow.
    ///        If it differs from the current nonce, the auction was kicked and should be taken
    function _takeAuctionIfKicked(
        uint256 _nonceBefore
    ) internal {
        if (DUTCH_DESK.nonce() == _nonceBefore) return;
        _isTakingAuction = true;
        AUCTION.take(_nonceBefore, type(uint256).max, address(this), abi.encode(uint256(420)));
        _isTakingAuction = false;
    }

}
