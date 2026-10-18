// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.20;

import "./interfaces/IToken.sol";
import "./utils/Admin.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC1046} from "./interfaces/IERC1046.sol";

contract GemoonToken is
    IGemoonToken,
    ERC20,
    ERC20Permit,
    ERC20Burnable,
    ERC165,
    Admin
{
    string private _imgUrl;
    string private _description;
    uint8 private _decimals;
    address private _creator;
    SocialMedia private _socialMedia;
    /// @dev Number of addresses with a non-zero balance, kept by `_update`.
    uint256 private _holders;
    /// @dev ERC-1046 metadata URI.
    string private _tokenURI;

    constructor(
        TokenConfig memory config,
        address creator_
    )
        ERC20(config.name, config.symbol)
        ERC20Permit(config.name)
        Admin(config.admins)
    {
        _imgUrl = config.imgUrl;
        _description = config.description;
        _decimals = DECIMALS;
        _creator = creator_;
        _socialMedia = config.socialMedia;
        _setTokenURI(config.tokenURI);

        /// @notice Minting the maximum supply of tokens to the deployer.
        _mint(msg.sender, 1_000_000_000 * 10 ** uint256(_decimals));
    }

    /// @notice Number of addresses holding a non-zero balance of this token.
    /// @dev Every address counts, contracts included (PoolManager, controller dust, vault stakes).
    /// @return Current holder count.
    function totalHolders() external view returns (uint256) {
        return _holders;
    }

    /// @dev Keeps `_holders` in sync with every mint, transfer and burn: an address joins when its
    /// balance goes from zero to non-zero and leaves when it drops back to zero. Zero-value and
    /// self transfers change no balance and are skipped. The zero address (mint source, burn sink)
    /// never counts.
    function _update(
        address from,
        address to,
        uint256 value
    ) internal override {
        uint256 toBalanceBefore = to == address(0) ? 0 : balanceOf(to);
        super._update(from, to, value);
        if (value == 0 || from == to) return;

        // value > 0 left `from`, so it held a non-zero balance before: no underflow.
        if (from != address(0) && balanceOf(from) == 0) --_holders;
        if (to != address(0) && toBalanceBefore == 0) ++_holders;
    }

    function creator() external view override returns (address) {
        return _creator;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function imageAddress() external view override returns (string memory) {
        return _imgUrl;
    }

    modifier onlyAdmin() {
        require(_isAdmin(msg.sender), "Caller is not an admin");
        _;
    }

    function updateImage(string memory addr) external override onlyAdmin {
        _imgUrl = addr;
        emit UpdateImage(addr);
    }

    /// @inheritdoc IERC1046
    function tokenURI() external view override returns (string memory) {
        return _tokenURI;
    }

    /// @inheritdoc IGemoonToken
    function setTokenURI(string calldata uri) external override onlyAdmin {
        _setTokenURI(uri);
    }

    /// @inheritdoc IERC165
    function supportsInterface(
        bytes4 interfaceId
    ) public view override returns (bool) {
        return
            interfaceId == type(IERC1046).interfaceId ||
            interfaceId == type(IERC20).interfaceId ||
            interfaceId == type(IERC20Metadata).interfaceId ||
            super.supportsInterface(interfaceId);
    }

    function changeDescription(
        string memory desc_
    ) external override onlyAdmin {
        _description = desc_;
        emit UpdateDescription(desc_);
    }

    function description() external view override returns (string memory) {
        return _description;
    }

    function getSocialMedia() external view returns (SocialMedia memory) {
        return _socialMedia;
    }

    function _setTokenURI(string memory uri) internal {
        uint256 length = bytes(uri).length;
        if (length > MAX_TOKEN_URI_LENGTH)
            revert TokenURITooLong(length, MAX_TOKEN_URI_LENGTH);
        _tokenURI = uri;
        emit UpdateTokenURI(uri);
    }

    function showAdmins() public view override returns (address[] memory) {
        AdminConfig[] memory admConfigs_ = Admin.getAdmins();
        address[] memory admins_ = new address[](admConfigs_.length);

        for (uint256 i = 0; i < admConfigs_.length; i++) {
            admins_[i] = admConfigs_[i].admin;
        }

        return admins_;
    }
}
