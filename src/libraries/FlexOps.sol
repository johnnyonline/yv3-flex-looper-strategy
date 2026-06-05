// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {ITroveManager} from "../interfaces/ITroveManager.sol";
import {IDebtInFrontHelper} from "../interfaces/IDebtInFrontHelper.sol";

library FlexOps {

    uint256 internal constant _STATUS_ACTIVE = 1;
    uint256 internal constant _STATUS_ZOMBIE = 2;

    function openTrove(
        ITroveManager _troveManager,
        uint256 _ownerIndex,
        uint256 _collateral,
        uint256 _minDebt,
        uint256 _prevId,
        uint256 _nextId,
        uint256 _annualInterestRate,
        uint256 _maxUpfrontFee,
        uint256 _minBorrowOut
    ) external returns (uint256) {
        return _troveManager.open_trove(
            _ownerIndex,
            _collateral,
            _minDebt,
            _prevId,
            _nextId,
            _annualInterestRate,
            _maxUpfrontFee,
            _minBorrowOut,
            0, // minCollateralOut
            address(this) // owner (delegatecall => the Strategy)
        );
    }

    function addCollateral(ITroveManager _troveManager, uint256 _troveId, uint256 _amount) external {
        _troveManager.add_collateral(_troveId, _amount);
    }

    function removeCollateral(ITroveManager _troveManager, uint256 _troveId, uint256 _amount) external {
        _troveManager.remove_collateral(_troveId, _amount);
    }

    function borrow(ITroveManager _troveManager, uint256 _troveId, uint256 _amount, uint256 _minBorrowOut) external {
        _troveManager.borrow(_troveId, _amount, type(uint256).max, _minBorrowOut, 0);
    }

    function repay(ITroveManager _troveManager, uint256 _troveId, uint256 _amount) external {
        _troveManager.repay(_troveId, _amount);
    }

    /// @notice Close an ACTIVE or ZOMBIE Trove (no-op for any other status).
    function closeTrove(ITroveManager _troveManager, uint256 _troveId) external {
        uint256 _status = _troveManager.troves(_troveId).status;
        if (_status == _STATUS_ACTIVE) {
            _troveManager.close_trove(_troveId);
        } else if (_status == _STATUS_ZOMBIE) {
            _troveManager.close_zombie_trove(_troveId);
        }
    }

    function adjustInterestRate(
        ITroveManager _troveManager,
        uint256 _troveId,
        uint256 _newAnnualInterestRate,
        uint256 _prevId,
        uint256 _nextId,
        uint256 _maxUpfrontFee
    ) external {
        _troveManager.adjust_interest_rate(_troveId, _newAnnualInterestRate, _prevId, _nextId, _maxUpfrontFee);
    }

    /// @notice Debt of all Troves paying a lower rate than ours, i.e. what we can redeem.
    function maxRedeemable(
        IDebtInFrontHelper _helper,
        ITroveManager _troveManager,
        uint256 _troveId,
        uint256 _hintPrev,
        uint256 _hintNext
    ) external view returns (uint256) {
        return _helper.get_debt_in_front(
            address(_troveManager),
            0, // interestRateLow
            _troveManager.troves(_troveId).annualInterestRate, // interestRateHigh
            _troveId, // stopAtTroveId
            _hintPrev,
            _hintNext
        );
    }
}
