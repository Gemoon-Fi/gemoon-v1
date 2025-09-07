// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import "forge-std/Test.sol";
import "../src/contracts/utils/Admin.sol";

contract TestAdmin is Test {
    function testAdmin_setCorrectly() external {
        AdminConfig[] memory configs = new AdminConfig[](1);
        configs[0] = AdminConfig({admin: address(0x1), removable: false});

        Admin admin = new Admin(configs);

        assertEq(admin.getAdmins().length, 1, "Invalid admins count");
    }

    function testAdmin_replaceSuccessfull() external {
        AdminConfig[] memory configs = new AdminConfig[](1);
        configs[0] = AdminConfig({admin: address(0x1), removable: true});

        Admin admin = new Admin(configs);

        vm.prank(address(0x1));
        admin.replaceAdmin(address(0x2), address(0x1));

        assertEq(
            admin.getAdmins()[0].admin,
            address(0x2),
            "fail to change admin"
        );
    }

    function testAdmin_replaceFailBecauseAdminIsntRemovable() external {
        AdminConfig[] memory configs = new AdminConfig[](1);
        configs[0] = AdminConfig({admin: address(0x1), removable: false});

        Admin admin = new Admin(configs);

        bool reverted = false;

        vm.prank(address(0x1));

        try admin.replaceAdmin(address(0x2), address(0x1)) {} catch {
            reverted = true;
        }

        assertTrue(reverted, "revert expected");
    }

    function testAdmin_replaceFailBecauseIsntFunctionCalledByAdmin() external {
        AdminConfig[] memory configs = new AdminConfig[](1);
        configs[0] = AdminConfig({admin: address(0x1), removable: true});

        Admin admin = new Admin(configs);

        bool reverted = false;

        try admin.replaceAdmin(address(0x2), address(0x1)) {} catch {
            reverted = true;
        }

        assertTrue(reverted, "revert expected");
    }

    function testAdmin_checkAdminSuccess() external {
        AdminConfig[] memory configs = new AdminConfig[](1);
        configs[0] = AdminConfig({admin: address(0x1), removable: true});

        Admin admin = new Admin(configs);


        assertTrue(admin.isAdmin(address(0x1)), "given address is not admin");
    }

    function testAdmin_checkAdminFail() external {
        AdminConfig[] memory configs = new AdminConfig[](1);
        configs[0] = AdminConfig({admin: address(0x1), removable: true});

        Admin admin = new Admin(configs);


        assertFalse(admin.isAdmin(address(0x2)), "given address should not be an admin");
    }
}
