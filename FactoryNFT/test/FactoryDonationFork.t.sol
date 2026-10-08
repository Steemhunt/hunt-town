// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { FactoryDonation } from "../src/FactoryDonation.sol";
import { FactoryNFT } from "../src/FactoryNFT.sol";

/// @notice Optional fork checks against the deployed Ethereum Factory NFT and real HUNT.
/// @dev Funding uses local storage cheatcodes. These tests never broadcast transactions.
contract FactoryDonationForkTest is Test {
    address internal constant HUNT = 0x9AAb071B4129B083B01cB5A0Cb513Ce7ecA26fa5;
    address internal constant FACTORY = 0x961eA6C51c185958b1A11ad8335046988D1B5734;
    address internal constant DONOR = address(0xA11CE);
    uint256 internal constant FORK_BLOCK = 26_146_887;
    uint256 internal constant AMOUNT = 2_500e18;

    event Deposited(address indexed depositor, uint256 huntIn, uint256 supply);
    event Donated(address indexed donor, uint256 amount, string message);

    bool internal forkEnabled;
    FactoryDonation internal donation;
    FactoryNFT internal factory;
    IERC20 internal hunt;

    modifier onMainnetFork() {
        vm.skip(!forkEnabled, "Set MAINNET_RPC_URL to run optional Ethereum fork tests");
        _;
    }

    function setUp() public {
        string memory rpcUrl = vm.envOr("MAINNET_RPC_URL", string(""));
        if (bytes(rpcUrl).length == 0) return;

        vm.createSelectFork(rpcUrl, vm.envOr("DONATION_FORK_BLOCK", FORK_BLOCK));
        forkEnabled = true;
        assertEq(block.chainid, 1, "MAINNET_RPC_URL must select Ethereum mainnet");
        assertGt(HUNT.code.length, 0, "HUNT must exist at the selected block");
        assertGt(FACTORY.code.length, 0, "Factory NFT must exist at the selected block");

        hunt = IERC20(HUNT);
        factory = FactoryNFT(FACTORY);
        assertEq(address(factory.huntToken()), HUNT);
        donation = new FactoryDonation(factory);
        deal(HUNT, DONOR, 2 * AMOUNT);
    }

    function testForkDonationUpdatesRealVaultAndRecordsOriginalDonor() public onMainnetFork {
        uint256 supply = factory.totalSupply(0);
        uint256 beforeVault = hunt.balanceOf(FACTORY);
        uint256 beforeNav = factory.navPerNFT();
        assertEq(factory.balanceOf(DONOR, 0), 0);
        assertEq(address(donation.factory()), FACTORY);
        assertEq(address(donation.huntToken()), HUNT);
        assertEq(hunt.allowance(address(donation), FACTORY), type(uint256).max);

        vm.prank(DONOR);
        assertTrue(hunt.approve(address(donation), AMOUNT));
        vm.expectEmit(true, false, false, true, FACTORY);
        emit Deposited(address(donation), AMOUNT, supply);
        vm.expectEmit(true, false, false, true, address(donation));
        emit Donated(DONOR, AMOUNT, "For every builder.");
        vm.prank(DONOR);
        donation.donate(AMOUNT, supply, "For every builder.");

        assertEq(hunt.balanceOf(FACTORY), beforeVault + AMOUNT);
        assertEq(factory.navPerNFT(), (beforeVault + AMOUNT) / supply);
        assertGt(factory.navPerNFT(), beforeNav);
        assertEq(factory.totalSupply(0), supply);
        assertEq(factory.balanceOf(DONOR, 0), 0);
        assertEq(hunt.balanceOf(DONOR), AMOUNT);
        assertEq(hunt.balanceOf(address(donation)), 0);
        assertEq(hunt.allowance(DONOR, address(donation)), 0);
        // The deployed HUNT token decrements even a maximum allowance.
        assertEq(hunt.allowance(address(donation), FACTORY), type(uint256).max - AMOUNT);
    }

    function testForkEmptyAndMaximumMessagesBothDeposit() public onMainnetFork {
        uint256 supply = factory.totalSupply(0);
        uint256 beforeVault = hunt.balanceOf(FACTORY);
        bytes memory message = new bytes(donation.MAX_MESSAGE_BYTES());
        for (uint256 i; i < message.length; ++i) {
            message[i] = 0x41;
        }
        assertEq(message.length, 280);

        vm.prank(DONOR);
        assertTrue(hunt.approve(address(donation), 2 * AMOUNT));
        vm.expectEmit(true, false, false, true, address(donation));
        emit Donated(DONOR, AMOUNT, "");
        vm.prank(DONOR);
        donation.donate(AMOUNT, supply, "");
        vm.expectEmit(true, false, false, true, address(donation));
        emit Donated(DONOR, AMOUNT, string(message));
        vm.prank(DONOR);
        donation.donate(AMOUNT, supply, string(message));

        assertEq(hunt.balanceOf(FACTORY), beforeVault + 2 * AMOUNT);
        assertEq(hunt.balanceOf(DONOR), 0);
        assertEq(hunt.balanceOf(address(donation)), 0);
        assertEq(hunt.allowance(DONOR, address(donation)), 0);
        assertEq(hunt.allowance(address(donation), FACTORY), type(uint256).max - 2 * AMOUNT);
        assertEq(factory.totalSupply(0), supply);
    }

    function testForkSupplyMismatchRollsBackTransfersAndAllowances() public onMainnetFork {
        uint256 supply = factory.totalSupply(0);
        uint256 beforeVault = hunt.balanceOf(FACTORY);
        vm.prank(DONOR);
        assertTrue(hunt.approve(address(donation), AMOUNT));
        uint256 beforeFactoryAllowance = hunt.allowance(address(donation), FACTORY);

        vm.expectRevert(
            abi.encodeWithSelector(FactoryNFT.SupplyChanged.selector, supply, supply + 1)
        );
        vm.prank(DONOR);
        donation.donate(AMOUNT, supply + 1, "This donation must revert.");

        assertEq(hunt.balanceOf(FACTORY), beforeVault);
        assertEq(hunt.balanceOf(DONOR), 2 * AMOUNT);
        assertEq(hunt.balanceOf(address(donation)), 0);
        assertEq(hunt.allowance(DONOR, address(donation)), AMOUNT);
        assertEq(hunt.allowance(address(donation), FACTORY), beforeFactoryAllowance);
        assertEq(factory.totalSupply(0), supply);
    }
}
