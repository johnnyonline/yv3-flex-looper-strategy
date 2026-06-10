// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.23;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IExchange} from "../interfaces/IExchange.sol";

contract yvUSDToUSDCExchange is IExchange {

    using SafeERC20 for ERC20;

    /// @notice The borrow token
    ERC20 public constant USDC = ERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);

    /// @notice The collateral token
    IERC4626 public constant YVUSD = IERC4626(0x696d02Db93291651ED510704c9b286841d506987);

    constructor() {
        // Max approve the vault to pull USDC on deposits
        USDC.forceApprove(address(YVUSD), type(uint256).max);
    }

    /// @inheritdoc IExchange
    function name() external pure override returns (string memory) {
        return "yvUSDToUSDCExchange";
    }

    /// @inheritdoc IExchange
    function exchange(
        address _from,
        address _to,
        uint256 _amountIn,
        uint256 _amountOutMin
    ) external override returns (uint256 _amountOut) {
        ERC20(_from).safeTransferFrom(msg.sender, address(this), _amountIn);

        if (_from == address(USDC) && _to == address(YVUSD)) {
            _amountOut = YVUSD.deposit(_amountIn, msg.sender);
        } else if (_from == address(YVUSD) && _to == address(USDC)) {
            _amountOut = YVUSD.redeem(_amountIn, msg.sender, address(this));
        } else {
            revert("!pair");
        }

        require(_amountOut >= _amountOutMin, "!amountOut");
    }

}
