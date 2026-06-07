// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.23;

interface IMorpho {

    function flashLoan(
        address token,
        uint256 assets,
        bytes calldata data
    ) external;

}
