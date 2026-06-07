// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.23;

import {IAuction} from "./IAuction.sol";

interface IDutchDesk {

    function nonce() external view returns (uint256);
    function auction() external view returns (IAuction);

}
