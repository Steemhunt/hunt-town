// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { IERC1155 } from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {
    IERC1155MetadataURI
} from "@openzeppelin/contracts/token/ERC1155/extensions/IERC1155MetadataURI.sol";
import { IERC2981 } from "@openzeppelin/contracts/interfaces/IERC2981.sol";

import { FactoryNFT } from "../src/FactoryNFT.sol";

/// @notice Optional Ethereum fork checks against real HUNT.
/// @dev Funding uses local storage cheatcodes. These tests never broadcast transactions.
contract FactoryNFTForkTest is Test {
    address internal constant HUNT = 0x9AAb071B4129B083B01cB5A0Cb513Ce7ecA26fa5;
    address internal constant SEED_OWNER = address(0x5EED);
    address internal constant ALICE = address(0xA11CE);
    address internal constant ROYALTY_RECEIVER = address(0xFEE);
    uint256 internal constant ID = 0;
    uint256 internal constant SEED = 1_000e18;

    bool internal forkEnabled;
    FactoryNFT internal factory;
    IERC20 internal hunt;

    modifier onMainnetFork() {
        vm.skip(!forkEnabled, "Set MAINNET_RPC_URL to run optional Ethereum fork tests");
        _;
    }

    function setUp() public {
        string memory rpcUrl = vm.envOr("MAINNET_RPC_URL", string(""));
        if (bytes(rpcUrl).length == 0) return;

        uint256 forkBlock = vm.envOr("MAINNET_FORK_BLOCK", uint256(0));
        if (forkBlock == 0) {
            vm.createSelectFork(rpcUrl);
        } else {
            vm.createSelectFork(rpcUrl, forkBlock);
        }
        forkEnabled = true;

        assertEq(block.chainid, 1, "MAINNET_RPC_URL must select Ethereum mainnet");
        assertGt(HUNT.code.length, 0, "HUNT must exist at the selected block");
        hunt = IERC20(HUNT);

        deal(HUNT, address(this), SEED);
        // Isolated execution treats approve as a separate transaction, consuming one nonce.
        uint256 deploymentNonce = vm.getNonce(address(this)) + (vm.isIsolateMode() ? 1 : 0);
        address predicted = vm.computeCreateAddress(address(this), deploymentNonce);
        assertTrue(hunt.approve(predicted, SEED));
        assertEq(hunt.allowance(address(this), predicted), SEED);
        factory = new FactoryNFT(
            hunt, address(this), SEED_OWNER, "ipfs://factory/{id}.json", ROYALTY_RECEIVER
        );
        assertEq(address(factory), predicted);
    }

    function testForkRealHuntSeedMintAndBulkBurn() public onMainnetFork {
        assertEq(IERC20Metadata(HUNT).decimals(), 18);
        assertEq(address(factory.huntToken()), HUNT);
        assertEq(hunt.balanceOf(address(this)), 0);
        assertEq(hunt.allowance(address(this), address(factory)), 0);
        assertEq(hunt.balanceOf(address(factory)), SEED);
        assertEq(factory.balanceOf(SEED_OWNER, ID), 1);
        assertEq(factory.totalSupply(ID), 1);

        deal(HUNT, ALICE, 2 * SEED);
        vm.startPrank(ALICE);
        assertTrue(hunt.approve(address(factory), 2 * SEED));
        assertEq(factory.mint(2, 2 * SEED, ALICE), 2 * SEED);
        assertEq(hunt.allowance(ALICE, address(factory)), 0);
        assertEq(hunt.balanceOf(ALICE), 0);
        assertEq(factory.balanceOf(ALICE, ID), 2);
        assertEq(factory.totalSupply(ID), 3);
        assertEq(hunt.balanceOf(address(factory)), 3 * SEED);

        assertEq(factory.burn(2, 1_900e18), 1_900e18);
        vm.stopPrank();
        assertEq(hunt.balanceOf(ALICE), 1_900e18);
        assertEq(hunt.balanceOf(address(factory)), 1_100e18);
        assertEq(factory.balanceOf(ALICE, ID), 0);
        assertEq(factory.balanceOf(SEED_OWNER, ID), 1);
        assertEq(factory.totalSupply(ID), 1);
        assertEq(factory.navPerNFT(), 1_100e18);
    }

    function testForkRealHuntConstructorRequiresSeedAllowance() public onMainnetFork {
        deal(HUNT, address(this), SEED);
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        assertEq(hunt.allowance(address(this), predicted), 0);
        vm.expectRevert();
        new FactoryNFT(hunt, address(this), SEED_OWNER, "", ROYALTY_RECEIVER);
        assertEq(hunt.balanceOf(address(this)), SEED);
        assertEq(hunt.balanceOf(predicted), 0);
    }

    function testForkInterfaceMetadataAndRoyalty() public onMainnetFork {
        assertTrue(factory.supportsInterface(type(IERC1155).interfaceId));
        assertTrue(factory.supportsInterface(type(IERC1155MetadataURI).interfaceId));
        assertTrue(factory.supportsInterface(type(IERC2981).interfaceId));
        assertEq(factory.uri(ID), "ipfs://factory/{id}.json");
        (address receiver, uint256 amount) = factory.royaltyInfo(ID, 100 ether);
        assertEq(receiver, ROYALTY_RECEIVER);
        assertEq(amount, 3 ether);
    }
}
