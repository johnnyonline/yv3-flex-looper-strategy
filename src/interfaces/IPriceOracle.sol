// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

interface IPriceOracle {
    /// @param scaled true => 10**(36 + borrowDecimals - collateralDecimals) format,
    ///        which is exactly BaseLooper's 1e36 price convention.
    function get_price(bool scaled) external view returns (uint256);
}
