// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ITroveManager} from "./interfaces/ITroveManager.sol";
import {IPriceOracle} from "./interfaces/IPriceOracle.sol";
import {IMorpho} from "./interfaces/IMorpho.sol";
import {IDutchDesk} from "./interfaces/IDutchDesk.sol";
import {IAuction} from "./interfaces/IAuction.sol";
import {IDebtInFrontHelper} from "./interfaces/IDebtInFrontHelper.sol";

import {BaseLooper} from "./BaseLooper.sol";

//  *
//  *         A borrow draws first from the lender's idle liquidity, then (only when
//  *         `allowRedemption` is set) redeems lower-rate troves for the rest,
//  *         kicking a Dutch auction with this strategy as receiver; we take that
//  *         auction atomically in the same tx, swapping the redeemed collateral
//  *         back to asset through the exchange. So _maxBorrowAmount() = idle when
//  *         redemption is off, idle + debt-in-front when on.
//  *
//  *         Enable `allowRedemption` only for vault-redeem markets (collateral is a
//  *         vault of the borrow token) where that swap is ~lossless; for non-vault
//  *         markets keep it off and pre-fund the lender with idle liquidity, since
//  *         a lossy redeemed-collateral->asset swap would make the lever step revert.
//  */
contract Strategy is BaseLooper {

    using SafeERC20 for ERC20;

    // ===============================================================
    // Storage
    // ===============================================================

    /// @notice Trove ID
    uint256 public troveId;

    /// @notice Whether borrows may redeem Troves or be limited to idle Lender liquidity
    bool public allowRedemption;

    /// @notice Sorted-troves insertion hints for the debt-in-front lookup in `_maxBorrowAmount()`
    uint256 public debtInFrontHintPrev;
    uint256 public debtInFrontHintNext;

    /// @notice Morpho callback reentrancy guard
    bool internal _isFlashloanActive;

    /// @notice True while a `manualClose()` flash loan is in flight
    bool internal _isClosing;

    /// @notice True while we are taking a redemption auction
    bool internal _isTakingAuction;

    // ===============================================================
    // Constants
    // ===============================================================

    /// @notice The market's minimum debt
    uint256 public immutable MIN_DEBT;

    /// @notice The market's minimum collateral ratio (WAD, e.g. 1.1e18)
    uint256 public immutable MCR;

    /// @notice Index used to derive our Trove ID
    uint256 public constant OWNER_INDEX = 0;

    /// @notice Trove status value for an ACTIVE Trove
    uint256 internal constant _STATUS_ACTIVE = 1;

    /// @notice The Flex Lender contract
    address public immutable LENDER;

    /// @notice The Flex Trove Manager contract
    ITroveManager public immutable TROVE_MANAGER;

    /// @notice The Flex Dutch Desk contract
    IDutchDesk public immutable DUTCH_DESK;

    /// @notice The Flex Auction contract
    IAuction public immutable AUCTION;

    /// @notice The Flex Debt-In-Front Helper contract
    IDebtInFrontHelper public immutable DEBT_IN_FRONT_HELPER;

    /// @notice The Flex collateral price oracle contract. 1e36-format, collateral priced in borrow token
    IPriceOracle public immutable ORACLE;

    /// @notice The flash-loan provider
    IMorpho public constant MORPHO = IMorpho(0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb);

    // ===============================================================
    // Constructor
    // ===============================================================

    /// @param _asset The borrow token (e.g. USDC)
    /// @param _name Strategy name for BaseLooper events
    /// @param _troveManager The Flex Trove Manager contract
    /// @param _exchange The exchange address for collateral <--> asset swaps
    /// @param _debtInFrontHelper The Flex Debt-In-Front Helper contract
    /// @param _governance The address with management permissions (e.g. for opening the trove and toggling redemption)
    constructor(
        address _asset,
        address _collateraltoken,
        string memory _name,
        address _troveManager,
        address _exchange,
        address _debtInFrontHelper,
        address _governance
    ) BaseLooper(_asset, _name, _collateraltoken, _governance, _exchange) {
        TROVE_MANAGER = _troveManager;
        require(_asset == TROVE_MANAGER.borrow_token(), "!borrow");
        require(_collateraltoken == TROVE_MANAGER.collateral_token(), "!collateral");

        DEBT_IN_FRONT_HELPER = _debtInFrontHelper;

        // Set Flex contract addresses from the Trove Manager
        LENDER = TROVE_MANAGER.lender();
        DUTCH_DESK = TROVE_MANAGER.dutch_desk();
        AUCTION = IDutchDesk(TROVE_MANAGER.dutch_desk()).auction();
        ORACLE = TROVE_MANAGER.price_oracle();

        // Set market parameters from the Trove Manager
        MIN_DEBT = TROVE_MANAGER.min_debt();
        MCR = TROVE_MANAGER.minimum_collateral_ratio();

        // Max approve Trove Manager to pull collateral (supply) and borrow token (repay/close)
        ERC20(_collateraltoken).forceApprove(_troveManager, type(uint256).max);
        ERC20(_asset).forceApprove(_troveManager, type(uint256).max);

        // Max approve Morpho to pull the flash-loan repayment
        ERC20(_asset).forceApprove(address(MORPHO), type(uint256).max);
    }

    // ===============================================================
    // Trove operations
    // ===============================================================

    /// @inheritdoc BaseLooper
    function _supplyCollateral(uint256 _amount) internal override {
        if (_amount == 0) return;
        TROVE_MANAGER.add_collateral(troveId, _amount);
    }

    /// @inheritdoc BaseLooper
    function _withdrawCollateral(uint256 _amount) internal override {
        if (_amount == 0) return;
        TROVE_MANAGER.remove_collateral(troveId, _amount);
    }

    /// @inheritdoc BaseLooper
    function _borrow(uint256 _amount) internal override {
        if (_amount == 0) return;

        // If redemption is disabled, force full delivery from idle liquidity
        // If enabled, allow the redeem path and take the auction atomically
        if (allowRedemption) {
            uint256 _nonceBefore = DUTCH_DESK.nonce();
            TROVE_MANAGER.borrow(troveId, _amount, type(uint256).max, 0, 0);
            _takeAuctionIfKicked(_nonceBefore);
        } else {
            TROVE_MANAGER.borrow(troveId, _amount, type(uint256).max, _amount, 0);
        }
    }

    /// @inheritdoc BaseLooper
    function _repay(uint256 amount) internal override {
        if (amount == 0) return;
        TROVE_MANAGER.repay(troveId, amount);
    }

    // ===============================================================
    // Flash loan
    // ===============================================================

    /// @inheritdoc BaseLooper
    function _executeFlashloan(address _token, uint256 _amount, bytes memory _data) internal override {
        _isFlashloanActive = true;
        MORPHO.flashLoan(_token, _amount, _data);
        _isFlashloanActive = false;
    }

    /// @inheritdoc BaseLooper
    function onMorphoFlashLoan(uint256 _assets, bytes calldata _data) external {
        require(msg.sender == address(MORPHO), "!morpho");
        require(_isFlashloanActive, "!active");
        _isClosing ? _handleClose(_assets) : _onFlashloanReceived(_assets, _data);
    }

    /// @inheritdoc BaseLooper
    function maxFlashloan() public view override returns (uint256) {
        return asset.balanceOf(address(MORPHO));
    }

    // ===============================================================
    // Protocol Views
    // ===============================================================

    /// @notice Checks if the Trove is active or not yet opened (troveId == 0)
    /// @dev Returns True when not opened yet to allow for seed deposits
    /// @return True if the Trove is active or not yet opened, false if it is zombie, liquidated, or closed
    function _isTroveActive() internal view returns (bool) {
        uint256 _troveId = troveId;
        return _troveId == 0 || TROVE_MANAGER.troves(_troveId).status == _STATUS_ACTIVE;
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
        if (!allowRedemption) return _idle;

        // Debt of all Troves paying a lower rate than ours (i.e. what we can redeem)
        uint256 _redeemable = DEBT_IN_FRONT_HELPER.get_debt_in_front(
            address(TROVE_MANAGER), // troveManager
            0, // interestRateLow
            TROVE_MANAGER.troves(_troveId).annualInterestRate, // interestRateHigh
            _troveId, // stopAtTroveId
            debtInFrontHintPrev, // hintPrevId
            debtInFrontHintNext // hintNextId
        );

        return _idle + _redeemable;
    }

    // ===============================================================
    // Oracle
    // ===============================================================

    /// @inheritdoc BaseLooper
    function _getCollateralPrice() internal view override returns (uint256) {
        return ORACLE.get_price(true);
    }

    // ===============================================================
    // Rewards
    // ===============================================================

    /// @inheritdoc BaseLooper
    function _claimAndSellRewards() internal pure override {
        return; // no rewards
    }

    // @todo -- here
    // ===============================================================
    // Close
    // ===============================================================

    /// @notice Fully unwind the trove via a flash loan (repay all debt + close),
    ///         leaving the freed equity as idle asset. Needed because repay()
    ///         can't take the trove below MIN_DEBT.
    function manualClose() external onlyEmergencyAuthorized {
        require(troveId != 0, "no trove");
        isClosing = true;
        _executeFlashloan(address(asset), balanceOfDebt(), "");
        isClosing = false;
    }

    function _handleClose(uint256 /*assets*/) internal {
        TROVE_MANAGER.close_trove(troveId);
        troveId = 0;
        _convertCollateralToAsset(balanceOfCollateralToken());
    }

    // ===============================================================
    // OPEN (MANAGEMENT, ONCE)
    // ===============================================================

    /// @notice Open the trove. Must be done by management before any looping.
    /// @dev Swaps `_assetToSeed` of idle asset into collateral and opens the
    ///      trove at MIN_DEBT. `_prevId`/`_nextId` are sorted-trove insertion
    ///      hints (computed off-chain). Seed enough that the MIN_DEBT trove
    ///      clears MCR.
    function openTrove(uint256 _assetToSeed, uint256 _annualInterestRate, uint256 _prevId, uint256 _nextId)
        external
        onlyManagement
        returns (uint256 _troveId)
    {
        require(troveId == 0, "trove exists");
        require(_assetToSeed <= balanceOfAsset(), "!idle");
        uint256 collateral = _convertAssetToCollateral(_assetToSeed);
        uint256 nonceBefore = IDutchDesk(DUTCH_DESK).nonce();
        _troveId = ITroveManager(TROVE_MANAGER).open_trove(
            OWNER_INDEX,
            collateral,
            MIN_DEBT,
            _prevId,
            _nextId,
            _annualInterestRate,
            type(uint256).max, // accept any upfront fee
            0,
            0,
            address(this)
        );
        troveId = _troveId;
        // Opening borrows MIN_DEBT, which can redeem if lender liquidity is short.
        _takeAuctionIfKicked(nonceBefore);
    }

    /// @notice Toggle whether borrows may redeem lower-rate troves for liquidity.
    /// @dev Enable only for vault-redeem markets (collateral is a vault of the
    ///      borrow token), where the redeemed-collateral->asset swap is lossless.
    function setAllowRedemption(bool _allowRedemption) external onlyManagement {
        allowRedemption = _allowRedemption;
    }

    /// @notice Update the sorted-troves hints used by the debt-in-front lookup in
    ///         `_maxBorrowAmount`, keeping that lookup cheap as the list changes.
    /// @dev Stale/bad hints only cost extra gas (the helper falls back to a linear
    ///      search), never correctness, so they're safe to leave to the emergency admin.
    function setDebtInFrontHints(uint256 _hintPrev, uint256 _hintNext) external onlyEmergencyAuthorized {
        debtInFrontHintPrev = _hintPrev;
        debtInFrontHintNext = _hintNext;
    }

    /*//////////////////////////////////////////////////////////////
                        REDEMPTION AUCTION TAKING
    //////////////////////////////////////////////////////////////*/

    /// @dev If the preceding borrow/open redeemed (bumping the dutch desk nonce),
    ///      it kicked auction id == `_nonceBefore` with this strategy as receiver.
    ///      Take it now so the borrow is fully realized in this same tx.
    function _takeAuctionIfKicked(uint256 _nonceBefore) internal {
        if (IDutchDesk(DUTCH_DESK).nonce() == _nonceBefore) return;
        isTakingAuction = true;
        // Non-empty data triggers takeCallback on us.
        IAuction(AUCTION).take(_nonceBefore, type(uint256).max, address(this), abi.encode(uint256(1)));
        isTakingAuction = false;
    }

    /// @dev Auction callback: we already received `amountTaken` of the redeemed
    ///      collateral; swap it back to asset (slippage-checked via the exchange)
    ///      and let the auction pull the `neededAmount` payment. As the auction
    ///      receiver, that payment circles back to us up to what we were owed.
    function takeCallback(
        uint256, /*auctionId*/
        address taker,
        uint256 amountTaken,
        uint256 neededAmount,
        bytes calldata /*data*/
    ) external {
        require(isTakingAuction && msg.sender == AUCTION, "!auction");
        require(taker == address(this), "!taker");
        _convertCollateralToAsset(amountTaken);
        ERC20(address(asset)).forceApprove(AUCTION, neededAmount);
    }
}
