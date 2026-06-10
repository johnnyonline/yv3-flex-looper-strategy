// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.23;

import {IAuction} from "./IAuction.sol";

interface IDutchDesk {

    function nonce() external view returns (uint256);
    function auction() external view returns (IAuction);
    function starting_price_buffer_percentage() external view returns (uint256);

}
