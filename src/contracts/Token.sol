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
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {Json} from "./utils/Json.sol";

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
    /// @dev Custom ERC-1046 URI set by an admin; empty = on-chain JSON.
    string private _tokenURI;
    /// @dev Swap fee split fixed at deployment.
    FeeInfo private _feeInfo;

    constructor(
        TokenConfig memory config,
        address creator_,
        FeeInfo memory feeInfo_
    )
        ERC20(config.name, config.symbol)
        ERC20Permit(config.name)
        Admin(config.admins)
    {
        if (
            uint256(feeInfo_.creatorPpm) + feeInfo_.vaultPpm + feeInfo_.protocolPpm !=
            feeInfo_.totalPpm
        ) revert InvalidFeeInfo();
        _feeInfo = feeInfo_;
        _imgUrl = config.imgUrl;
        _description = config.description;
        _decimals = DECIMALS;
        _creator = creator_;
        _socialMedia = config.socialMedia;

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

    /// @inheritdoc IGemoonToken
    function feeInfo() external view override returns (FeeInfo memory) {
        return _feeInfo;
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

    /// @notice ERC-1046 metadata URI. The custom URI set by an admin (`setTokenURI`) if any,
    ///         otherwise built on-chain from the current token data:
    ///         `data:application/json;base64,<json>` with
    ///         `{"name","symbol","decimals","description","image",
    ///         "socialMedia":{"farcaster","twitterX","telegram","website"},
    ///         "fees":{"totalPercent","creatorPercent","vaultPercent","protocolPercent"}}`.
    ///         Fees are JSON numbers in percent of the swap amount, up to 4 decimals (`1.25`).
    /// @dev The on-chain JSON is always in sync with `updateImage` / `changeDescription`
    /// (`UpdateImage`, `UpdateDescription` signal a change). Creator-chosen strings are
    /// JSON-escaped, so they cannot break out of their field. A custom URI is returned as is.
    /// @return Metadata URI.
    function tokenURI() external view override returns (string memory) {
        string memory custom = _tokenURI;
        if (bytes(custom).length != 0) return custom;
        return
            string.concat(
                "data:application/json;base64,",
                Base64.encode(bytes(_metadataJson()))
            );
    }

    /// @inheritdoc IGemoonToken
    function setTokenURI(string calldata uri) external override onlyAdmin {
        _tokenURI = uri;
        emit UpdateTokenURI(uri);
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

    /// @dev Metadata JSON of `tokenURI`.
    function _metadataJson() internal view returns (string memory) {
        SocialMedia memory social = _socialMedia;
        string memory socials = string.concat(
            '{"farcaster":"',
            Json.escape(social.farcaster),
            '","twitterX":"',
            Json.escape(social.twitterX),
            '","telegram":"',
            Json.escape(social.telegram),
            '","website":"',
            Json.escape(social.website),
            '"}'
        );
        return
            string.concat(
                '{"name":"',
                Json.escape(name()),
                '","symbol":"',
                Json.escape(symbol()),
                '","decimals":',
                Strings.toString(decimals()),
                ',"description":"',
                Json.escape(_description),
                '","image":"',
                Json.escape(_imgUrl),
                '","socialMedia":',
                socials,
                ',"fees":',
                _feesJson(),
                "}"
            );
    }

    /// @dev `fees` object of the metadata JSON.
    function _feesJson() internal view returns (string memory) {
        FeeInfo memory fees = _feeInfo;
        return
            string.concat(
                '{"totalPercent":',
                _percent(fees.totalPpm),
                ',"creatorPercent":',
                _percent(fees.creatorPpm),
                ',"vaultPercent":',
                _percent(fees.vaultPpm),
                ',"protocolPercent":',
                _percent(fees.protocolPpm),
                "}"
            );
    }

    /// @dev Parts per million as a JSON number in percent: 12_500 -> `1.25`, 4_166 -> `0.4166`,
    /// 10_000 -> `1`. Exact, trailing zeros of the fraction dropped.
    function _percent(uint256 ppm) internal pure returns (string memory) {
        string memory whole = Strings.toString(ppm / 10_000);
        uint256 frac = ppm % 10_000;
        if (frac == 0) return whole;

        uint256 digits = 4;
        while (frac % 10 == 0) {
            frac /= 10;
            --digits;
        }
        string memory fracStr = Strings.toString(frac);
        while (bytes(fracStr).length < digits) fracStr = string.concat("0", fracStr);
        return string.concat(whole, ".", fracStr);
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
