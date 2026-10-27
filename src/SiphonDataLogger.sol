// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {HookFlags} from "./HookFlags.sol";

/// @notice Observes owner-configured endpoints after swaps without changing swap accounting.
/// @dev The launch admission rule additionally requires the inert afterInitialize callback.
/// Endpoints must accept exactly 0xc815641c with NO arguments. This is not the ordinary v4 StateView ABI.
contract SiphonDataLogger {
    error Unauthorized();
    error InvalidAddress();
    error InvalidHookAddress();
    error InvalidPoolCount();
    error InvalidPool();
    error PoolReadFailed(address pool);
    error InvalidSlot0(address pool);

    event PoolData(
        uint256 indexed blockNumber, uint160 sqrtPriceA, int24 tickA, uint160 sqrtPriceB, int24 tickB
    );

    IPoolManager public immutable poolManager;
    address public immutable owner;
    bool public paused;
    address[8] public pools;
    uint256 public poolCount;

    /// @dev Does not call external contracts or assume code exists at the manager address yet.
    /// Mine the final creation code with CREATE2 for address & 0x3fff == 0x1040.
    constructor(IPoolManager poolManager_, address initialOwner) {
        if (address(poolManager_) == address(0) || initialOwner == address(0)) revert InvalidAddress();
        if (!HookFlags.matches(address(this), HookFlags.LOGGER)) revert InvalidHookAddress();
        poolManager = poolManager_;
        owner = initialOwner;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert Unauthorized();
        _;
    }

    function getHookPermissions() external pure returns (Hooks.Permissions memory p) {
        p.afterInitialize = true;
        p.afterSwap = true;
    }

    /// @notice Stops logging, allowing swaps and LP fee collection to continue.
    function pause() external onlyOwner {
        paused = true;
    }

    function unpause() external onlyOwner {
        paused = false;
    }

    /// @notice Configures adjacent pairs: [A,B], [C,D], ...; at most eight distinct endpoints.
    /// @dev An empty list disables logging. No calls or extra events are produced by configuration.
    function setPools(address[] calldata newPools) external onlyOwner {
        uint256 length = newPools.length;
        if (length > 8 || length % 2 != 0) revert InvalidPoolCount();
        for (uint256 i = 0; i < length; ++i) {
            address pool = newPools[i];
            // This bounded administrative loop must reject invalid input atomically.
            // forge-lint: disable-next-line(require-revert-in-loop)
            if (pool.code.length == 0) revert InvalidPool();
            for (uint256 j = 0; j < i; ++j) {
                // forge-lint: disable-next-line(require-revert-in-loop)
                if (pool == newPools[j]) revert InvalidPool();
            }
            pools[i] = pool;
        }
        for (uint256 i = length; i < poolCount; ++i) {
            delete pools[i];
        }
        poolCount = length;
    }

    /// @notice Required by launch admission; deliberately independent of pause and pool configuration.
    function afterInitialize(address, PoolKey calldata, uint160, int24)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        return IHooks.afterInitialize.selector;
    }

    /// @notice Returns the standard v4 selector and a zero unspecified-currency delta on every success.
    /// @dev Unset or paused logging is inert. Configured invalid endpoints revert rather than emit false data.
    function afterSwap(address, PoolKey calldata, SwapParams calldata, BalanceDelta, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, int128)
    {
        if (!paused) {
            uint256 length = poolCount;
            for (uint256 i = 0; i < length;) {
                (uint160 priceA, int24 tickA) = _readSlot0(pools[i]);
                (uint160 priceB, int24 tickB) = _readSlot0(pools[i + 1]);
                // STATICCALL forbids endpoint writes/logs, and callbacks also require the manager.
                // forge-lint: disable-next-line(reentrancy-events)
                emit PoolData(block.number, priceA, tickA, priceB, tickB);
                // setPools bounds the even length to eight.
                unchecked {
                    i += 2;
                }
            }
        }
        return (IHooks.afterSwap.selector, 0);
    }

    function _readSlot0(address pool) private view returns (uint160 price, int24 tick) {
        bool ok;
        bool canonical;
        // Copy only the first two ABI words, even if an endpoint returns excessive data.
        // Temporary memory at the free pointer is discarded before returning to Solidity.
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(ptr, 0xc815641c00000000000000000000000000000000000000000000000000000000)
            ok := staticcall(gas(), pool, ptr, 4, ptr, 64)
            ok := and(ok, iszero(lt(returndatasize(), 64)))
            price := mload(ptr)
            tick := mload(add(ptr, 32))
            canonical := and(
                eq(price, and(price, 0xffffffffffffffffffffffffffffffffffffffff)),
                eq(tick, signextend(2, tick))
            )
        }
        // Each bounded read must fail atomically if it cannot supply a valid snapshot.
        // forge-lint: disable-next-line(require-revert-in-loop)
        if (!ok) revert PoolReadFailed(pool);
        // forge-lint: disable-next-line(require-revert-in-loop)
        if (!canonical) revert InvalidSlot0(pool);
    }
}
