// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.17;

import { GeneralMath } from "../libraries/GeneralMath.sol";
import { DebitService } from "../services/DebitService.sol";
import { IService } from "../interfaces/IService.sol";

/// @dev constant value IR model, used for testing
abstract contract ConstantRateModel is DebitService {
    using GeneralMath for uint256;
    error AboveRiskThreshold();

    mapping(address => uint256) public riskSpreads;
    mapping(address => uint256) public baseRisks;

    function setRiskParams(address token, uint256 riskSpread, uint256 baseRisk) external onlyOwner {
        riskSpreads[token] = riskSpread;
        baseRisks[token] = baseRisk;
    }

    /// @dev Defaults to riskSpread = baseRiskSpread * amount / margin
    function riskSpreadFromMargin(address token, uint256 amount, uint256 margin) internal view returns (uint256) {
        return riskSpreads[token].safeMulDiv(amount, margin);
    }

    // todo: with this it's constant, do we want to increase based on Vault's usage?
    function _checkRiskiness(IService.Loan memory loan, uint256 /*freeLiquidity*/) internal override {
        uint256 spread = riskSpreadFromMargin(loan.token, loan.amount, loan.margin);
        (uint256 requestedIr, uint256 requestedSpread) = loan.interestAndSpread.unpackUint();
        if (requestedIr < baseRisks[loan.token] || requestedSpread < spread) revert AboveRiskThreshold();
    }
}
