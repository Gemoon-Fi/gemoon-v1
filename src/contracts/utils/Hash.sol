// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

type Hash is bytes32;

library Hashes {
	function hashTokenPair(address tokenA, address tokenB) internal pure returns (Hash) {
		return Hash.wrap(keccak256(abi.encodePacked(tokenA < tokenB ? tokenA : tokenB, tokenA < tokenB ? tokenB : tokenA)));
	}

	/// @dev Hash of a referral code, the key of `Referrals` code storage.
	function codeToToken(string calldata refCode) internal pure returns (Hash) {
		return Hash.wrap(keccak256(abi.encodePacked(refCode)));
	}
}