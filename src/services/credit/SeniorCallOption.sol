// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.18;

import { IERC20, SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { CreditService } from "../CreditService.sol";
import { Service } from "../Service.sol";
import { IService } from "../../interfaces/IService.sol";
import { IVault } from "../../interfaces/IVault.sol";
import { Service } from "../Service.sol";

/// @title    Call option contract
/// @author   Ithil
/// @notice   A service to obtain a call option on ITHIL by boosting
contract SeniorCallOption is CreditService {
    using SafeERC20 for IERC20;
    // It would be very hard to make a multi-token call option and ensuring consistency between prices
    // Therefore we make a single-token call option with a dutch auction price scheme
    // Price has precision of the underlying token
    // Total price is initialPrice + latestSpread
    // initialPrice is fixed, latestSpread follows a Dutch auction model
    uint256 public latestSpread;
    uint256 public latestOpen;
    uint256 public halvingTime;
    uint256 public totalAllocation;

    // This is the initial price, below which the token price cannot go
    // Beware that the actual minimum price is HALF the initial price
    // This is because locking liquidity for 1y will give a 50% discount
    uint256 public immutable initialPrice;
    IERC20 public immutable underlying;
    IERC20 public immutable ithil;
    address public immutable treasury;

    // 2^((n+1)/12) with 18 digit fixed point
    uint64[] internal _rewards;

    uint256 internal immutable _precision;

    error ZeroAmount();
    error ZeroCollateral();
    error MaxLockExceeded();
    error MaxPurchaseExceeded();
    error InvalidCalledPortion();

    constructor(
        address _manager,
        address _treasury,
        address _ithil,
        uint256 _deadline,
        uint256 _initialPrice,
        uint256 _halvingTime,
        address _underlying
    ) Service("Ithil Senior Call Option", "SCALL", _manager, _deadline) {
        require(_initialPrice > 0, "Zero initial price");
        initialPrice = _initialPrice;
        treasury = _treasury;
        underlying = IERC20(_underlying);
        ithil = IERC20(_ithil);
        _precision = 10 ** IERC20Metadata(_underlying).decimals();
        halvingTime = _halvingTime;

        _rewards = new uint64[](12);
        _rewards[0] = 1059463094359295265;
        _rewards[1] = 1122462048309372981;
        _rewards[2] = 1189207115002721067;
        _rewards[3] = 1259921049894873165;
        _rewards[4] = 1334839854170034365;
        _rewards[5] = 1414213562373095049;
        _rewards[6] = 1498307076876681499;
        _rewards[7] = 1587401051968199475;
        _rewards[8] = 1681792830507429086;
        _rewards[9] = 1781797436280678609;
        _rewards[10] = 1887748625363386993;
        _rewards[11] = 2000000000000000000;
    }

    function _open(Agreement memory agreement, bytes memory data) internal override {
        if (agreement.loans[0].amount == 0) revert ZeroAmount();
        uint256 currentPrice = _currentPrice();
        // Apply reward based on lock
        uint256 monthsLocked = abi.decode(data, (uint256));
        if (monthsLocked > 11) revert MaxLockExceeded();

        // The amount bought if no price update were applied
        uint256 virtualBoughtAmount = (((agreement.loans[0].amount * _precision) / currentPrice) *
            _rewards[monthsLocked]) / 1e18;
        // Update current price based on the current balance and the collateral amount
        // One cannot purchase more than the total allocation
        if (totalAllocation <= virtualBoughtAmount) revert MaxPurchaseExceeded();

        // Update latest open and latest spread
        latestOpen = block.timestamp;
        // Total price increases as a function of the remaining allocation in inverse proportionality
        // E.g. if 50% of the entire allocation is bought, the current price gets multiplied by 2
        // if 10% of the allocation is bought, remaining is 9/10 so price gets multiplied by 10/9, etc...
        // notice that the denominator is positive since totalAllocation > virtualBoughtAmount
        latestSpread = (currentPrice * totalAllocation) / (totalAllocation - virtualBoughtAmount) - initialPrice;

        // We register the amount of ITHIL to be redeemed as collateral
        // The user obtains a discount based on how many months the position is locked
        agreement.collaterals[0].amount =
            (((agreement.loans[0].amount * _precision) / (initialPrice + latestSpread)) * _rewards[monthsLocked]) /
            1e18;

        if (agreement.collaterals[0].amount == 0) revert ZeroCollateral();

        // update allocation: since we cannot know how much will be called, we subtract max
        // since collateral <= totalAllocation, this subtraction does not underflow
        totalAllocation -= agreement.collaterals[0].amount;
    }

    function _close(uint256 tokenID, IService.Agreement memory agreement, bytes memory data) internal virtual override {
        // The portion of the loan amount we want to call
        uint256 calledPortion = abi.decode(data, (uint256));
        if (calledPortion > 1e18) revert InvalidCalledPortion();

        // gas savings
        IVault vault = IVault(manager.vaults(agreement.loans[0].token));
        uint256 redeemable = vault.convertToAssets(agreement.collaterals[0].amount);
        uint256 toTransfer = dueAmount(agreement, data);
        uint256 toCall = (agreement.collaterals[0].amount * calledPortion) / 1e18;
        // The amount of ithil not called can be added back to the total allocation
        totalAllocation += (agreement.collaterals[0].amount - toCall);
        if (toTransfer > redeemable) {
            // Since this service is senior, we need to pay the user even if redeemable is too low
            // To do this, we take liquidity from the vault and register the loss (no loan)
            uint256 freeLiquidity = vault.freeLiquidity();
            if (freeLiquidity > 0) {
                manager.borrow(
                    agreement.loans[0].token,
                    toTransfer - redeemable > freeLiquidity - 1 ? freeLiquidity - 1 : toTransfer - redeemable,
                    0,
                    ownerOf(tokenID)
                );
            }
        }

        // We will always have ithil.balanceOf(address(this)) >= toCall, so the following succeeds
        ithil.safeTransfer(ownerOf(tokenID), toCall);
    }

    function _currentPrice() internal view returns (uint256) {
        return initialPrice + (latestSpread * halvingTime) / (block.timestamp - latestOpen + halvingTime);
    }

    function dueAmount(Agreement memory agreement, bytes memory data) public view virtual override returns (uint256) {
        // The portion of the loan amount we want to call
        uint256 calledPortion = abi.decode(data, (uint256));

        // The non-called portion is capital to give back to the user
        return (agreement.loans[0].amount * (1e18 - calledPortion)) / 1e18;
    }

    function allocateIthil(uint256 amount) external onlyOwner {
        totalAllocation += amount;
        ithil.safeTransferFrom(msg.sender, address(this), amount);
    }

    function sweepIthil() external onlyOwner {
        // Only total allocation can be swept, otherwise there would be a risk of rug pull
        // in case owner sweeps balance when there are still open orders
        uint256 initialAllocation = totalAllocation;
        totalAllocation = 0;
        ithil.safeTransfer(msg.sender, initialAllocation);
    }
}
