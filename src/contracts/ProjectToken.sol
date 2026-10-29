// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC1046} from "./interfaces/IERC1046.sol";

/// @title Project token.
/// @notice Standalone ERC-20 of the project, deployed directly, not through the controller.
///         A copy of `GemoonToken` without the fee split and the admin list, where `tokenURI()`
///         is a plain stored link (`https://...`, `ipfs://...`) instead of on-chain base64 JSON.
/// @dev The whole fixed supply (1 000 000 000, 18 decimals) is minted to the deployer at
/// construction; there is no other mint. The owner (Ownable2Step) only manages metadata:
/// the token URI, the image link and the description. Ownership grants no control over balances.
contract ProjectToken is IERC1046, ERC20, ERC20Permit, ERC20Burnable, ERC165, Ownable2Step {
    /// @notice Whole supply minted at construction, in raw units.
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 * 1e18;

    /// @dev ERC-1046 metadata URI returned by `tokenURI()` as is.
    string private _tokenURI;
    /// @dev Image link.
    string private _imgUrl;
    /// @dev Free-form description.
    string private _description;
    /// @dev Number of addresses with a non-zero balance, kept by `_update`.
    uint256 private _holders;

    /// @notice Token URI changed.
    event UpdateTokenURI(string newTokenURI);
    /// @notice Image link changed.
    event UpdateImage(string newAddress);
    /// @notice Description changed.
    event UpdateDescription(string newDescription);

    /// @param name_        ERC-20 name.
    /// @param symbol_      ERC-20 symbol.
    /// @param tokenURI_    Initial metadata URI, may be empty.
    /// @param owner_       Owner allowed to change the metadata.
    constructor(
        string memory name_,
        string memory symbol_,
        string memory tokenURI_,
        address owner_
    ) ERC20(name_, symbol_) ERC20Permit(name_) Ownable(owner_) {
        _tokenURI = tokenURI_;
        emit UpdateTokenURI(tokenURI_);
        _mint(msg.sender, TOTAL_SUPPLY);
    }

    /// @notice ERC-1046 metadata URI: the link set by the owner, returned as is.
    /// @return Metadata URI, empty until set.
    function tokenURI() external view override returns (string memory) {
        return _tokenURI;
    }

    /// @notice Sets the metadata URI returned by `tokenURI()`. Only owner.
    /// @param uri New metadata URI (e.g. `https://...`, `ipfs://...`), empty clears it.
    function setTokenURI(string calldata uri) external onlyOwner {
        _tokenURI = uri;
        emit UpdateTokenURI(uri);
    }

    /// @notice Image link.
    /// @return Current image link.
    function imageAddress() external view returns (string memory) {
        return _imgUrl;
    }

    /// @notice Sets the image link. Only owner.
    /// @param addr New image link.
    function updateImage(string calldata addr) external onlyOwner {
        _imgUrl = addr;
        emit UpdateImage(addr);
    }

    /// @notice Description.
    /// @return Current description.
    function description() external view returns (string memory) {
        return _description;
    }

    /// @notice Sets the description. Only owner.
    /// @param desc_ New description.
    function changeDescription(string calldata desc_) external onlyOwner {
        _description = desc_;
        emit UpdateDescription(desc_);
    }

    /// @notice Number of addresses holding a non-zero balance, contracts included.
    /// @return Current holder count.
    function totalHolders() external view returns (uint256) {
        return _holders;
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) public view override returns (bool) {
        return
            interfaceId == type(IERC1046).interfaceId ||
            interfaceId == type(IERC20).interfaceId ||
            interfaceId == type(IERC20Metadata).interfaceId ||
            super.supportsInterface(interfaceId);
    }

    /// @dev Keeps `_holders` in sync with every mint, transfer and burn, same as `GemoonToken`.
    function _update(address from, address to, uint256 value) internal override {
        uint256 toBalanceBefore = to == address(0) ? 0 : balanceOf(to);
        super._update(from, to, value);
        if (value == 0 || from == to) return;

        // value > 0 left `from`, so it held a non-zero balance before: no underflow.
        if (from != address(0) && balanceOf(from) == 0) --_holders;
        if (to != address(0) && toBalanceBefore == 0) ++_holders;
    }
}
