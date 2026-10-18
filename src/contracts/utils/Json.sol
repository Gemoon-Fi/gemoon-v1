// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice JSON helpers for on-chain metadata.
/// @dev Adapted from OpenZeppelin `Strings.escapeJSON` (master, MIT): also escapes U+0000..U+001F
/// as `\u00XX`, so the output is valid RFC 8259 for any input. OZ 5.0.2 in `lib/` has no
/// `escapeJSON` at all (added in 5.1).
library Json {
    bytes16 private constant HEX_DIGITS = "0123456789abcdef";

    uint256 private constant SPECIAL_CHARS_LOOKUP =
        0xffffffff | // first 32 bits corresponding to the control characters (U+0000 to U+001F)
            (1 << 0x22) | // double quote
            (1 << 0x5c); // backslash

    /// @notice Escapes `input` for use inside a double-quoted JSON string: `"` and `\` get a
    ///         backslash, control chars get `\b \t \n \f \r` or `\u00XX`. Bytes >= 0x20 are kept
    ///         as is, so valid UTF-8 stays valid UTF-8.
    /// @param input Raw string, e.g. a description chosen by a Meme creator.
    /// @return Escaped string, without surrounding quotes.
    function escape(string memory input) internal pure returns (string memory) {
        bytes memory buffer = bytes(input);

        // Put output at the FMP. Memory will be reserved later when we figure out the actual length of the escaped
        // string. All write are done using _unsafeWriteBytesOffset, which avoid the (expensive) length checks for
        // each character written.
        bytes memory output;
        assembly ("memory-safe") {
            output := mload(0x40)
        }
        uint256 outputLength = 0;

        for (uint256 i = 0; i < buffer.length; ++i) {
            uint8 char = uint8(bytes1(_unsafeReadBytesOffset(buffer, i)));
            if (((SPECIAL_CHARS_LOOKUP & (1 << char)) != 0)) {
                _unsafeWriteBytesOffset(output, outputLength++, "\\");
                if (char == 0x08)
                    _unsafeWriteBytesOffset(output, outputLength++, "b");
                else if (char == 0x09)
                    _unsafeWriteBytesOffset(output, outputLength++, "t");
                else if (char == 0x0a)
                    _unsafeWriteBytesOffset(output, outputLength++, "n");
                else if (char == 0x0c)
                    _unsafeWriteBytesOffset(output, outputLength++, "f");
                else if (char == 0x0d)
                    _unsafeWriteBytesOffset(output, outputLength++, "r");
                else if (char == 0x5c)
                    _unsafeWriteBytesOffset(output, outputLength++, "\\");
                else if (char == 0x22) {
                    // solhint-disable-next-line quotes
                    _unsafeWriteBytesOffset(output, outputLength++, '"');
                } else {
                    // U+0000 to U+001F without short form: output \u00XX
                    _unsafeWriteBytesOffset(output, outputLength++, "u");
                    _unsafeWriteBytesOffset(output, outputLength++, "0");
                    _unsafeWriteBytesOffset(output, outputLength++, "0");
                    _unsafeWriteBytesOffset(
                        output,
                        outputLength++,
                        HEX_DIGITS[char >> 4]
                    );
                    _unsafeWriteBytesOffset(
                        output,
                        outputLength++,
                        HEX_DIGITS[char & 0x0f]
                    );
                }
            } else {
                _unsafeWriteBytesOffset(output, outputLength++, bytes1(char));
            }
        }
        // write the actual length and reserve memory, free memory pointer kept 32-byte aligned
        assembly ("memory-safe") {
            mstore(output, outputLength)
            mstore(0x40, add(output, shl(5, shr(5, add(outputLength, 63)))))
        }

        return string(output);
    }

    /**
     * @dev Reads a bytes32 from a bytes array without bounds checking.
     *
     * NOTE: making this function internal would mean it could be used with memory unsafe offset, and marking the
     * assembly block as such would prevent some optimizations.
     */
    function _unsafeReadBytesOffset(
        bytes memory buffer,
        uint256 offset
    ) private pure returns (bytes32 value) {
        // This is not memory safe in the general case, but all calls to this private function are within bounds.
        assembly ("memory-safe") {
            value := mload(add(add(buffer, 0x20), offset))
        }
    }

    function _unsafeWriteBytesOffset(
        bytes memory buffer,
        uint256 offset,
        bytes1 value
    ) private pure {
        // This is not memory safe in the general case, but all calls to this private function are within bounds.
        assembly ("memory-safe") {
            mstore8(add(add(buffer, 0x20), offset), shr(248, value))
        }
    }
}
