// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {
    ERC165Checker
} from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";

import {Address} from "./Address.sol";

library InterfaceChecker {
    function supportsInterface(
        address contractAddress,
        bytes4 interfaceId
    ) internal view returns (bool) {
        return
            Address.isContract(contractAddress) &&
            ERC165Checker.supportsERC165(contractAddress) &&
            ERC165Checker.supportsInterface(contractAddress, interfaceId);
    }
}
