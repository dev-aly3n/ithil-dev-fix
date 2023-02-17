// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.17;

import { IERC20, SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ERC20PresetMinterPauser } from "@openzeppelin/contracts/token/ERC20/presets/ERC20PresetMinterPauser.sol";
import { IVault } from "../../src/interfaces/IVault.sol";
import { Service, IService } from "../../src/services/Service.sol";
import { WhitelistedService } from "../../src/services/WhitelistedService.sol";
import { GeneralMath } from "../../src/libraries/GeneralMath.sol";
import { IManager, Manager } from "../../src/Manager.sol";
import { BaseIntegrationServiceTest } from "./BaseIntegrationServiceTest.sol";
import { Helper } from "./Helper.sol";

contract TestService is WhitelistedService {
    constructor(address manager) Service("TestService", "TEST-SERVICE", manager) {}

    function _open(Agreement memory agreement, bytes calldata data) internal override {}

    function edit(uint256 tokenID, Agreement calldata agreement, bytes calldata data) public override {}

    function _close(uint256 tokenID, Agreement memory agreement, bytes calldata data) internal override {}
}

contract WhitelistedServiceTest is BaseIntegrationServiceTest {
    using SafeERC20 for IERC20;

    TestService internal immutable service;
    ERC20PresetMinterPauser internal immutable token;
    address internal constant whitelistedUser = address(uint160(uint(keccak256(abi.encodePacked("Whitelisted")))));
    address internal constant whitelistedUser2 = address(uint160(uint(keccak256(abi.encodePacked("Whitelisted2")))));
    uint256 internal constant collateral = 1e18;
    uint256 internal constant loan = 10 * 1e18;
    uint256 internal constant margin = 1e18;

    string internal constant rpcUrl = "MAINNET_RPC_URL";
    uint256 internal constant blockNumber = 16448665;

    constructor() BaseIntegrationServiceTest(rpcUrl, blockNumber) {
        token = new ERC20PresetMinterPauser("test", "TEST");

        vm.startPrank(admin);
        service = new TestService(address(manager));
        vm.stopPrank();
        serviceAddress = address(service);
        loanLength = 1;
    }

    function setUp() public override {
        token.mint(whitelistedUser, type(uint128).max);
        token.mint(address(this), type(uint128).max);

        vm.prank(whitelistedUser);
        token.approve(address(service), type(uint256).max);

        vm.startPrank(admin);
        manager.create(address(token));
        manager.setCap(address(service), address(token), GeneralMath.RESOLUTION);
        vm.stopPrank();
    }

    function testWhitelist() public {
        IService.Order memory order = Helper.createSimpleERC20Order(
            address(token),
            loan,
            margin,
            address(token),
            collateral
        );

        vm.expectRevert(bytes4(keccak256(abi.encodePacked("UserIsNotWhitelisted()"))));
        service.open(order);

        address[] memory whitelistedUsers = new address[](2);
        whitelistedUsers[0] = whitelistedUser;
        whitelistedUsers[1] = whitelistedUser2;

        vm.prank(admin);
        service.addToWhitelist(whitelistedUsers);

        vm.prank(whitelistedUser);
        service.open(order);

        vm.prank(whitelistedUser2);
        service.open(order);

        vm.prank(admin);
        service.removeFromWhitelist(whitelistedUsers);

        vm.expectRevert(bytes4(keccak256(abi.encodePacked("UserIsNotWhitelisted()"))));
        vm.prank(whitelistedUser);
        service.open(order);

        vm.expectRevert(bytes4(keccak256(abi.encodePacked("UserIsNotWhitelisted()"))));
        vm.prank(whitelistedUser2);
        service.open(order);

        vm.prank(admin);
        service.toggleWhitelistFlag();

        service.open(order);
        vm.prank(whitelistedUser);
        service.open(order);
    }
}