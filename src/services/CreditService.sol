// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.18;

import { IERC20, SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IVault } from "../interfaces/IVault.sol";
import { Service } from "./Service.sol";

abstract contract CreditService is Service {
    using SafeERC20 for IERC20;

    error InvalidInput();

    function open(Order calldata order) public virtual override unlocked {
        Agreement memory agreement = order.agreement;
        // Transfers deposit the loan to the relevant vault
        for (uint256 index = 0; index < agreement.loans.length; index++) {
            address vaultAddress = manager.vaults(agreement.loans[index].token);
            if (
                agreement.collaterals[index].itemType != ItemType.ERC20 ||
                agreement.collaterals[index].token != vaultAddress
            ) revert InvalidInput();
            // Transfer tokens to this
            IERC20(agreement.loans[index].token).safeTransferFrom(
                msg.sender,
                address(this),
                agreement.loans[index].amount
            );

            // Deposit tokens to the relevant vault
            if (
                IERC20(agreement.loans[index].token).allowance(address(this), vaultAddress) <
                agreement.loans[index].amount
            ) IERC20(agreement.loans[index].token).approve(vaultAddress, type(uint256).max);
            uint256 shares = IVault(vaultAddress).deposit(agreement.loans[index].amount, address(this));

            // Register obtained shares
            agreement.collaterals[index].amount = shares;
        }
        Service.open(order);
    }

    function close(uint256 tokenID, bytes calldata data) public virtual override returns (uint256[] memory) {
        Agreement memory agreement = agreements[tokenID];
        address owner = ownerOf(tokenID);
        if (owner != msg.sender && agreement.createdAt + deadline > block.timestamp) revert RestrictedToOwner();
        Service.close(tokenID, data);

        for (uint256 index = 0; index < agreement.loans.length; index++) {
            IVault vault = IVault(manager.vaults(agreement.loans[index].token));
            uint256 toTransfer = dueAmount(agreement, data);

            // we allow the closure to fail if there is not enough liquidity: we always redeem the maximum amount
            uint256 redeemed = vault.redeem(agreement.collaterals[index].amount, address(this), address(this));
            // give toTransfer to the user and pay the vault if toTransfer < redeemed
            // otherwise transfer redeemed and do nothing
            if (toTransfer < redeemed) {
                manager.repay(agreement.loans[index].token, redeemed - toTransfer, 0, address(this));
                IERC20(agreement.loans[index].token).safeTransfer(owner, toTransfer);
            } else IERC20(agreement.loans[index].token).safeTransfer(owner, redeemed);
        }
    }

    // dueAmount must be implemented otherwise the credit service is worthless
    function dueAmount(Agreement memory agreement, bytes memory data) public view virtual returns (uint256);
}
