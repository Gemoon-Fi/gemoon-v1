// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

error NotAdmin(string msg);
error ZeroAddress(string msg);

struct AdminConfig {
    address admin;
    bool removable;
}

contract Admin {
    AdminConfig[] private _admins;

    constructor(AdminConfig[] memory admins_) {
        _admins = admins_;
    }

    function replaceAdmin(address newAdmin, address oldAdmin) public {
        require(
            newAdmin != address(0) && oldAdmin != address(0),
            "newAdmin and oldAdmin must be valid address!"
        );

        if (!_isAdmin(msg.sender)) {
            revert NotAdmin("Only admin can replace admin");
        }

        for (uint256 i = 0; i < _admins.length; i++) {
            if (_admins[i].admin == oldAdmin) {
                require(_admins[i].removable, "Admin is not removable!");
                _admins[i].admin = newAdmin;

                return;
            }
        }
    }

    function isAdmin(address possibleAdmin) public view returns (bool) {
        return _isAdmin(possibleAdmin);
    }

    function getAdmins() public view returns (AdminConfig[] memory) {
        return _admins;
    }

    function _isAdmin(address possibleAdmin) internal view returns (bool) {
        if (possibleAdmin == address(0)) {
            revert ZeroAddress("Zero address cant be admin!");
        }
        for (uint i = 0; i < _admins.length; i++) {
            if (possibleAdmin == _admins[i].admin) {
                return true;
            }
        }

        return false;
    }
}
