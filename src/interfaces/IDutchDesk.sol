// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

interface IDutchDesk {
    function nonce() external view returns (uint256); // bumps on every redemption auction kick
    function auction() external view returns (address);
}
