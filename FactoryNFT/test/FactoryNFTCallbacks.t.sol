// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { ERC1155Holder } from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import { IERC1155 } from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import { IERC1155Errors } from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { FactoryNFT } from "../src/FactoryNFT.sol";
import { FactoryNFTTestBase } from "./FactoryNFT.t.sol";

contract FactoryNFTCallbackReceiver is ERC1155Holder {
    enum Action {
        Redeem,
        MintThenRedeem,
        Deposit,
        ForwardAndTryGuardedCalls,
        ForwardTwice
    }

    FactoryNFT private immutable factory;
    address private immutable destination;
    Action private immutable action;
    bool private entered;
    bool[3] public callSucceeded;
    bytes[3] public callResult;

    constructor(FactoryNFT factory_, IERC20 hunt, address destination_, Action action_) {
        factory = factory_;
        destination = destination_;
        action = action_;
        hunt.approve(address(factory_), type(uint256).max);
    }

    function onERC1155Received(address, address, uint256, uint256, bytes memory)
        public
        override
        returns (bytes4)
    {
        _act();
        return this.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(
        address,
        address,
        uint256[] memory,
        uint256[] memory,
        bytes memory
    ) public override returns (bytes4) {
        _act();
        return this.onERC1155BatchReceived.selector;
    }

    function _act() private {
        if (entered) return;
        entered = true;
        if (action == Action.Redeem) {
            factory.burn(factory.balanceOf(address(this), 0), 0);
        } else if (action == Action.MintThenRedeem) {
            factory.mint(1, type(uint256).max, address(this));
            factory.burn(factory.balanceOf(address(this), 0), 0);
        } else if (action == Action.Deposit) {
            factory.deposit(100 ether, factory.totalSupply(0));
        } else if (action == Action.ForwardAndTryGuardedCalls) {
            factory.safeTransferFrom(address(this), destination, 0, 1, "");
            bytes[3] memory calls = [
                abi.encodeCall(FactoryNFT.mint, (1, type(uint256).max, address(this))),
                abi.encodeCall(FactoryNFT.burn, (1, 0)),
                abi.encodeCall(FactoryNFT.deposit, (100 ether, factory.totalSupply(0)))
            ];
            for (uint256 i; i < calls.length; ++i) {
                (callSucceeded[i], callResult[i]) = address(factory).call(calls[i]);
            }
        } else {
            factory.safeTransferFrom(address(this), destination, 0, 1, "");
            (callSucceeded[0], callResult[0]) = address(factory)
                .call(
                    abi.encodeCall(
                        IERC1155.safeTransferFrom, (address(this), destination, 0, 1, "")
                    )
                );
        }
    }
}

contract FactoryNFTCallbacksTest is FactoryNFTTestBase {
    function _receiver(FactoryNFTCallbackReceiver.Action action)
        private
        returns (FactoryNFTCallbackReceiver receiver)
    {
        receiver = new FactoryNFTCallbackReceiver(factory, hunt, BOB, action);
        hunt.mint(address(receiver), 2 * SEED);
    }

    function testSingleTransferCallbackRedeemsAtSettledBalances() public {
        _mintFor(ALICE, 2);
        FactoryNFTCallbackReceiver receiver = _receiver(FactoryNFTCallbackReceiver.Action.Redeem);
        vm.prank(ALICE);
        factory.safeTransferFrom(ALICE, address(receiver), ID, 1, "");
        assertEq(factory.totalSupply(ID), 2);
        assertEq(factory.balanceOf(address(receiver), ID), 0);
        assertEq(hunt.balanceOf(address(factory)), 2_050 ether);
        assertEq(hunt.balanceOf(address(receiver)), 2_950 ether);
    }

    function testBatchUpdatesAllBalancesBeforeCallbackRedemption() public {
        _mintFor(ALICE, 2);
        FactoryNFTCallbackReceiver receiver = _receiver(FactoryNFTCallbackReceiver.Action.Redeem);
        uint256[] memory ids = new uint256[](2);
        uint256[] memory amounts = new uint256[](2);
        ids[0] = ID;
        ids[1] = ID;
        amounts[0] = 1;
        amounts[1] = 1;
        vm.prank(ALICE);
        factory.safeBatchTransferFrom(ALICE, address(receiver), ids, amounts, "");
        assertEq(factory.totalSupply(ID), 1);
        assertEq(factory.balanceOf(ALICE, ID), 0);
        assertEq(factory.balanceOf(address(receiver), ID), 0);
        assertEq(hunt.balanceOf(address(factory)), 1_100 ether);
        assertEq(hunt.balanceOf(address(receiver)), 3_900 ether);
    }

    function testTransferCallbackMintAndBurnPreserveAccounting() public {
        _mintFor(ALICE, 2);
        FactoryNFTCallbackReceiver receiver =
            _receiver(FactoryNFTCallbackReceiver.Action.MintThenRedeem);
        vm.prank(ALICE);
        factory.safeTransferFrom(ALICE, address(receiver), ID, 1, "");
        assertEq(factory.totalSupply(ID), 2);
        assertEq(factory.balanceOf(address(receiver), ID), 0);
        assertEq(hunt.balanceOf(address(factory)), 2_100 ether);
        assertEq(hunt.balanceOf(address(receiver)), 2_900 ether);
    }

    function testTransferCallbackDepositUsesSettledSupply() public {
        _mintFor(ALICE, 2);
        FactoryNFTCallbackReceiver receiver = _receiver(FactoryNFTCallbackReceiver.Action.Deposit);
        vm.prank(ALICE);
        factory.safeTransferFrom(ALICE, address(receiver), ID, 1, "");
        assertEq(factory.totalSupply(ID), 3);
        assertEq(factory.balanceOf(address(receiver), ID), 1);
        assertEq(hunt.balanceOf(address(factory)), 3_100 ether);
        assertEq(hunt.balanceOf(address(receiver)), 1_900 ether);
    }

    function testMintCallbackCanForwardButMintBurnAndDepositRemainGuarded() public {
        FactoryNFTCallbackReceiver receiver =
            _receiver(FactoryNFTCallbackReceiver.Action.ForwardAndTryGuardedCalls);
        hunt.mint(ALICE, SEED);
        vm.startPrank(ALICE);
        hunt.approve(address(factory), SEED);
        factory.mint(1, SEED, address(receiver));
        vm.stopPrank();
        assertEq(factory.balanceOf(BOB, ID), 1);
        assertEq(factory.balanceOf(address(receiver), ID), 0);
        assertEq(factory.totalSupply(ID), 2);
        assertEq(hunt.balanceOf(address(factory)), 2_000 ether);
        bytes memory expected = abi.encodeWithSignature("ReentrancyGuardReentrantCall()");
        for (uint256 i; i < 3; ++i) {
            assertFalse(receiver.callSucceeded(i));
            assertEq(receiver.callResult(i), expected);
        }
    }

    function testForwardedUnitCannotBeTransferredTwice() public {
        _mintFor(ALICE, 1);
        FactoryNFTCallbackReceiver receiver =
            _receiver(FactoryNFTCallbackReceiver.Action.ForwardTwice);
        vm.prank(ALICE);
        factory.safeTransferFrom(ALICE, address(receiver), ID, 1, "");
        assertFalse(receiver.callSucceeded(0));
        assertEq(
            receiver.callResult(0),
            abi.encodeWithSelector(
                IERC1155Errors.ERC1155InsufficientBalance.selector, address(receiver), 0, 1, ID
            )
        );
        assertEq(factory.balanceOf(BOB, ID), 1);
        assertEq(factory.balanceOf(address(receiver), ID), 0);
        assertEq(factory.totalSupply(ID), 2);
        assertEq(hunt.balanceOf(address(factory)), 2_000 ether);
    }
}
