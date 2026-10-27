// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {LoggerTestBase} from "./helpers/LoggerTestBase.sol";
import {SiphonDataLogger} from "../src/SiphonDataLogger.sol";
import {LoggerDeployment, PrepareSiphonDeployment} from "../script/PrepareSiphonDeployment.s.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";

contract DeploymentTest is LoggerTestBase {
    IPoolManager private constant MANAGER = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    PrepareSiphonDeployment private planner;

    function setUp() public {
        planner = new PrepareSiphonDeployment();
    }

    function test_planDeploysExactReviewedBytecodeWithNamedOwner() public {
        (bytes memory code, bytes32 salt, address predicted) =
            planner.run(address(this), MANAGER, OWNER, 0, 200_000);
        assertEq(code, abi.encodePacked(type(SiphonDataLogger).creationCode, abi.encode(MANAGER, OWNER)));
        address deployed;
        assembly ("memory-safe") {
            deployed := create2(0, add(code, 32), mload(code), salt)
        }
        assertEq(deployed, predicted);
        assertGt(deployed.code.length, 0);
        assertEq(uint160(deployed) & 0x3fff, 0x1040);
        assertEq(SiphonDataLogger(deployed).owner(), OWNER);
        assertNotEq(SiphonDataLogger(deployed).owner(), address(this));
        assertEq(address(SiphonDataLogger(deployed).poolManager()), address(MANAGER));
        assertEq(SiphonDataLogger(deployed).poolCount(), 0);
        assertLt(deployed.code.length, 2000);
    }

    function test_constructorOrDeployerChangeRequiresRemining() public view {
        (bytes memory code, bytes32 salt, address predicted) =
            planner.run(address(this), MANAGER, OWNER, 0, 200_000);
        assertNotEq(LoggerDeployment.predict(address(planner), salt, keccak256(code)), predicted);
        bytes memory other = LoggerDeployment.creationCode(MANAGER, address(planner));
        assertNotEq(LoggerDeployment.predict(address(this), salt, keccak256(other)), predicted);
    }

    function test_noImplicitDeployerOwnerManagerOrUnboundedSearch() public {
        vm.expectRevert(LoggerDeployment.InvalidParameters.selector);
        planner.run(address(0), MANAGER, OWNER, 0, 1);
        vm.expectRevert(LoggerDeployment.InvalidParameters.selector);
        planner.run(address(this), IPoolManager(address(0)), OWNER, 0, 1);
        vm.expectRevert(LoggerDeployment.InvalidParameters.selector);
        planner.run(address(this), MANAGER, address(0), 0, 1);
        vm.expectRevert(LoggerDeployment.InvalidParameters.selector);
        planner.run(address(this), MANAGER, OWNER, 0, 0);
        vm.expectRevert(LoggerDeployment.InvalidParameters.selector);
        planner.run(address(this), MANAGER, OWNER, 0, 1_000_001);
    }

    function test_exhaustedSearchFailsExplicitly() public {
        bytes32 hash = keccak256(LoggerDeployment.creationCode(MANAGER, OWNER));
        uint256 start;
        while (uint160(LoggerDeployment.predict(address(this), bytes32(start), hash)) & 0x3fff == 0x1040) {
            ++start;
        }
        vm.expectRevert(LoggerDeployment.SaltNotFound.selector);
        planner.run(address(this), MANAGER, OWNER, start, 1);
    }
}
