// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SiphonDataLogger} from "../../src/SiphonDataLogger.sol";
import {LoggerDeployment} from "../../script/PrepareSiphonDeployment.s.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";

abstract contract LoggerTestBase is Test {
    address internal constant OWNER = 0x735121A546092F31050A867FD7E3A750C7B0EFF9;
    uint160 internal constant Q96 = 79228162514264337593543950336;
    bytes32 internal constant DATA_TOPIC = keccak256("PoolData(uint256,uint160,int24,uint160,int24)");
    uint256 private nextSalt;

    function deployLogger(IPoolManager manager) internal returns (SiphonDataLogger hook) {
        bytes memory code = LoggerDeployment.creationCode(manager, OWNER);
        (bytes32 salt, address predicted) =
            LoggerDeployment.mine(address(this), keccak256(code), nextSalt, 200_000);
        nextSalt = uint256(salt) + 1;
        hook = new SiphonDataLogger{salt: salt}(manager, OWNER);
        assertEq(address(hook), predicted);
        assertEq(uint160(address(hook)) & 0x3fff, 0x1040);
    }

    function pair(address a, address b) internal pure returns (address[] memory result) {
        result = new address[](2);
        result[0] = a;
        result[1] = b;
    }

    function configure(SiphonDataLogger hook, address a, address b) internal {
        address[] memory endpoints = pair(a, b);
        vm.prank(OWNER);
        hook.setPools(endpoints);
    }
}
