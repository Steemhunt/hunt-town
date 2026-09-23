// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/// @notice OpenSea Creator Token interface for transfer-validator discovery and configuration.
interface ICreatorToken {
    event TransferValidatorUpdated(address oldValidator, address newValidator);

    function getTransferValidator() external view returns (address validator);
    function getTransferValidationFunction()
        external
        view
        returns (bytes4 functionSignature, bool isViewFunction);
    function setTransferValidator(address validator) external;
}

interface ITransferValidator {
    function validateTransfer(
        address caller,
        address from,
        address to,
        uint256 tokenId,
        uint256 amount
    ) external;
}
