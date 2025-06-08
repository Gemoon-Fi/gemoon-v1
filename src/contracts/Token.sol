// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.20;

import "./interfaces/IToken.sol";
import "./utils/Admin.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract GemoonToken is
    IGemoonToken,
    ERC20,
    Ownable,
    ERC20Permit,
    ERC20Burnable,
    Admin
{
    string private _imgUrl;
    string private _description;
    uint8 private _decimals;

    constructor(
        TokenConfig memory config
    )
        ERC20(config.name, config.symbol)
        ERC20Permit(config.name)
        Admin(_toAdminConfigArray(config.admins))
    {
        _imgUrl = config.imgUrl;
        _description = config.description;
        _decimals = config.decimals;

        require(config.maxSupplyTokens > 0);

        _mint(msg.sender, config.maxSupplyTokens * 10 ** uint256(_decimals));
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function imageAddress() external view override returns (string memory) {
        return _imgUrl;
    }

    function updateImage(string memory addr) external override {
        require(_isAdmin(msg.sender), "Caller is not admin");

        _imgUrl = addr;
        emit UpdateImage(addr);
    }

    function changeDescription(
        string memory desc_
    ) external override onlyOwner {
        require(_isAdmin(address(msg.sender)), "Caller is not admin");

        _description = desc_;
        emit UpdateDescription(desc_);
    }

    function description() external view override returns (string memory) {
        return _description;
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
