// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.18;

import { IERC20, SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IVault } from "../../interfaces/IVault.sol";
import { IOracle } from "../../interfaces/IOracle.sol";
import { IFactory } from "../../interfaces/external/wizardex/IFactory.sol";
import { IPool } from "../../interfaces/external/wizardex/IPool.sol";
import { Whitelisted } from "../Whitelisted.sol";
import { Service } from "../Service.sol";
import { VeIthil } from "../../VeIthil.sol";

/// @title    FeeCollectorService contract
/// @author   Ithil
/// @notice   A service to perform leveraged staking on any Aave markets
contract FeeCollectorService is Service {
    using SafeERC20 for IERC20;

    // Percentage of fees which can be harvested. Only locked fees can be harvested
    uint256 public immutable feePercentage;
    IERC20 public immutable weth;
    VeIthil public immutable veToken;
    IOracle public immutable oracle;
    IFactory public immutable dex;

    // weights for different tokens, 0 => not supported
    // assumes 18 digit fixed point math
    mapping(address => uint256) public weights;
    // Locking of the position in seconds
    mapping(uint256 => uint256) public locktimes;
    // Necessary to avoid a double harvest: harvesting is allowed only once after each repay
    mapping(address => uint256) public latestHarvest;
    // Necessary to properly distribute fees and prevent snatching
    uint256 public totalLoans;
    // 2^((n+1)/12) with 18 digit fixed point
    uint64[] internal _rewards;

    event TokenWeightWasChanged(address indexed token, uint256 weight);

    error Throttled();
    error InsufficientProfits();
    error ZeroLoan();
    error BeforeExpiry();
    error ZeroAmount();
    error UnsupportedToken();
    error MaxLockExceeded();

    constructor(
        address _manager,
        address _weth,
        uint256 _feePercentage,
        address _oracle,
        address _dex
    ) Service("FeeCollector", "FEE-COLLECTOR", _manager, type(uint256).max) {
        veToken = new VeIthil();

        weth = IERC20(_weth);
        oracle = IOracle(_oracle);
        dex = IFactory(_dex);

        feePercentage = _feePercentage;
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

    modifier expired(uint256 tokenId) {
        if (agreements[tokenId].createdAt + locktimes[tokenId] * 86400 * 30 > block.timestamp) revert BeforeExpiry();
        _;
    }

    function setTokenWeight(address token, uint256 weight) external onlyOwner {
        weights[token] = weight;

        emit TokenWeightWasChanged(token, weight);
    }

    // Weth weight is the same as virtual balance rather than balance
    // In this way, who locks for more time has right to more shares
    function totalAssets() public view returns (uint256) {
        return veToken.totalSupply() + weth.balanceOf(address(this));
    }

    function _open(Agreement memory agreement, bytes memory data) internal override {
        if (agreement.loans[0].margin == 0) revert ZeroAmount();
        if (weights[agreement.loans[0].token] == 0) revert UnsupportedToken();
        // Update collateral using ERC4626 formula
        uint256 assets = totalAssets();
        agreement.loans[0].amount = assets == 0
            ? agreement.loans[0].margin
            : (agreement.loans[0].margin * totalLoans) / assets;
        // Apply reward based on lock
        uint256 monthsLocked = abi.decode(data, (uint256));
        if (monthsLocked > 11) revert MaxLockExceeded();
        agreement.loans[0].amount =
            (agreement.loans[0].amount * (_rewards[monthsLocked] * weights[agreement.loans[0].token])) /
            1e36;
        // Total loans is updated
        // We must be sure it's positive, otherwise division by zero would make the position impossible to close
        if (agreement.loans[0].amount == 0) revert ZeroLoan();
        totalLoans += agreement.loans[0].amount;
        // Collateral is equal to the amount of veTokens to mint
        agreement.collaterals[0].amount =
            (agreement.loans[0].margin * (_rewards[monthsLocked] * weights[agreement.loans[0].token])) /
            1e36;
        veToken.mint(msg.sender, agreement.collaterals[0].amount);
        // register locktime
        locktimes[id] = monthsLocked + 1;
        // Deposit Ithil
        IERC20(agreement.loans[0].token).safeTransferFrom(msg.sender, address(this), agreement.loans[0].margin);
    }

    function _close(
        uint256 tokenID,
        Agreement memory agreement,
        bytes memory /*data*/
    ) internal override expired(tokenID) {
        uint256 totalWithdraw = (totalAssets() * agreement.loans[0].amount) / totalLoans;
        totalLoans -= agreement.loans[0].amount;
        veToken.burn(msg.sender, agreement.collaterals[0].amount);
        // give back Ithil tokens
        IERC20(agreement.loans[0].token).safeTransfer(msg.sender, agreement.loans[0].margin);
        // Transfer weth
        if (totalWithdraw > agreement.collaterals[0].amount)
            weth.safeTransfer(msg.sender, totalWithdraw - agreement.collaterals[0].amount);
    }

    function withdrawFees(uint256 tokenId) external returns (uint256) {
        if (ownerOf(tokenId) != msg.sender) revert RestrictedAccess();
        Agreement memory agreement = agreements[tokenId];
        // This is the total withdrawable, consisting of virtualIthil + weth
        // Thus it has no physical meaning: it's an auxiliary variable
        uint256 totalWithdraw = (totalAssets() * agreement.loans[0].amount) / totalLoans;
        // By subtracting the Ithil staked we get only the weth part: this is the weth the user is entitled to
        uint256 toTransfer;
        if (totalWithdraw > agreement.collaterals[0].amount) {
            toTransfer = totalWithdraw - agreement.collaterals[0].amount;
            // Update collateral and totalCollateral
            // With the new state, we will have totalAssets * collateral / totalCollateral = margin
            // Thus, the user cannot withdraw again (unless other fees are generated)
            uint256 toSubtract = (agreement.loans[0].amount * toTransfer) / totalWithdraw;
            agreement.loans[0].amount -= toSubtract;
            totalLoans -= toSubtract;
            weth.safeTransfer(msg.sender, toTransfer);
        }

        return toTransfer;
    }

    function _harvestFees(address token) internal returns (uint256, address) {
        IVault vault = IVault(manager.vaults(token));
        (uint256 profits, uint256 losses, , uint256 latestRepay) = vault.getFeeStatus();
        if (latestRepay < latestHarvest[token]) revert Throttled();
        if (profits <= losses) revert InsufficientProfits();
        latestHarvest[token] = block.timestamp;

        uint256 feesToHarvest = ((profits - losses) * feePercentage) / 1e18;
        manager.borrow(token, feesToHarvest, 0, address(this));
        // todo: reward harvester

        return (feesToHarvest, address(vault));
    }

    function harvestAndSwap(address[] calldata tokens) external {
        uint256 length = tokens.length;
        for (uint256 i = 0; i < length; i++) {
            (uint256 amount, address vault) = _harvestFees(tokens[i]);

            // Swap if not WETH
            if (tokens[i] != address(weth)) {
                // TODO check assumption: all pools will have same the tick
                IPool pool = IPool(dex.pools(tokens[i], address(weth), 5));

                // TODO check oracle
                uint256 price = oracle.getPrice(tokens[i], address(weth), 1);

                // TODO add discount to price
                pool.createOrder(amount, price, vault, block.timestamp + 1 weeks);
            }
        }
    }
}
