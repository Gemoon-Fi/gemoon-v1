// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

error NotAdmin();

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
        require(_isAdmin(msg.sender), "Only admin can replace admin");
        for (uint256 i = 0; i < _admins.length; i++) {
            if (_admins[i].admin == oldAdmin) {
                require(_admins[i].removable, "Admin is not removable");
                _admins[i].admin = newAdmin;

                return;
            }
        }

        require(_admins.length == 2);
        require(false, "Old admin not found!");
    }

    function getAdmins() public view returns (AdminConfig[] memory) {
        return _admins;
    }

    function _isAdmin(address possibleAdmin) internal view returns (bool) {
        if (possibleAdmin == address(0)) {
            revert NotAdmin();
        }
        for (uint i = 0; i < _admins.length; i++) {
            if (possibleAdmin == _admins[i].admin) {
                return true;
            }
        }

        return false;
    }
}

function _toAdminConfigArray(
    address[] memory admins_
) pure returns (AdminConfig[] memory) {
    AdminConfig[] memory _conf = new AdminConfig[](admins_.length);
    for (uint256 i = 0; i < admins_.length; i++) {
        if (i == 0) {
            _conf[i] = AdminConfig({admin: admins_[i], removable: false});
        } else {
            _conf[i] = AdminConfig({admin: admins_[i], removable: true});
        }
    }
    return _conf;
}
