// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.23;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ILidoWithdrawalQueue} from "../interfaces/ILidoWithdrawalQueue.sol";
import {IWETH, IwstETH} from "../interfaces/IStethInterfaces.sol";

import {BaseLooper, ERC20, FlexLooperStrategy, Math} from "../Strategy.sol";

contract LidoFlexLooperStrategy is FlexLooperStrategy {

    using SafeERC20 for ERC20;

    // ===============================================================
    // Storage
    // ===============================================================

    /// @notice stETH queued in Lido's withdrawal queue. Storage var and not the queue's list to avoid unsolicited requests issues
    uint256 public queuedSteth;

    /// @notice Whether reports ignore the pending redemptions, an escape hatch for management
    bool public ignorePending;

    // ===============================================================
    // Constants
    // ===============================================================

    /// @notice Pending amount below which reports are not blocked, for stETH rounding dust
    uint256 internal constant _PENDING_DUST = 1e15; // 0.001 WETH

    /// @notice WETH token
    address public constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    /// @notice wstETH token
    address public constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;

    /// @notice stETH token
    ERC20 public constant STETH = ERC20(0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84);

    /// @notice Lido withdrawal queue
    ILidoWithdrawalQueue public constant WITHDRAWAL_QUEUE =
        ILidoWithdrawalQueue(0x889edC2eDab5f40e902b864aD4d7AdE8E412F9B1);

    // ===============================================================
    // Constructor
    // ===============================================================

    /// @param _name Strategy name
    /// @param _troveManager The Flex Trove Manager contract of a wstETH/WETH market
    /// @param _exchange The exchange address for collateral <--> asset swaps
    /// @param _governance The address allowed to update exchange configuration
    constructor(
        string memory _name,
        address _troveManager,
        address _exchange,
        address _governance
    ) FlexLooperStrategy(WETH, WSTETH, _name, _troveManager, _exchange, false, _governance) {
        // Max approve the withdrawal queue to pull the stETH being unwound
        STETH.forceApprove(address(WITHDRAWAL_QUEUE), type(uint256).max);
    }

    /// @notice Needed to receive ETH from the withdrawal queue
    receive() external payable {}

    // ===============================================================
    // Accounting
    // ===============================================================

    /// @notice Asset value queued in Lido's withdrawal queue, 1:1 with stETH
    function pendingRedemptions() public view returns (uint256) {
        return queuedSteth;
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

    /// @notice Zero the queued stETH
    /// @dev Escape hatch for a request that can't be claimed. Whatever is zeroed shows up as a loss on report
    function zeroPendingRedemptions() external onlyManagement {
        queuedSteth = 0;
    }

    /// @notice Unwrap loose wstETH and queue the stETH for a 1:1 withdrawal through Lido
    /// @dev Lido caps a single request at 1000 stETH, larger unwinds need multiple calls
    /// @param _shares The amount of wstETH to unwind, capped by the loose balance
    /// @return _requestId Lido withdrawal request id, used to claim once finalized
    function initiateCooldown(
        uint256 _shares
    ) external onlyEmergencyAuthorized returns (uint256 _requestId) {
        _shares = Math.min(_shares, balanceOfCollateralToken());
        require(_shares > 0, "!shares");

        // wstETH --> stETH
        uint256 _pendingAssets = IwstETH(WSTETH).unwrap(_shares);

        // Record the queued stETH
        queuedSteth += _pendingAssets;

        // Queue the stETH for withdrawal
        uint256[] memory _amounts = new uint256[](1);
        _amounts[0] = _pendingAssets;
        _requestId = WITHDRAWAL_QUEUE.requestWithdrawals(_amounts, address(this))[0];
    }

    /// @notice Claim finalized withdrawal requests from Lido, with checkpoint hints
    /// @dev Lido warns its own hint search in `claimWithdrawal` can run out of gas
    /// @param _requestIds The withdrawal request ids to claim
    /// @param _hints The checkpoint hints, from the queue's `findCheckpointHints`
    /// @return _assets The amount of asset claimed
    function claimCooldown(
        uint256[] calldata _requestIds,
        uint256[] calldata _hints
    ) external onlyEmergencyAuthorized returns (uint256 _assets) {
        // Consume the queued stETH by the requests' amounts, so a discounted claim shows up as a loss on report
        ILidoWithdrawalQueue.WithdrawalRequestStatus[] memory _statuses =
            WITHDRAWAL_QUEUE.getWithdrawalStatus(_requestIds);
        uint256 _claimedSteth;
        for (uint256 i; i < _statuses.length; ++i) {
            _claimedSteth += _statuses[i].amountOfStETH;
        }
        queuedSteth -= Math.min(_claimedSteth, queuedSteth);

        // Claim the withdrawals and wrap the received ETH
        uint256 _balanceBefore = balanceOfAsset();
        WITHDRAWAL_QUEUE.claimWithdrawals(_requestIds, _hints);
        if (address(this).balance > 0) IWETH(WETH).deposit{value: address(this).balance}();
        _assets = balanceOfAsset() - _balanceBefore;
        require(_assets > 0, "!assets");
    }

}
