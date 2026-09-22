// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

type Hash is bytes32;

library Hashes {
	function hashTokenPair(address tokenA, address tokenB) internal pure returns (Hash) {
		return Hash.wrap(keccak256(abi.encodePacked(tokenA < tokenB ? tokenA : tokenB, tokenA < tokenB ? tokenB : tokenA)));
	}
}