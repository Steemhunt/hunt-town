// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC1155Receiver } from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import { ERC165 } from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { FactoryNFT } from "../../src/FactoryNFT.sol";

contract FactoryTestHunt is ERC20 {
    bool public chargeTransferFee;

    constructor() ERC20("Test HUNT", "HUNT") { }

    function mint(address receiver, uint256 amount) external {
        _mint(receiver, amount);
    }

    function setTransferFee(bool enabled) external {
        chargeTransferFee = enabled;
    }

    function _update(address from, address to, uint256 amount) internal override {
        if (chargeTransferFee && from != address(0) && to != address(0)) {
            uint256 fee = amount / 100;
            super._update(from, to, amount - fee);
            super._update(from, address(0), fee);
        } else {
            super._update(from, to, amount);
        }
    }
}

contract FactoryTestReceiver is ERC165, IERC1155Receiver {
    FactoryNFT public factory;
    bool public rejectTransfers;
    bool public attemptReentry;
    bool public mintReentrySucceeded;
    bool public burnReentrySucceeded;
    bytes public mintReentryResult;
    bytes public burnReentryResult;

    function configure(FactoryNFT factory_, IERC20 hunt, bool reject_, bool reenter_) external {
        factory = factory_;
        rejectTransfers = reject_;
        attemptReentry = reenter_;
        hunt.approve(address(factory_), type(uint256).max);
    }

    function onERC1155Received(address, address, uint256, uint256, bytes calldata)
        external
        override
        returns (bytes4)
    {
        _attemptReentry();
        return rejectTransfers ? bytes4(0) : this.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(
        address,
        address,
        uint256[] calldata,
        uint256[] calldata,
        bytes calldata
    ) external override returns (bytes4) {
        _attemptReentry();
        return rejectTransfers ? bytes4(0) : this.onERC1155BatchReceived.selector;
    }

    function _attemptReentry() private {
        if (!attemptReentry) return;
        (mintReentrySucceeded, mintReentryResult) = address(factory)
            .call(abi.encodeCall(FactoryNFT.mint, (1, type(uint256).max, address(this))));
        (burnReentrySucceeded, burnReentryResult) =
            address(factory).call(abi.encodeCall(FactoryNFT.burn, (1, 0)));
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC165, IERC165)
        returns (bool)
    {
        return interfaceId == type(IERC1155Receiver).interfaceId
            || super.supportsInterface(interfaceId);
    }
}
