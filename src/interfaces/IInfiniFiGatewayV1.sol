// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.23;

interface IInfiniFiGatewayV1 {

    function mintAndStake(
        address _to,
        uint256 _amount
    ) external returns (uint256);
    function unstake(
        address _to,
        uint256 _amount
    ) external returns (uint256);
    function redeem(
        address _to,
        uint256 _amount,
        uint256 _minAssetsOut
    ) external returns (uint256);
    function claimRedemption() external;
    function getAddress(
        string memory _name
    ) external view returns (address);

}
