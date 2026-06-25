// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import "forge-std/console2.sol";
import {Test} from "forge-std/Test.sol";

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {FlexLooperStrategy as Strategy, ERC20} from "../../Strategy.sol";
import {StrategyFactory} from "../../StrategyFactory.sol";
import {IStrategyInterface} from "../../interfaces/IStrategyInterface.sol";
import {ITroveManager} from "../../interfaces/ITroveManager.sol";
import {IDebtInFrontHelper} from "../../interfaces/IDebtInFrontHelper.sol";

// Inherit the events so they can be checked if desired.
import {IEvents} from "@tokenized-strategy/interfaces/IEvents.sol";

interface IFactory {

    function governance() external view returns (address);

    function set_protocol_fee_bps(
        uint16
    ) external;

    function set_protocol_fee_recipient(
        address
    ) external;

}

interface ILender {

    function deposit(
        uint256 assets,
        address receiver
    ) external returns (uint256);

    function withdraw(
        uint256 assets,
        address receiver,
        address owner
    ) external returns (uint256);

    function maxWithdraw(
        address owner
    ) external view returns (uint256);

    function totalAssets() external view returns (uint256);

}

contract Setup is Test, IEvents {

    using SafeERC20 for ERC20;

    uint256 internal constant TEST_LEVERAGE_DUST_BPS = 100; // 1% of target leverage

    // Contract instances that we will use repeatedly.
    ERC20 public asset;
    ERC20 public collateral;
    IStrategyInterface public strategy;

    StrategyFactory public strategyFactory;

    mapping(string => address) public tokenAddrs;

    // Flex market (deployed yvUSD/USDC)
    address public yvusd = address(0x696d02Db93291651ED510704c9b286841d506987);
    address public troveManager = address(0xd82DB9893751E9C90E2a6C3bE31183048E8E2e49);
    // Deployed ERC4626Exchange (USDC <--> yvUSD via vault deposit/redeem)
    address public erc4626Exchange = address(0x13100bB6AB4e349A36EAa6bD4ab0536Bf72b3054);
    address public exchange;
    address public lender;

    // Addresses for different roles we will use repeatedly.
    address public user = address(10);
    address public seeder = address(777);
    address public lenderUser = address(420);
    address public keeper = address(4);
    address public management = address(1);
    address public performanceFeeRecipient = address(3);
    address public emergencyAdmin = address(5);

    // Address of the real deployed Factory
    address public factory;

    // Integer variables that will be used repeatedly.
    uint256 public decimals;
    uint256 public MAX_BPS = 10_000;

    // Fuzz from 1k USDC up to 100k USDC (6 decimals).
    uint256 public maxFuzzAmount = 100_000e6;
    uint256 public minFuzzAmount = 1_000e6;

    // Default profit max unlock time is set for 10 days
    uint256 public profitMaxUnlockTime = 10 days;

    // Borrow liquidity to seed into the lender so troves can draw idle on borrow.
    uint256 public constant LENDER_LIQUIDITY_SEED = 10_000_000e6;

    function setUp() public virtual {
        vm.createSelectFork(vm.envString("ETH_RPC_URL"), 25_261_306);

        _setTokenAddrs();

        // Set asset / collateral
        asset = ERC20(tokenAddrs["USDC"]);
        collateral = ERC20(yvusd);
        decimals = asset.decimals();

        lender = ITroveManager(troveManager).lender();

        strategyFactory = new StrategyFactory(management, performanceFeeRecipient, keeper, emergencyAdmin);

        exchange = _deployExchange();

        // Seed borrow liquidity so the market can serve borrows during levering.
        _seedLenderLiquidity(LENDER_LIQUIDITY_SEED);

        // Deploy strategy and set variables
        strategy = IStrategyInterface(setUpStrategy());

        factory = strategy.FACTORY();

        // label all the used addresses for traces
        vm.label(keeper, "keeper");
        vm.label(factory, "factory");
        vm.label(lender, "lender");
        vm.label(exchange, "exchange");
        vm.label(yvusd, "collateral");
        vm.label(address(asset), "asset");
        vm.label(management, "management");
        vm.label(troveManager, "troveManager");
        vm.label(address(strategy), "strategy");
        vm.label(performanceFeeRecipient, "performanceFeeRecipient");
    }

    /// @dev Override to swap the deployed exchange for the configurable mock
    function _deployExchange() internal virtual returns (address) {
        return erc4626Exchange;
    }

    function setUpStrategy() public returns (address) {
        IStrategyInterface _strategy = _deployStrategy();

        _openInitialTrove(_strategy);

        return address(_strategy);
    }

    function _deployStrategy() internal returns (IStrategyInterface _strategy) {
        // we save the strategy as a IStrategyInterface to give it the needed interface
        _strategy = IStrategyInterface(
            address(
                strategyFactory.newStrategy(
                    address(asset), // _asset
                    yvusd, // _collateralToken
                    "Flex Looper", // _name
                    troveManager, // _troveManager
                    exchange, // _exchange
                    _allowRedemption() // _allowRedemption
                )
            )
        );

        vm.startPrank(management);
        _strategy.acceptManagement();
        _strategy.setAllowed(user, true);
        _strategy.setAllowed(seeder, true);
        _strategy.setMaxGasPriceToTend(type(uint256).max);
        _strategy.setProfitMaxUnlockTime(0);
        vm.stopPrank();
    }

    /// @dev Override to deploy the strategy with redemption disabled
    function _allowRedemption() internal view virtual returns (bool) {
        return true;
    }

    /// @dev Donate a small asset seed to the strategy and open the trove at MIN_DEBT.
    function _openInitialTrove(
        IStrategyInterface _strategy
    ) internal {
        uint256 _seed = ITroveManager(troveManager).min_debt() * 2;
        mintAndDepositIntoStrategy(_strategy, seeder, _seed);

        uint256 _rate = ITroveManager(troveManager).min_annual_interest_rate() * 100;

        vm.prank(management);
        _strategy.openTrove(_rate, 0, 0, type(uint256).max);
    }

    /// @dev Make the lender hold enough borrow token to serve the strategy's borrows.
    function _seedLenderLiquidity(
        uint256 _amount
    ) internal {
        // Ignore the lender's deposit limit so fork tests don't depend on live headroom.
        vm.mockCall(lender, abi.encodeWithSignature("availableDepositLimit(address)"), abi.encode(type(uint256).max));

        airdrop(asset, lenderUser, _amount);
        vm.startPrank(lenderUser);
        asset.forceApprove(lender, _amount);
        ILender(lender).deposit(_amount, lenderUser);
        vm.stopPrank();
    }

    /// @dev Withdraw the seeded liquidity so the lender keeps at most `_keep` idle borrow token.
    function _drainLenderIdle(
        uint256 _keep
    ) internal {
        uint256 _idle = asset.balanceOf(lender);
        if (_idle <= _keep) return;

        uint256 _toRemove = _idle - _keep;
        uint256 _max = ILender(lender).maxWithdraw(lenderUser);
        if (_toRemove > _max) _toRemove = _max;

        vm.prank(lenderUser);
        ILender(lender).withdraw(_toRemove, lenderUser, lenderUser);
    }

    /// @dev Redeem as the Lender (Flex redeems lowest-rate Troves first). We redeem all the debt in
    ///      front of our Trove, then either twice our debt (dropping it below MIN_DEBT into a zombie)
    ///      or half our debt (a partial redemption that keeps it active). `_inFront` is ~0 when our
    ///      Trove holds all the debt, and the Lender redeem frees only what's available, so it's safe
    function simulateCollateralRedemption(
        bool _zombie
    ) internal {
        uint256 _troveId = strategy.troveId();
        uint256 _rate = ITroveManager(troveManager).troves(_troveId).annualInterestRate;
        uint256 _inFront = IDebtInFrontHelper(strategy.DEBT_IN_FRONT_HELPER())
            .get_debt_in_front(troveManager, 0, _rate, _troveId, 0, 0);

        uint256 _amount = _inFront + (_zombie ? strategy.balanceOfDebt() * 2 : strategy.balanceOfDebt() / 2);

        vm.prank(lender);
        ITroveManager(troveManager).redeem(_amount, address(this));

        uint256 _status = ITroveManager(troveManager).troves(_troveId).status;
        if (_zombie) require(_status == 2, "!zombie");
        else require(_status == 1, "!active");
    }

    /// @dev Mock the collateral oracle to report `_price`
    function _setCollateralPrice(
        uint256 _price
    ) internal {
        address _oracle = address(ITroveManager(troveManager).price_oracle());
        vm.mockCall(_oracle, abi.encodeWithSignature("get_price()"), abi.encode(_price));
        vm.mockCall(_oracle, abi.encodeWithSignature("get_price(bool)"), abi.encode(_price));
    }

    /// @dev Drop the price and liquidate the strategy's trove (this contract is the liquidator).
    ///      `_full` drops 40% so the 3x trove is underwater and fully wiped. Otherwise it drops 28%
    ///      so the trove is just below MCR and only partially liquidated, then the price recovers so
    ///      the surviving (now under-levered) trove stays active and can be re-levered
    function simulateLiquidation(
        bool _full
    ) internal {
        uint256 _price = ITroveManager(troveManager).price_oracle().get_price();
        _setCollateralPrice(_price * (_full ? 60 : 72) / 100);

        ITroveManager(troveManager)
            .liquidate_trove(strategy.troveId(), type(uint256).max, address(this), abi.encode(uint256(420)));

        uint256 _status = ITroveManager(troveManager).troves(strategy.troveId()).status;
        if (_full) {
            require(_status == 8, "!liquidated");
        } else {
            require(_status == 1, "!active");
            _setCollateralPrice(_price);
        }
    }

    /// @dev Liquidator callback: fund the repayment and approve the Trove Manager to pull it
    function takeCallback(
        uint256,
        address,
        uint256,
        uint256 _neededAmount,
        bytes calldata
    ) external {
        deal(address(asset), address(this), _neededAmount);
        asset.forceApprove(msg.sender, _neededAmount);
    }

    function _defaultMaxAmountToSwap() internal view virtual returns (uint256) {
        return type(uint256).max;
    }

    function depositIntoStrategy(
        IStrategyInterface _strategy,
        address _user,
        uint256 _amount
    ) public {
        vm.prank(_user);
        asset.forceApprove(address(_strategy), _amount);

        vm.prank(_user);
        _strategy.deposit(_amount, _user);
    }

    function mintAndDepositIntoStrategy(
        IStrategyInterface _strategy,
        address _user,
        uint256 _amount
    ) public {
        airdrop(asset, _user, _amount);
        depositIntoStrategy(_strategy, _user, _amount);
    }

    // For checking the amounts in the strategy
    function checkStrategyTotals(
        IStrategyInterface _strategy,
        uint256 _totalAssets,
        uint256 _totalDebt,
        uint256 _totalIdle
    ) public {
        uint256 _assets = _strategy.totalAssets();
        uint256 _balance = ERC20(_strategy.asset()).balanceOf(address(_strategy));
        uint256 _idle = _balance > _assets ? _assets : _balance;
        uint256 _debt = _assets - _idle;
        assertEq(_assets, _totalAssets, "!totalAssets");
        assertEq(_debt, _totalDebt, "!totalDebt");
        assertEq(_idle, _totalIdle, "!totalIdle");
        assertEq(_totalAssets, _totalDebt + _totalIdle, "!Added");
    }

    function airdrop(
        ERC20 _asset,
        address _to,
        uint256 _amount
    ) public {
        uint256 balanceBefore = _asset.balanceOf(_to);
        deal(address(_asset), _to, balanceBefore + _amount);
    }

    function accrueYield(
        uint256 _amount
    ) public virtual {
        uint256 _assetValue = (_amount * 300) / 10_000; // ~3% gain
        airdrop(asset, address(strategy), _assetValue);
    }

    function setFees(
        uint16 _protocolFee,
        uint16 _performanceFee
    ) public {
        address gov = IFactory(factory).governance();

        // Need to make sure there is a protocol fee recipient to set the fee.
        vm.prank(gov);
        IFactory(factory).set_protocol_fee_recipient(gov);

        vm.prank(gov);
        IFactory(factory).set_protocol_fee_bps(_protocolFee);

        vm.prank(management);
        strategy.setPerformanceFee(_performanceFee);
    }

    function _setTokenAddrs() internal {
        tokenAddrs["WBTC"] = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
        tokenAddrs["YFI"] = 0x0bc529c00C6401aEF6D220BE8C6Ea1667F6Ad93e;
        tokenAddrs["WETH"] = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
        tokenAddrs["LINK"] = 0x514910771AF9Ca656af840dff83E8264EcF986CA;
        tokenAddrs["USDT"] = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
        tokenAddrs["DAI"] = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
        tokenAddrs["USDC"] = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    }

    /*//////////////////////////////////////////////////////////////
                        LEVERAGE TEST HELPERS
    //////////////////////////////////////////////////////////////*/

    function _leverageDust() internal view returns (uint256) {
        return strategy.targetLeverageRatio() / TEST_LEVERAGE_DUST_BPS;
    }

    function _assetAmount(
        uint256 wholeTokens
    ) internal view returns (uint256) {
        return wholeTokens * (10 ** decimals);
    }

    function _lowerLeverageBound(
        uint256 targetLeverage,
        uint256 buffer
    ) internal view returns (uint256) {
        uint256 totalTolerance = buffer + _leverageDust();
        return targetLeverage > totalTolerance ? targetLeverage - totalTolerance : 0;
    }

    function _upperLeverageBound(
        uint256 targetLeverage,
        uint256 buffer
    ) internal view returns (uint256) {
        return targetLeverage + buffer + _leverageDust();
    }

    function _isWithinLeverageDust(
        uint256 leverage,
        uint256 targetLeverage
    ) internal view returns (bool) {
        uint256 dust = _leverageDust();
        if (leverage > targetLeverage) return leverage - targetLeverage <= dust;
        return targetLeverage - leverage <= dust;
    }

    function _isWithinTestBuffer(
        uint256 leverage,
        uint256 targetLeverage,
        uint256 buffer
    ) internal view returns (bool) {
        return leverage >= _lowerLeverageBound(targetLeverage, buffer)
            && leverage <= _upperLeverageBound(targetLeverage, buffer);
    }

    function _assertLeverageWithinTestBuffer(
        uint256 leverage,
        uint256 targetLeverage,
        uint256 buffer,
        string memory lowErr,
        string memory highErr
    ) internal view {
        assertGe(leverage, _lowerLeverageBound(targetLeverage, buffer), lowErr);
        assertLe(leverage, _upperLeverageBound(targetLeverage, buffer), highErr);
    }

    function _assertAtTargetLeverage() internal view {
        uint256 target = strategy.targetLeverageRatio();
        uint256 buffer = strategy.leverageBuffer();

        _assertLeverageWithinTestBuffer(
            strategy.getCurrentLeverageRatio(), target, buffer, "!leverage low", "!leverage high"
        );

        (uint256 collateralValue, uint256 debt) = strategy.position();
        uint256 equity = collateralValue - debt;
        assertApproxEqRel(collateralValue, target * equity / 1e18, buffer, "!collateral");
        assertApproxEqRel(debt, (target - 1e18) * equity / 1e18, buffer, "!debt");
    }

    function logStrategyStatus(
        string memory label
    ) public view {
        console2.log("=== Strategy Status:", label, "===");
        console2.log("Total Assets:", strategy.totalAssets());
        (uint256 collateralValue, uint256 debt) = strategy.position();
        console2.log("Collateral:", collateralValue);
        console2.log("Debt:", debt);
        console2.log("Loose Asset:", strategy.balanceOfAsset());
        console2.log("Current LTV:", strategy.getCurrentLTV());
        console2.log("Current Leverage:", strategy.getCurrentLeverageRatio());
        console2.log("Max Flashloan:", strategy.maxFlashloan());
        console2.log("==============================");
    }

}
