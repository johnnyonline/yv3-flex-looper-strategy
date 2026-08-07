// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.23;

interface ICatFactory {

    struct DeployParams {
        address borrow_token;
        address collateral_token;
        address price_oracle;
        uint256 minimum_debt;
        uint256 safe_collateral_ratio;
        uint256 minimum_collateral_ratio;
        uint256 max_penalty_collateral_ratio;
        uint256 min_liquidation_fee;
        uint256 max_liquidation_fee;
        uint256 upfront_interest_period;
        uint256 interest_rate_adj_cooldown;
        uint256 repay_cooldown;
        uint256 minimum_price_buffer_percentage;
        uint256 starting_price_buffer_percentage;
        uint256 re_kick_starting_price_buffer_percentage;
        uint256 step_duration;
        uint256 step_decay_rate;
        uint256 auction_length;
        bytes32 salt;
    }

    function deploy(
        DeployParams calldata params
    ) external returns (address, address, address, address, address);

}
