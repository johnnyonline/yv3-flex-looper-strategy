// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {StdCheats} from "forge-std/StdCheats.sol";

import {IExchange} from "../../interfaces/IExchange.sol";
import {IPriceOracle} from "../../interfaces/IPriceOracle.sol";

/// @notice Minimal test exchange: swaps asset <-> collateral at the Flex oracle price
///         with zero slippage. Deals itself the exact output amount on each swap.
contract ExchangeMock is IExchange, StdCheats {

    using SafeERC20 for ERC20;

    uint256 internal constant ORACLE_SCALE = 1e36;

    address public immutable ASSET; // borrow token (e.g. USDC)
    address public immutable COLLATERAL; // collateral token (e.g. yvUSD)
    IPriceOracle public immutable ORACLE; // collateral price in asset terms, 1e36-scaled

    constructor(
        address _asset,
        address _collateral,
        address _oracle
    ) {
        ASSET = _asset;
        COLLATERAL = _collateral;
        ORACLE = IPriceOracle(_oracle);
    }

    /// @inheritdoc IExchange
    function name() external pure override returns (string memory) {
        return "ExchangeMock";
    }

    /// @inheritdoc IExchange
    function exchange(
        address _from,
        address _to,
        uint256 _amountIn,
        uint256 _amountOutMin
    ) external override returns (uint256 _amountOut) {
        ERC20(_from).safeTransferFrom(msg.sender, address(this), _amountIn);

        uint256 _price = ORACLE.get_price(true);
        if (_from == COLLATERAL && _to == ASSET) _amountOut = _amountIn * _price / ORACLE_SCALE;
        else if (_from == ASSET && _to == COLLATERAL) _amountOut = _amountIn * ORACLE_SCALE / _price;
        else revert("!pair");

        require(_amountOut >= _amountOutMin, "!amountOut");
        deal(_to, address(this), _amountOut);
        ERC20(_to).safeTransfer(msg.sender, _amountOut);
    }

}
