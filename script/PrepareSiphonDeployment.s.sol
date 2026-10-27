// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SiphonDataLogger} from "../src/SiphonDataLogger.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";

/// @notice Offline deployment preparation. Does not broadcast, read keys, or assume a factory address.
library LoggerDeployment {
    error SaltNotFound();
    error InvalidParameters();

    function creationCode(IPoolManager manager, address owner) internal pure returns (bytes memory) {
        if (address(manager) == address(0) || owner == address(0)) revert InvalidParameters();
        return abi.encodePacked(type(SiphonDataLogger).creationCode, abi.encode(manager, owner));
    }

    function predict(address deployer, bytes32 salt, bytes32 initCodeHash) internal pure returns (address) {
        return
            address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, initCodeHash)))));
    }

    function mine(address deployer, bytes32 initCodeHash, uint256 start, uint256 attempts)
        internal
        pure
        returns (bytes32 salt, address predicted)
    {
        if (deployer == address(0) || attempts == 0 || attempts > 1_000_000) revert InvalidParameters();
        for (uint256 i = 0; i < attempts; ++i) {
            salt = bytes32(start + i);
            predicted = predict(deployer, salt, initCodeHash);
            if (HookFlags.matches(predicted, HookFlags.LOGGER)) return (salt, predicted);
        }
        revert SaltNotFound();
    }
}

contract PrepareSiphonDeployment {
    /// @notice Supply the ACTUAL CREATE2 deployer and final constructor parameters before mining.
    function run(address deployer, IPoolManager manager, address owner, uint256 start, uint256 attempts)
        external
        pure
        returns (bytes memory initCode, bytes32 salt, address predicted)
    {
        initCode = LoggerDeployment.creationCode(manager, owner);
        (salt, predicted) = LoggerDeployment.mine(deployer, keccak256(initCode), start, attempts);
    }
}
