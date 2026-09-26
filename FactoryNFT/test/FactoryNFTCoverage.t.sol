// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { FactoryNFT } from "../src/FactoryNFT.sol";
import { FactoryNFTTestBase } from "./FactoryNFT.t.sol";
import { FactoryTestHunt } from "./mocks/FactoryNFTMocks.sol";

contract FactoryNFTCoverageTest is FactoryNFTTestBase {
    function testConstructorRejectsAnExternallyOwnedHuntAddress() public {
        vm.expectRevert(FactoryNFT.InvalidAddress.selector);
        _deployUnchecked(FactoryTestHunt(ALICE), TEAM, bytes32(uint256(1)));
    }

    function testConstructorRejectsAZeroSeedOwner() public {
        vm.expectRevert(FactoryNFT.InvalidAddress.selector);
        _deployUnchecked(hunt, address(0), bytes32(uint256(1)));
    }

    function testConstructorRejectsItselfAsSeedOwner() public {
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        vm.expectRevert(FactoryNFT.InvalidAddress.selector);
        new FactoryNFT(IERC20(address(hunt)), address(this), predicted, "", ROYALTY_OPERATOR);
    }

    function testConstructorRejectsAZeroRoyaltyOperator() public {
        vm.expectRevert(FactoryNFT.InvalidAddress.selector);
        new FactoryNFT(IERC20(address(hunt)), address(this), TEAM, "", address(0));
    }

    function testMintRejectsZeroAndSelfReceiversWithoutTakingHunt() public {
        hunt.mint(ALICE, SEED);
        vm.startPrank(ALICE);
        hunt.approve(address(factory), SEED);
        vm.expectRevert(FactoryNFT.InvalidAddress.selector);
        factory.mint(1, SEED, address(0));
        vm.expectRevert(FactoryNFT.InvalidAddress.selector);
        factory.mint(1, SEED, address(factory));
        vm.stopPrank();
        assertEq(hunt.balanceOf(ALICE), SEED);
        assertEq(hunt.balanceOf(address(factory)), SEED);
        assertEq(factory.totalSupply(ID), 1);
        assertEq(factory.balanceOf(TEAM, ID), 1);
    }

    function testZeroRoyaltyOperatorCannotReplaceTheConfiguredReceiver() public {
        vm.expectRevert(FactoryNFT.InvalidAddress.selector);
        factory.setRoyaltyOperator(address(0));
        assertEq(factory.royaltyOperator(), ROYALTY_OPERATOR);
        (address receiver, uint256 royalty) = factory.royaltyInfo(ID, SEED);
        assertEq(receiver, ROYALTY_OPERATOR);
        assertEq(royalty, 30e18);
    }

    function testSupportsInterfaceRejectsUnknownIds() public view {
        assertTrue(factory.supportsInterface(type(IERC165).interfaceId));
        assertFalse(factory.supportsInterface(0xffffffff));
    }
}
