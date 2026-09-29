// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { ERC721 } from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import { ERC721Holder } from "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";
import { ERC1155Holder } from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import { IERC721Receiver } from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IFactoryNFT } from "../../src/interfaces/IFactoryNFT.sol";
import { BuildingMigrator } from "../../src/BuildingMigrator.sol";

contract MigratorTestBuilding is ERC721 {
    constructor() ERC721("Test Building", "BUILDING") { }

    function mint(address receiver, uint256 id) external {
        _mint(receiver, id);
    }
}

contract MigratorTestReceiver is ERC721Holder, ERC1155Holder {
    BuildingMigrator public migrator;
    bool public rejectMint;
    bytes public reentryResult;
    bytes public operatorReentryResult;
    bool public reentrySucceeded;
    bool public operatorReentrySucceeded;

    function configure(BuildingMigrator migrator_, bool rejectMint_) external {
        migrator = migrator_;
        rejectMint = rejectMint_;
    }

    function migrate(uint256[] calldata ids, uint256 maximum) external {
        migrator.building().setApprovalForAll(address(migrator), true);
        migrator.huntToken().approve(address(migrator), maximum);
        migrator.migrate(ids, maximum);
    }

    function onERC1155Received(address, address, uint256, uint256, bytes memory)
        public
        override
        returns (bytes4)
    {
        (reentrySucceeded, reentryResult) = address(migrator)
            .call(abi.encodeCall(BuildingMigrator.migrate, (new uint256[](0), 0)));
        (operatorReentrySucceeded, operatorReentryResult) = address(migrator)
            .call(
                abi.encodeCall(
                    BuildingMigrator.migrateByOperator,
                    (1, address(this), keccak256("nested receipt"), type(uint256).max)
                )
            );
        return rejectMint ? bytes4(0) : this.onERC1155Received.selector;
    }
}

contract MigratorTestCustody is IERC721Receiver {
    IFactoryNFT public factory;
    IERC20 public hunt;
    uint256 public donation;

    function configure(IFactoryNFT factory_, IERC20 hunt_, uint256 donation_) external {
        factory = factory_;
        hunt = hunt_;
        donation = donation_;
    }

    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4) {
        hunt.transfer(address(factory), donation);
        return this.onERC721Received.selector;
    }
}
