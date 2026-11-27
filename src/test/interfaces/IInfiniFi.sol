// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.23;

import {IRedeemController} from "../../interfaces/IRedeemController.sol";

interface IInfiniFiCore {

    function getRoleMember(
        bytes32 _role,
        uint256 _index
    ) external view returns (address);

}

interface ILiveRedeemController is IRedeemController {

    function core() external view returns (address);
    function accounting() external view returns (address);
    function beforeRedeemHook() external view returns (address);
    function liquidity() external view returns (uint256);
    function setBeforeRedeemHook(
        address _hook
    ) external;
    function deposit() external;
    function withdraw(
        uint256 _amount,
        address _to
    ) external;

}

interface IGatewayMint {

    function mint(
        address _to,
        uint256 _amount
    ) external returns (uint256);

}
