// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.23;

interface IPriceOracle {

    function get_price(
        bool scaled
    ) external view returns (uint256);

}
