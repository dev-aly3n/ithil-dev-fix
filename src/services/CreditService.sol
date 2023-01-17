// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.17;

import { Service } from "./Service.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

abstract contract CreditService is Service {
    function close(uint256 tokenID, bytes calldata data) public override {
        if (ownerOf(tokenID) != msg.sender) revert RestrictedToOwner();

        super.close(tokenID, data);
    }
}
