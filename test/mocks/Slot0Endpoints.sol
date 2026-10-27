// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";

/// @dev Test-only endpoint implementing the exact four-byte ABI from the brief.
contract Slot0Endpoint {
    bytes private response;
    bool private fails;

    constructor(uint160 price, int24 tick) {
        response = abi.encode(price, tick);
    }

    function setResponse(bytes memory value) external {
        response = value;
    }

    function setFails(bool value) external {
        fails = value;
    }

    fallback(bytes calldata input) external returns (bytes memory) {
        require(input.length == 4 && bytes4(input) == 0xc815641c, "unexpected calldata");
        require(!fails, "endpoint unavailable");
        return response;
    }
}

/// @dev This mock attempts a write. The hook's STATICCALL must make it fail.
contract WritingEndpoint {
    uint256 public writes;

    fallback(bytes calldata) external returns (bytes memory) {
        ++writes;
        return abi.encode(uint160(1), int24(0));
    }
}

/// @dev Test-only bridge to REAL local v4 state. It is NOT a verified Robinhood deployment or pool.
contract LocalPoolEndpoint {
    using StateLibrary for IPoolManager;
    IPoolManager private immutable manager;
    PoolId private immutable poolId;

    constructor(IPoolManager manager_, PoolId poolId_) {
        manager = manager_;
        poolId = poolId_;
    }

    fallback(bytes calldata input) external returns (bytes memory) {
        require(input.length == 4 && bytes4(input) == 0xc815641c, "unexpected calldata");
        (uint160 price, int24 tick,,) = manager.getSlot0(poolId);
        return abi.encode(price, tick);
    }
}

/// @dev Standard v4 StateView-shaped ABI: the required argument cannot be omitted.
contract StandardStateViewEndpoint {
    function getSlot0(bytes32) external pure returns (uint160, int24, uint24, uint24) {
        return (1, 0, 0, 5000);
    }
}
