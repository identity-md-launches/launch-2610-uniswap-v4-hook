// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm, VmSafe} from "forge-std/Vm.sol";
import {LoggerTestBase} from "./helpers/LoggerTestBase.sol";
import {Slot0Endpoint, WritingEndpoint, StandardStateViewEndpoint} from "./mocks/Slot0Endpoints.sol";
import {SiphonDataLogger} from "../src/SiphonDataLogger.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {LoggerDeployment} from "../script/PrepareSiphonDeployment.s.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";

contract SiphonDataLoggerTest is LoggerTestBase {
    SiphonDataLogger internal hook;
    Slot0Endpoint internal a;
    Slot0Endpoint internal b;
    address internal manager;
    PoolKey internal key;
    SwapParams internal params;

    function setUp() public {
        manager = makeAddr("unit test manager");
        hook = deployLogger(IPoolManager(manager));
        a = new Slot0Endpoint(Q96, -100);
        b = new Slot0Endpoint(Q96 + 100, 200);
        configure(hook, address(a), address(b));
    }

    function invoke() internal returns (bytes4 selector, int128 delta) {
        vm.prank(manager);
        return hook.afterSwap(address(this), key, params, BalanceDelta.wrap(0), "");
    }

    function test_permissionsMatchAddressAndLaunchAdmission() public view {
        Hooks.Permissions memory p = hook.getHookPermissions();
        assertTrue(p.afterInitialize);
        assertTrue(p.afterSwap);
        assertFalse(p.beforeInitialize);
        assertFalse(p.beforeAddLiquidity);
        assertFalse(p.afterAddLiquidity);
        assertFalse(p.beforeRemoveLiquidity);
        assertFalse(p.afterRemoveLiquidity);
        assertFalse(p.beforeSwap);
        assertFalse(p.beforeDonate);
        assertFalse(p.afterDonate);
        assertFalse(p.beforeSwapReturnDelta);
        assertFalse(p.afterSwapReturnDelta);
        assertFalse(p.afterAddLiquidityReturnDelta);
        assertFalse(p.afterRemoveLiquidityReturnDelta);
        assertEq(HookFlags.flagsOf(address(hook)), HookFlags.LOGGER);
        assertEq(address(hook.poolManager()), manager);
        assertEq(hook.owner(), OWNER);
        assertNotEq(hook.owner(), address(this));
        assertFalse(hook.paused());
    }

    function test_underTwoThousandBytesAndNoForbiddenOpcodes() public view {
        bytes memory code = address(hook).code;
        assertLt(code.length, 2000);
        uint256 staticCalls;
        bool reachable = true;
        for (uint256 i = 0; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op == 0x5b) reachable = true;
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            if (reachable) {
                assertTrue(op != 0x5c && op != 0x5d, "transient storage opcode");
                assertTrue(op != 0xf1 && op != 0xf2 && op != 0xf4, "non-static external call");
                assertTrue(op != 0xf0 && op != 0xf5 && op != 0xff, "creation or selfdestruct");
                if (op == 0xfa) ++staticCalls;
            }
            if (op == 0x00 || op == 0x56 || op == 0xf3 || op == 0xfd || op == 0xfe) reachable = false;
        }
        assertGt(staticCalls, 0);
    }

    function test_rejectsWrongDeploymentBits() public {
        bytes32 hash = keccak256(LoggerDeployment.creationCode(IPoolManager(manager), OWNER));
        uint256 salt;
        while (HookFlags.matches(
                LoggerDeployment.predict(address(this), bytes32(salt), hash), HookFlags.LOGGER
            )) {
            ++salt;
        }
        vm.expectRevert(SiphonDataLogger.InvalidHookAddress.selector);
        new SiphonDataLogger{salt: bytes32(salt)}(IPoolManager(manager), OWNER);
    }

    function test_constructorRejectsZeroManagerOrOwner() public {
        vm.expectRevert(SiphonDataLogger.InvalidAddress.selector);
        new SiphonDataLogger(IPoolManager(address(0)), OWNER);
        vm.expectRevert(SiphonDataLogger.InvalidAddress.selector);
        new SiphonDataLogger(IPoolManager(manager), address(0));
    }

    function test_constructorNeedsNoExternalCodeOrPoolSetting() public {
        // The manager deliberately has no code in unit tests, as on an empty launch probe chain.
        assertEq(manager.code.length, 0);
        vm.recordLogs();
        SiphonDataLogger fresh = deployLogger(IPoolManager(manager));
        assertEq(vm.getRecordedLogs().length, 0);
        assertEq(fresh.poolCount(), 0);
        vm.prank(manager);
        (bytes4 selector, int128 delta) =
            fresh.afterSwap(address(this), key, params, BalanceDelta.wrap(0), "");
        assertEq(selector, IHooks.afterSwap.selector);
        assertEq(delta, 0);
    }

    function testFuzz_onlyOwnerControlsConfigurationAndPause(address caller) public {
        vm.assume(caller != OWNER);
        address[] memory endpoints = pair(address(b), address(a));
        vm.startPrank(caller);
        vm.expectRevert(SiphonDataLogger.Unauthorized.selector);
        hook.setPools(endpoints);
        vm.expectRevert(SiphonDataLogger.Unauthorized.selector);
        hook.pause();
        vm.expectRevert(SiphonDataLogger.Unauthorized.selector);
        hook.unpause();
        vm.stopPrank();
        assertFalse(hook.paused());
        assertEq(hook.pools(0), address(a));
    }

    function testFuzz_bothCallbacksRefuseNonManagerEvenWhenPaused(address caller) public {
        vm.assume(caller != manager);
        vm.prank(OWNER);
        hook.pause();
        vm.startPrank(caller);
        vm.expectRevert(SiphonDataLogger.Unauthorized.selector);
        hook.afterInitialize(manager, key, Q96, 0);
        vm.expectRevert(SiphonDataLogger.Unauthorized.selector);
        hook.afterSwap(manager, key, params, BalanceDelta.wrap(0), "");
        vm.stopPrank();
    }

    function test_initCallbackIsInertWhilePausedAndUnconfigured() public {
        vm.startPrank(OWNER);
        hook.setPools(new address[](0));
        hook.pause();
        vm.stopPrank();
        vm.recordLogs();
        vm.record();
        vm.prank(manager);
        assertEq(hook.afterInitialize(address(this), key, Q96, 0), IHooks.afterInitialize.selector);
        assertEq(vm.getRecordedLogs().length, 0);
        (, bytes32[] memory writes) = vm.accesses(address(hook));
        assertEq(writes.length, 0);
    }

    function test_exactTwoStaticCallsOneEventNoWritesAndZeroDelta() public {
        vm.roll(123456);
        vm.expectCall(address(a), hex"c815641c", uint64(1));
        vm.expectCall(address(b), hex"c815641c", uint64(1));
        vm.recordLogs();
        vm.record();
        vm.startStateDiffRecording();
        (bytes4 selector, int128 delta) = invoke();
        Vm.AccountAccess[] memory accesses = vm.stopAndReturnStateDiff();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        (, bytes32[] memory writes) = vm.accesses(address(hook));
        assertEq(writes.length, 0);
        assertEq(selector, IHooks.afterSwap.selector);
        assertEq(delta, 0);
        assertEq(logs.length, 1);
        assertSnapshot(logs[0], Q96, -100, Q96 + 100, 200);
        uint256 calls;
        for (uint256 i = 0; i < accesses.length; ++i) {
            Vm.AccountAccess memory access = accesses[i];
            if (access.accessor != address(hook) || access.kind == VmSafe.AccountAccessKind.Resume) continue;
            assertTrue(access.kind == VmSafe.AccountAccessKind.StaticCall, "unexpected hook interaction");
            assertEq(access.account, calls == 0 ? address(a) : address(b));
            assertEq(access.data, hex"c815641c");
            assertEq(access.value, 0);
            ++calls;
        }
        assertEq(calls, 2);
    }

    function testFuzz_preservesFullABIValueRanges(uint160 priceA, int24 tickA, uint160 priceB, int24 tickB)
        public
    {
        a.setResponse(abi.encode(priceA, tickA));
        b.setResponse(abi.encode(priceB, tickB));
        vm.recordLogs();
        invoke();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertSnapshot(logs[0], priceA, tickA, priceB, tickB);
    }

    function test_fullTypeBoundariesAndNegativeTickSignExtension() public {
        a.setResponse(abi.encode(type(uint160).max, type(int24).min));
        b.setResponse(abi.encode(uint160(0), type(int24).max));
        vm.recordLogs();
        invoke();
        assertSnapshot(vm.getRecordedLogs()[0], type(uint160).max, type(int24).min, 0, type(int24).max);
    }

    function test_trailingDataIsIgnoredWithoutCopyingItAll() public {
        a.setResponse(bytes.concat(abi.encode(Q96, int24(-100)), new bytes(65536)));
        vm.recordLogs();
        invoke();
        assertSnapshot(vm.getRecordedLogs()[0], Q96, -100, Q96 + 100, 200);
    }

    function test_pauseUnpauseAndSetPoolsEmitNoAdministrativeEvents() public {
        address[] memory endpoints = pair(address(b), address(a));
        vm.recordLogs();
        vm.startPrank(OWNER);
        hook.pause();
        hook.pause();
        hook.setPools(endpoints);
        hook.unpause();
        hook.unpause();
        vm.stopPrank();
        assertEq(vm.getRecordedLogs().length, 0);
        invoke();
        assertSnapshot(vm.getRecordedLogs()[0], Q96 + 100, 200, Q96, -100);
    }

    function test_pausedSkipsBrokenEndpointsAndResumesAfterRepair() public {
        a.setFails(true);
        vm.prank(OWNER);
        hook.pause();
        vm.recordLogs();
        vm.startStateDiffRecording();
        (bytes4 selector, int128 delta) = invoke();
        Vm.AccountAccess[] memory accesses = vm.stopAndReturnStateDiff();
        assertEq(selector, IHooks.afterSwap.selector);
        assertEq(delta, 0);
        assertEq(vm.getRecordedLogs().length, 0);
        for (uint256 i = 0; i < accesses.length; ++i) {
            assertFalse(accesses[i].accessor == address(hook), "paused hook called an endpoint");
        }
        a.setFails(false);
        vm.prank(OWNER);
        hook.unpause();
        invoke();
        assertEq(vm.getRecordedLogs().length, 1);
    }

    function test_clearConfigurationIsInertAndClearsStaleAddresses() public {
        vm.prank(OWNER);
        hook.setPools(new address[](0));
        assertEq(hook.poolCount(), 0);
        assertEq(hook.pools(0), address(0));
        assertEq(hook.pools(1), address(0));
        vm.recordLogs();
        (bytes4 selector, int128 delta) = invoke();
        assertEq(selector, IHooks.afterSwap.selector);
        assertEq(delta, 0);
        assertEq(vm.getRecordedLogs().length, 0);
    }

    function test_eightEndpointsProduceFourOrderedPairsThenCanShrink() public {
        address[] memory endpoints = new address[](8);
        for (uint256 i = 0; i < 8; ++i) {
            endpoints[i] = address(new Slot0Endpoint(uint160(i + 1), -int24(int256(i))));
            vm.expectCall(endpoints[i], hex"c815641c", uint64(1));
        }
        vm.prank(OWNER);
        hook.setPools(endpoints);
        assertEq(hook.poolCount(), 8);
        vm.recordLogs();
        invoke();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 4);
        for (uint256 i = 0; i < 4; ++i) {
            assertSnapshot(
                logs[i],
                uint160(2 * i + 1),
                -int24(int256(2 * i)),
                uint160(2 * i + 2),
                -int24(int256(2 * i + 1))
            );
        }
        configure(hook, address(a), address(b));
        assertEq(hook.poolCount(), 2);
        for (uint256 i = 2; i < 8; ++i) {
            assertEq(hook.pools(i), address(0));
        }
        invoke();
        assertEq(vm.getRecordedLogs().length, 1);
    }

    function testFuzz_rejectsOddOrTooManyPools(uint8 length) public {
        vm.assume(length > 8 || length % 2 != 0);
        address[] memory endpoints = new address[](length);
        vm.prank(OWNER);
        vm.expectRevert(SiphonDataLogger.InvalidPoolCount.selector);
        hook.setPools(endpoints);
        assertEq(hook.poolCount(), 2);
        assertEq(hook.pools(0), address(a));
    }

    function test_invalidSetPoolsIsAtomic() public {
        address[] memory endpoints = pair(address(b), address(0));
        vm.startPrank(OWNER);
        vm.expectRevert(SiphonDataLogger.InvalidPool.selector);
        hook.setPools(endpoints);
        endpoints[1] = manager; // no code
        vm.expectRevert(SiphonDataLogger.InvalidPool.selector);
        hook.setPools(endpoints);
        endpoints[1] = address(b); // duplicate
        vm.expectRevert(SiphonDataLogger.InvalidPool.selector);
        hook.setPools(endpoints);
        vm.stopPrank();
        assertEq(hook.poolCount(), 2);
        assertEq(hook.pools(0), address(a));
        assertEq(hook.pools(1), address(b));
    }

    function test_revertingFirstOrSecondEndpointFailsWithoutEmitting() public {
        a.setFails(true);
        vm.recordLogs();
        vm.expectRevert(abi.encodeWithSelector(SiphonDataLogger.PoolReadFailed.selector, address(a)));
        invoke();
        assertEq(vm.getRecordedLogs().length, 0);
        a.setFails(false);
        b.setFails(true);
        vm.expectRevert(abi.encodeWithSelector(SiphonDataLogger.PoolReadFailed.selector, address(b)));
        invoke();
        assertEq(vm.getRecordedLogs().length, 0);
    }

    function testFuzz_shortReturnFails(uint8 size) public {
        size = uint8(bound(size, 0, 63));
        a.setResponse(new bytes(size));
        vm.expectRevert(abi.encodeWithSelector(SiphonDataLogger.PoolReadFailed.selector, address(a)));
        invoke();
    }

    function testFuzz_dirtyUint160Rejected(uint96 highBits, uint160 lowBits) public {
        vm.assume(highBits != 0);
        a.setResponse(abi.encode((uint256(highBits) << 160) | lowBits, int24(0)));
        vm.expectRevert(abi.encodeWithSelector(SiphonDataLogger.InvalidSlot0.selector, address(a)));
        invoke();
    }

    function test_noncanonicalPositiveAndNegativeTicksRejected() public {
        int256[3] memory dirty = [int256(8388608), int256(-8388609), int256(0xffffff)];
        for (uint256 i = 0; i < dirty.length; ++i) {
            b.setResponse(abi.encode(Q96, dirty[i]));
            vm.expectRevert(abi.encodeWithSelector(SiphonDataLogger.InvalidSlot0.selector, address(b)));
            invoke();
        }
    }

    function test_endpointCannotWriteDuringStaticRead() public {
        WritingEndpoint writing = new WritingEndpoint();
        configure(hook, address(writing), address(b));
        bytes memory data =
            abi.encodeCall(hook.afterSwap, (address(this), key, params, BalanceDelta.wrap(0), ""));
        vm.prank(manager);
        (bool ok, bytes memory reason) = address(hook).call{gas: 300000}(data);
        assertFalse(ok);
        assertEq(reason, abi.encodeWithSelector(SiphonDataLogger.PoolReadFailed.selector, address(writing)));
        assertEq(writing.writes(), 0);
    }

    function test_standardV4StateViewIsNotSilentlyTreatedAsCustomEndpoint() public {
        StandardStateViewEndpoint standard = new StandardStateViewEndpoint();
        assertEq(standard.getSlot0.selector, bytes4(0xc815641c));
        configure(hook, address(standard), address(b));
        vm.expectRevert(abi.encodeWithSelector(SiphonDataLogger.PoolReadFailed.selector, address(standard)));
        invoke();
    }

    function test_codeRemovedAfterConfigurationFailsClosed() public {
        vm.etch(address(b), "");
        vm.expectRevert(abi.encodeWithSelector(SiphonDataLogger.PoolReadFailed.selector, address(b)));
        invoke();
    }

    function test_unsupportedSelectorsAndNativeTransfersAreRejected() public {
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(hook).call{value: 1}("");
        assertFalse(ok);
        (ok,) = address(hook).call(hex"deadbeef");
        assertFalse(ok);
        vm.prank(OWNER);
        (ok,) = address(hook).call(abi.encodeWithSignature("transferOwnership(address)", address(this)));
        assertFalse(ok);
        assertEq(hook.owner(), OWNER);
    }

    function assertSnapshot(Vm.Log memory entry, uint160 priceA, int24 tickA, uint160 priceB, int24 tickB)
        internal
        view
    {
        assertEq(entry.emitter, address(hook));
        assertEq(entry.topics.length, 2);
        assertEq(entry.topics[0], DATA_TOPIC);
        assertEq(uint256(entry.topics[1]), vm.getBlockNumber());
        assertEq(entry.data, abi.encode(priceA, tickA, priceB, tickB));
    }
}
