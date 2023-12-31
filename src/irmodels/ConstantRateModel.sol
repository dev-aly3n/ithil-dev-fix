// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.18;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { IService } from "../interfaces/IService.sol";
import { BaseRiskModel } from "../services/BaseRiskModel.sol";

/// @dev constant value IR model, used for testing
abstract contract ConstantRateModel is Ownable, BaseRiskModel {
    error AboveRiskThreshold();
    error ZeroMarginLoan();

    mapping(address => uint256) public riskSpreads;
    mapping(address => uint256) public baseRisks;

    function setRiskParams(address token, uint256 riskSpread, uint256 baseRisk) external onlyOwner {
        riskSpreads[token] = riskSpread;
        baseRisks[token] = baseRisk;
    }

    /// @dev Defaults to riskSpread = baseRiskSpread * amount / margin
    function _riskSpreadFromMargin(address token, uint256 amount, uint256 margin) internal view returns (uint256) {
        if (amount == 0) return 0;
        // We do not allow a zero margin on a loan with positive amount
        if (margin == 0) revert ZeroMarginLoan();
        return (riskSpreads[token] * amount) / margin;
    }

    // todo: with this it's constant, do we want to increase based on Vault's usage?
    function _checkRiskiness(
        IService.Loan memory loan,
        uint256 /*freeLiquidity*/
    ) internal view override(BaseRiskModel) {
        uint256 spread = _riskSpreadFromMargin(loan.token, loan.amount, loan.margin);
        (uint256 requestedIr, uint256 requestedSpread) = (
            loan.interestAndSpread >> 128,
            loan.interestAndSpread % (1 << 128)
        );
        if (requestedIr < baseRisks[loan.token] || requestedSpread < spread) revert AboveRiskThreshold();
    }
}
