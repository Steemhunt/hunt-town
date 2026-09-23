// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { FactoryNFT } from "../src/FactoryNFT.sol";
import { ICreatorToken, ITransferValidator } from "../src/interfaces/ICreatorToken.sol";
import { FactoryNFTTestBase } from "./FactoryNFT.t.sol";
import { FactoryTestHunt, FactoryTestTransferValidator } from "./mocks/FactoryNFTMocks.sol";

contract FactoryNFTCoverageTest is FactoryNFTTestBase {
    function testConstructorRejectsAnExternallyOwnedHuntAddress() public {
        vm.expectRevert(FactoryNFT.InvalidAddress.selector);
        _deployUnchecked(FactoryTestHunt(ALICE), TEAM, address(0), bytes32(uint256(1)));
    }

    function testConstructorRejectsAZeroSeedOwner() public {
        vm.expectRevert(FactoryNFT.InvalidAddress.selector);
        _deployUnchecked(hunt, address(0), address(0), bytes32(uint256(1)));
    }

    function testConstructorRejectsItselfAsSeedOwner() public {
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        vm.expectRevert(FactoryNFT.InvalidAddress.selector);
        new FactoryNFT(
            IERC20(address(hunt)), address(this), predicted, "", ROYALTY_OPERATOR, address(0)
        );
    }

    function testConstructorRejectsAZeroRoyaltyOperator() public {
        vm.expectRevert(FactoryNFT.InvalidAddress.selector);
        new FactoryNFT(IERC20(address(hunt)), address(this), TEAM, "", address(0), address(0));
    }

    function testConstructorRejectsAnExternallyOwnedValidator() public {
        vm.expectRevert(FactoryNFT.InvalidAddress.selector);
        _deployUnchecked(hunt, TEAM, ALICE, bytes32(uint256(1)));
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

    function testCreatorTokenDiscoveryReportsTheAmountAwareValidator() public {
        assertTrue(factory.supportsInterface(type(ICreatorToken).interfaceId));
        assertFalse(factory.supportsInterface(0xffffffff));
        assertEq(factory.getTransferValidator(), address(0));
        (bytes4 selector, bool isViewFunction) = factory.getTransferValidationFunction();
        assertEq(selector, ITransferValidator.validateTransfer.selector);
        assertFalse(isViewFunction);

        FactoryTestTransferValidator validator = new FactoryTestTransferValidator();
        factory.setTransferValidator(address(validator));
        assertEq(factory.getTransferValidator(), address(validator));
        factory.setTransferValidator(address(0));
        assertEq(factory.getTransferValidator(), address(0));
    }

    function testMismatchedBatchArraysRevertBeforeValidatorOrBalanceChanges() public {
        _mintFor(ALICE, 2);
        FactoryTestTransferValidator validator = new FactoryTestTransferValidator();
        factory.setTransferValidator(address(validator));
        validator.setRejectTransfers(true);
        uint256[] memory ids = new uint256[](2);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1;

        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSignature("ERC1155InvalidArrayLength(uint256,uint256)", 2, 1));
        factory.safeBatchTransferFrom(ALICE, BOB, ids, amounts, "");

        assertEq(validator.validationCount(), 0);
        assertEq(factory.balanceOf(ALICE, ID), 2);
        assertEq(factory.balanceOf(BOB, ID), 0);
        assertEq(factory.totalSupply(ID), 3);
        assertEq(hunt.balanceOf(address(factory)), 3 * SEED);
    }
}
