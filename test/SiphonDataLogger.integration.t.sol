// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm, VmSafe} from "forge-std/Vm.sol";
import {LoggerTestBase} from "./helpers/LoggerTestBase.sol";
import {LocalPoolEndpoint, Slot0Endpoint} from "./mocks/Slot0Endpoints.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {Swapper} from "./mocks/Swapper.sol";
import {SiphonDataLogger} from "../src/SiphonDataLogger.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";

contract SiphonDataLoggerIntegrationTest is LoggerTestBase {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    bytes32 private constant SWAP_TOPIC =
        keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");
    IPoolManager private manager;
    SiphonDataLogger private hook;
    MockERC20 private token0;
    MockERC20 private token1;
    Swapper private trader;
    PoolKey private poolA;
    PoolKey private poolB;
    LocalPoolEndpoint private endpointA;
    LocalPoolEndpoint private endpointB;

    function setUp() public {
        manager = IPoolManager(address(new PoolManager(address(this))));
        hook = deployLogger(manager);
        MockERC20 first = new MockERC20("Local A", "A", 1000 ether);
        MockERC20 second = new MockERC20("Local B", "B", 1000 ether);
        (token0, token1) = address(first) < address(second) ? (first, second) : (second, first);
        poolA = PoolKey(
            Currency.wrap(address(token0)), Currency.wrap(address(token1)), 5000, 100, IHooks(address(0))
        );
        poolB = PoolKey(
            Currency.wrap(address(token0)), Currency.wrap(address(token1)), 5000, 100, IHooks(address(hook))
        );
        manager.initialize(poolA, Q96);
        manager.initialize(poolB, Q96);
        trader = new Swapper(manager);
        token0.transfer(address(trader), 500 ether);
        token1.transfer(address(trader), 500 ether);
        trader.modify(poolA, -887200, 887200, 1 ether);
        trader.modify(poolB, -887200, 887200, 1 ether);
        endpointA = new LocalPoolEndpoint(manager, poolA.toId());
        endpointB = new LocalPoolEndpoint(manager, poolB.toId());
        configure(hook, address(endpointA), address(endpointB));
    }

    function test_onePointZeroZeroOneSwapEmitsActualStateAndNoExtraSwaps() public {
        vm.roll(123456);
        (uint160 beforeB,,,) = manager.getSlot0(poolB.toId());
        uint256 before0 = token0.balanceOf(address(trader));
        uint256 before1 = token1.balanceOf(address(trader));
        vm.startStateDiffRecording();
        vm.recordLogs();
        BalanceDelta delta = trader.swap(poolB, false, 0.001 ether);
        Vm.AccountAccess[] memory accesses = vm.stopAndReturnStateDiff();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(delta.amount1(), -int128(0.001 ether));
        assertGt(delta.amount0(), 0);
        assertEq(token1.balanceOf(address(trader)), before1 - 0.001 ether);
        assertEq(token0.balanceOf(address(trader)), before0 + uint128(delta.amount0()));
        (uint160 afterB,,,) = manager.getSlot0(poolB.toId());
        assertGt(afterB, beforeB);
        assertRealSnapshot(logs, poolB);

        uint256 swaps;
        uint256 reads;
        for (uint256 i = 0; i < accesses.length; ++i) {
            Vm.AccountAccess memory access = accesses[i];
            if (
                access.kind == VmSafe.AccountAccessKind.Call && access.account == address(manager)
                    && bytes4(access.data) == IPoolManager.swap.selector
            ) ++swaps;
            if (access.accessor == address(hook) && access.kind != VmSafe.AccountAccessKind.Resume) {
                assertTrue(access.kind == VmSafe.AccountAccessKind.StaticCall);
                assertEq(access.account, reads == 0 ? address(endpointA) : address(endpointB));
                assertEq(access.data, hex"c815641c");
                ++reads;
            }
        }
        assertEq(swaps, 1);
        assertEq(reads, 2);
        assertSettled();
        assertEq(manager.getLiquidity(poolB.toId()), 1 ether);
    }

    function testFuzz_exactInputOrOutputBothDirectionsPreserveAccounting(
        bool zeroForOne,
        bool exactOutput,
        uint96 rawAmount
    ) public {
        uint256 amount = bound(rawAmount, 1e12, 0.01 ether);
        uint256 before0 = token0.balanceOf(address(trader));
        uint256 before1 = token1.balanceOf(address(trader));
        vm.recordLogs();
        BalanceDelta delta =
            trader.swapSpecified(poolB, zeroForOne, exactOutput ? int256(amount) : -int256(amount));
        assertEq(int256(token0.balanceOf(address(trader))) - int256(before0), int256(delta.amount0()));
        assertEq(int256(token1.balanceOf(address(trader))) - int256(before1), int256(delta.amount1()));
        if (exactOutput) assertEq(zeroForOne ? delta.amount1() : delta.amount0(), int256(amount));
        else assertEq(zeroForOne ? delta.amount0() : delta.amount1(), -int256(amount));
        assertRealSnapshot(vm.getRecordedLogs(), poolB);
        assertSettled();
    }

    function test_eachSwapReadsFreshPoolAAndPoolBState() public {
        trader.swap(poolA, true, 0.002 ether);
        vm.recordLogs();
        trader.swap(poolB, true, 0.001 ether);
        assertRealSnapshot(vm.getRecordedLogs(), poolB);
        trader.swap(poolA, false, 0.003 ether);
        vm.roll(vm.getBlockNumber() + 1);
        trader.swap(poolB, false, 0.001 ether);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        // Includes the separate unhooked pool A swap; isolate B's own call below.
        uint256 snapshots;
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter == address(hook)) ++snapshots;
        }
        assertEq(snapshots, 1);
        vm.recordLogs();
        trader.swap(poolB, false, 0.001 ether);
        assertRealSnapshot(vm.getRecordedLogs(), poolB);
    }

    function test_invalidReadRollsBackSwapAndOwnerCanRestoreLiveness() public {
        Slot0Endpoint broken = new Slot0Endpoint(Q96, 0);
        broken.setFails(true);
        configure(hook, address(endpointA), address(broken));
        (uint160 beforePrice, int24 beforeTick,,) = manager.getSlot0(poolB.toId());
        uint256 before0 = token0.balanceOf(address(trader));
        uint256 before1 = token1.balanceOf(address(trader));
        vm.expectRevert(); // PoolManager wraps the endpoint failure with hook context.
        trader.swap(poolB, false, 0.001 ether);
        (uint160 price, int24 tick,,) = manager.getSlot0(poolB.toId());
        assertEq(price, beforePrice);
        assertEq(tick, beforeTick);
        assertEq(token0.balanceOf(address(trader)), before0);
        assertEq(token1.balanceOf(address(trader)), before1);
        vm.prank(OWNER);
        hook.pause();
        vm.recordLogs();
        trader.swap(poolB, false, 0.001 ether);
        assertNoHookEvents(vm.getRecordedLogs());
        configure(hook, address(endpointA), address(endpointB));
        vm.prank(OWNER);
        hook.unpause();
        trader.swap(poolB, true, 0.001 ether);
        assertRealSnapshot(vm.getRecordedLogs(), poolB);
    }

    function test_unconfiguredHookTradesImmediatelyAndCanBeConfiguredLater() public {
        vm.prank(OWNER);
        hook.setPools(new address[](0));
        vm.recordLogs();
        trader.swap(poolB, true, 0.001 ether);
        assertNoHookEvents(vm.getRecordedLogs());
        configure(hook, address(endpointA), address(endpointB));
        trader.swap(poolB, false, 0.001 ether);
        assertRealSnapshot(vm.getRecordedLogs(), poolB);
    }

    function testFuzz_factoryCollectAndUnwindRemainAvailableInEveryLoggingState(uint8 rawMode) public {
        uint256 mode = bound(rawMode, 0, 3);
        trader.swap(poolB, true, 0.001 ether);
        trader.swap(poolB, false, 0.001 ether);
        if (mode == 1) {
            vm.prank(OWNER);
            hook.setPools(new address[](0));
        } else if (mode == 2) {
            vm.prank(OWNER);
            hook.pause();
        } else if (mode == 3) {
            Slot0Endpoint broken = new Slot0Endpoint(Q96, 0);
            broken.setFails(true);
            configure(hook, address(endpointA), address(broken));
        }
        vm.recordLogs();
        BalanceDelta fees = trader.modify(poolB, -887200, 887200, 0);
        assertGt(fees.amount0(), 0);
        assertGt(fees.amount1(), 0);
        assertNoHookEvents(vm.getRecordedLogs());
        BalanceDelta withdrawn = trader.modify(poolB, -887200, 887200, -int256(1 ether));
        assertGt(withdrawn.amount0(), 0);
        assertGt(withdrawn.amount1(), 0);
        assertEq(manager.getLiquidity(poolB.toId()), 0);
        assertSettled();
    }

    function test_initializeAcceptsNetworkFeeAndWorksWhilePaused() public {
        PoolKey memory launch = poolB;
        launch.fee = 12500;
        vm.prank(OWNER);
        hook.pause();
        vm.recordLogs();
        manager.initialize(launch, Q96);
        assertNoHookEvents(vm.getRecordedLogs());
        (uint160 price,,, uint24 fee) = manager.getSlot0(launch.toId());
        assertEq(price, Q96);
        assertEq(fee, 12500);
        trader.modify(launch, -887200, 887200, 1 ether);
        trader.swap(launch, true, 0.001 ether);
        trader.modify(launch, -887200, 887200, 0);
    }

    function test_nativeEthPoolLocalOnly() public {
        // Native ETH has v4's real native-currency encoding, not the brief's nonzero token address.
        PoolKey memory nativePool = PoolKey(
            Currency.wrap(address(0)), Currency.wrap(address(token0)), 5000, 100, IHooks(address(hook))
        );
        manager.initialize(nativePool, Q96);
        vm.deal(address(trader), 5 ether);
        trader.modify(nativePool, -887200, 887200, 1 ether);
        LocalPoolEndpoint nativeEndpoint = new LocalPoolEndpoint(manager, nativePool.toId());
        configure(hook, address(endpointA), address(nativeEndpoint));
        vm.recordLogs();
        BalanceDelta delta = trader.swap(nativePool, true, 0.001 ether);
        assertEq(delta.amount0(), -int128(0.001 ether));
        assertGt(delta.amount1(), 0);
        assertRealSnapshot(vm.getRecordedLogs(), nativePool);
        assertEq(address(hook).balance, 0);
    }

    function assertRealSnapshot(Vm.Log[] memory logs, PoolKey memory swappedPool) private view {
        (uint160 priceA, int24 tickA,,) = manager.getSlot0(poolA.toId());
        (uint160 priceB, int24 tickB,,) = manager.getSlot0(swappedPool.toId());
        uint256 snapshots;
        uint256 swaps;
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter == address(hook)) {
                ++snapshots;
                assertEq(logs[i].topics.length, 2);
                assertEq(logs[i].topics[0], DATA_TOPIC);
                assertEq(uint256(logs[i].topics[1]), vm.getBlockNumber());
                assertEq(logs[i].data, abi.encode(priceA, tickA, priceB, tickB));
            }
            if (logs[i].emitter == address(manager) && logs[i].topics[0] == SWAP_TOPIC) {
                ++swaps;
                assertEq(logs[i].topics[1], PoolId.unwrap(swappedPool.toId()));
            }
        }
        assertEq(snapshots, 1);
        assertEq(swaps, 1);
    }

    function assertNoHookEvents(Vm.Log[] memory logs) private view {
        for (uint256 i = 0; i < logs.length; ++i) {
            assertNotEq(logs[i].emitter, address(hook));
        }
    }

    function assertSettled() private view {
        assertEq(manager.currencyDelta(address(hook), poolB.currency0), 0);
        assertEq(manager.currencyDelta(address(hook), poolB.currency1), 0);
        assertEq(manager.currencyDelta(address(trader), poolB.currency0), 0);
        assertEq(manager.currencyDelta(address(trader), poolB.currency1), 0);
        assertEq(token0.balanceOf(address(hook)), 0);
        assertEq(token1.balanceOf(address(hook)), 0);
        assertEq(address(hook).balance, 0);
    }
}
