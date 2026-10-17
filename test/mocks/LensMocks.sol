// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

/// @notice Token with `totalSupply` and `balanceOf` only: no metadata, no `creator()`.
contract NoMetadataToken {
    function totalSupply() external pure returns (uint256) {
        return 1_000e18;
    }

    function balanceOf(address) external pure returns (uint256) {
        return 0;
    }
}

/// @notice Token whose optional getters answer with data that does not decode as the standard
/// types: `bytes32` name, out-of-range `decimals` and `creator`, broken string encodings.
contract MalformedToken {
    function totalSupply() external pure returns (uint256) {
        return 7;
    }

    /// @dev Old-style `bytes32` name: 32 bytes of return data instead of a dynamic string.
    function name() external pure returns (bytes32) {
        return "OLD";
    }

    function symbol() external pure {
        revert();
    }

    function decimals() external pure returns (uint256) {
        return 256;
    }

    function creator() external pure returns (uint256) {
        return type(uint256).max;
    }

    /// @dev Valid offset, but the announced length runs past the return data.
    function description() external pure {
        assembly {
            mstore(0, 0x20)
            mstore(0x20, 1000)
            return(0, 0x40)
        }
    }

    /// @dev Tuple offset is fine, the third member's offset points past the return data.
    function getSocialMedia() external pure {
        assembly {
            mstore(0, 0x20) // tuple at 0x20
            mstore(0x20, 0x80) // farcaster at tuple + 0x80
            mstore(0x40, 0x80)
            mstore(0x60, 0xffff) // telegram: out of range
            mstore(0x80, 0x80)
            mstore(0xa0, 0) // empty string
            return(0, 0xc0)
        }
    }

    /// @dev Offset points outside the return data.
    function imageAddress() external pure {
        assembly {
            mstore(0, 0xffffffff)
            mstore(0x20, 0)
            return(0, 0x40)
        }
    }
}

/// @notice Contract whose `totalSupply` reverts: not a token as far as the Lens is concerned.
contract RevertingSupplyToken {
    function totalSupply() external pure returns (uint256) {
        revert("no supply");
    }
}

/// @notice Swap adapter stand-in: quotes `amountIn * rate` for routed assets, reverts otherwise.
contract MockQuoteAdapter {
    mapping(address asset => uint256 rate) public rateOf;

    error RouteNotSet(address asset);

    function setRate(address asset, uint256 rate) external {
        rateOf[asset] = rate;
    }

    function quote(address asset, uint256 amountIn) external view returns (uint256) {
        uint256 rate = rateOf[asset];
        if (rate == 0) revert RouteNotSet(asset);
        return amountIn * rate;
    }
}
