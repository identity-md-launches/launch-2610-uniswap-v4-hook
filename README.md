# SiphonDataLogger

A compact Uniswap v4 observation hook with a reproducible Foundry project. The deployed hook is **1,991 bytes** with the pinned compiler/settings. All dependencies are ordinary, vendored source files; builds and tests need no RPC or dependency downloads once Solidity 0.8.26 is installed.

**Mainnet pre-flight is RED. This repository delivers the implementation and local evidence, not a completed on-chain deployment.** No transactions were signed or sent, no LP was funded, and no mainnet swap receipt exists. [The recorded read-only probes](docs/PREFLIGHT.json) distinguish missing evidence from completed checks.

## Decisions and deviations

The job order's final retry guidance asks for a useful implementation without waiting for missing deployment inputs. These are the decisions used here:

| Open issue | Decision and reason |
| --- | --- |
| `afterSwap` only conflicts with launch admission | Enable `afterInitialize` **and** `afterSwap`, address mask **`0x1040`**. The pinned `Hook.protected.t.sol::test_permissionsMatchTheDeclaredFlags` requires an initialization callback. `afterInitialize` only authenticates PoolManager and returns its selector; it does not log, call, charge, or write. This is an explicit departure from the job order's `0x0040` permission mask. |
| No authorized signing workflow or verified pool endpoints | Finish source and local verification. Keep production pool configuration empty, with owner-only `setPools`. Do not invent addresses, pool IDs, receipts, signing keys, or liquidity. The deployment and LP gate stays Red. |
| Pause behavior unspecified | `pause()` suppresses logging and reads; swaps continue. An empty configuration behaves the same way. This avoids blocking trading and fee collection immediately after launch. |
| Eight pools but only a two-pool event schema | Accept **0, 2, 4, 6, or 8** distinct endpoints, in adjacent pairs. Two endpoints produce exactly one event. Four/eight endpoints produce two/four ordered events. Reject odd lengths to avoid invented values or ambiguous missing partners. |
| Non-standard `getSlot0` payload | Send **exactly four bytes**, `0xc815641c`, to each configured endpoint. Never substitute `slot0()`, append an invented pool ID, or deploy a production adapter. Compatibility must be demonstrated before configuration. |
| Callback return described as selector only | Use the official v4 ABI: `(IHooks.afterSwap.selector, int128(0))`. All return-delta permissions remain false. |
| Requested Pool B fee versus IMD fee policy | Local tests cover requested fee **5000**, spacing **100**, and initialization/fee collection at the network policy fee **12500**. The hook imposes neither fee. An IMD factory launch must use its policy fee; it must not be represented as the requested 5000 pool. Pool creation remains an operator task. |

There is no launch token, hook fee, share token, router, upgrade path, ownership transfer, or fund-custody feature. Contracts under `test/` are local scaffolding, not deployment candidates.

## Build and test

```sh
forge build
FOUNDRY_FUZZ_SEED=0x51d709cf2bfe2f4a90e373eebd67a85f16553cb6944809625cef649814239a98 forge test
forge fmt --check
python3 -m unittest discover -s test -p 'test_*.py' -v
```

`foundry.toml` pins Solidity **0.8.26**, Cancun, IR compilation, optimizer runs **1**, and disabled CBOR metadata. FFI and filesystem cheatcode permissions are disabled. Do not change compilation settings after mining an address. Dependency repositories, commits, archive checksums, and included paths are recorded in [DEPENDENCIES.json](DEPENDENCIES.json); their licenses remain in `lib/`. There are no submodules or package-install steps.

The Solidity suite covers:

- Actual CREATE2 deployment, final owner/manager arguments, address permissions, enabled callback authentication, runtime size and forbidden opcodes.
- Exact call payloads, call order/count, STATICCALL execution, one event for v0, zero returned delta, and no callback storage writes.
- Full `uint160`/`int24` ranges, negative tick sign extension, short/reverting/dirty/oversized responses, disappeared code, attempted endpoint writes, and the incompatible ordinary StateView ABI.
- Owner authorization, atomic configuration validation, bounded pairs, replacement/clearing, pause/unpause, no administrative events, and inert unset behavior.
- A real vendored v4 PoolManager: initialize, seed, trade exact input/output in both directions, compare logged values to actual pool state, count swap calls/events, settle all deltas, collect fees and unwind LP while paused, unset, or configured with a failing endpoint.
- A local **0.001** unit swap and a separate native-ETH test. These use local tokens and test endpoints, not the named mainnet tokens or a dollar-valued $5 deposit.

The integration test's `LocalPoolEndpoint` translates the custom read to a real **local** PoolManager's state. That mock proves callback timing and accounting; it does not prove those endpoints exist on Robinhood. Tests are deterministic, parallel-safe, environment-independent, and do not use fork RPCs. [Decoded local evidence](docs/LOCAL_EVIDENCE.md) records the successful swap and pinned admission rehearsal; [security review and verification limits](docs/SECURITY.md) explain the remaining checks.

## Contract behavior

Deploy `src/SiphonDataLogger.sol:SiphonDataLogger` with:

```solidity
constructor(IPoolManager poolManager_, address initialOwner)
```

Both arguments must be nonzero. The constructor makes no external calls, requires no external code, sets the owner explicitly (never the deployer or `tx.origin`), and rejects addresses whose low 14 bits differ from `0x1040`. The PoolManager and owner are immutable.

`getHookPermissions()` declares only `afterInitialize` and `afterSwap`. Every enabled callback checks `msg.sender == poolManager`. Unsupported callback selectors revert. Initialization remains available while paused or unconfigured and does not restrict the factory, currencies, price, fee, or tick spacing.

`setPools(address[])` is owner-only. It validates the even count, limit of eight, existing code, and uniqueness, and replaces the list atomically. `poolCount()` gives the active count; `pools(index)` exposes fixed slots 0–7, with inactive slots cleared. This is a list of **read endpoints**, not a list of pool IDs. Setting the two v0 endpoints activates logging unless paused.

On an active callback, the hook reads each adjacent pair in order and emits only:

```solidity
event PoolData(
    uint256 indexed blockNumber,
    uint160 sqrtPriceA,
    int24 tickA,
    uint160 sqrtPriceB,
    int24 tickB
);
```

Each response must succeed, contain at least 64 bytes, and have canonical ABI-encoded `uint160` and sign-extended `int24` first words. Trailing fields are ignored; only 64 bytes are copied into hook memory. The values are raw observations, including zero if an endpoint reports zero; the hook does not certify initialized prices, tick/price consistency, or oracle safety.

A bad **configured** endpoint reverts the entire swap, avoiding fabricated data. The owner can pause, clear, or repair the configuration to restore swaps. A callee can consume forwarded gas, so endpoint implementations must be reviewed. The hook has no liquidity callbacks, so configuration or pause cannot block LP removal or the factory's zero-liquidity fee collect. No callback executes a swap, transfers funds, calls PoolManager, or uses transient storage. The real PoolManager itself uses transient storage as part of standard v4 accounting; the restriction is verified on the hook's runtime.

There are no pause, unpause, ownership, or configuration events, including during construction. Indexers must reconstruct the active endpoint ordering from successful owner transactions and storage. For larger lists, event order identifies pairs. All attached pools trigger the same configured observations; the hook does not restrict attachment to one Pool B. A `PoolData` record does not identify the triggering pool; correlate it with the manager's `Swap` event in the same receipt.

## Mainnet findings

The recorded RPC is `https://rpc.mainnet.chain.robinhood.com`, chain ID **4663**. At block `0x5e856d3`:

| Item from the brief | Address | Read-only result |
| --- | --- | --- |
| Owner / payer | `0x735121A546092F31050A867FD7E3A750C7B0EFF9` | Explicit constructor owner; no wallet access attempted |
| PoolManager | `0x8366a39CC670B4001A1121B8F6A443A643e40951` | 24,009 bytes of code; custom attachment not established |
| SIPHON | `0x60013a6f087cb84b3c28129dac9a568e94d2b384` | 2,205 bytes of code, symbol `SIPH`, 18 decimals |
| Supplied ETH | `0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7` | **No code**; `symbol()` and `decimals()` both return `0x` |

The nonzero ETH address cannot be assumed to be a usable ERC-20 or silently replaced with native ETH. The explorer address lookup also returned HTTP 403, so it supplied no genesis-pool evidence. Pool A has not been located.

There is a second compatibility gap: `cast sig 'getSlot0(bytes32)'` returns **`0xc815641c`**, while `cast sig 'getSlot0()'` returns **`0xc9ae5e0c`**. The job's four-byte-only payload therefore requires a specifically verified custom endpoint. Standard v4 uses a singleton PoolManager and pool IDs, without a separate deployed contract for every pool ([Uniswap PoolManager documentation](https://developers.uniswap.org/docs/protocols/v4/concepts/poolmanager)). An `Initialize` event by itself does not establish a per-pool endpoint accepting that payload.

Reproduce the read-only evidence with `python3 tools/preflight.py`. It prints JSON and exits **1** because a read-only probe cannot satisfy the signed mainnet pre-flight. It uses block-pinned `eth_call`/`eth_getCode`, no `eth_getLogs`, and bounded exponential backoff for HTTP/JSON-RPC rate limits. It requires Python 3 and curl, and reads no keys or wallet configuration. Its output is evidence of reads only.

## After launch

These responsibilities belong to the owner and the authorized deployment operator. The mandatory pre-flight must be satisfied before funding any production pool; this code's local success is not a Green pre-flight.

1. **Resolve token and endpoint identity.** Verify the intended ETH representation, both currencies' code and decimals, and the exact deployed PoolManager/hook attachment ABI. Locate the genesis pool using an indexed `Initialize` event and verify its transaction receipt. Derive its full PoolKey and `poolId = keccak256(abi.encode(currency0, currency1, fee, tickSpacing, hooks))`. Record the manager address separately from any custom pool endpoint. State can be read with `eth_call`; logs cannot be discovered with an ordinary state call. Use an indexed event service or appropriately bounded log queries with backoff when that service is available.
2. **Prepare deployment using actual parameters.** Pass the above named owner and manager plus the actual CREATE2-deploying factory to `PrepareSiphonDeployment.run(address,address,address,uint256,uint256)`. Supply a search start and 1–1,000,000 attempts. It returns initcode, salt and the predicted address without broadcasting or reading the environment. The final deployed address must satisfy `address & 0x3fff == 0x1040`. A different factory, constructor argument, compiler setting or source changes the address; re-mine. Verify predicted-address availability and the runtime independently before broadcast.
3. **Complete the transactional pre-flight.** The authorized operator must deploy and verify the hook, initialize the intended pair with standard attachment, seed a minimal position, and prove a swap reaches the callback. Establish custom endpoint compatibility from inside the callback. A non-standard attachment without a verified specification is Red; do not guess. No signing key or made-up factory is included here.
4. **Configure observations.** The owner calls `setPools([verifiedEndpointA, verifiedEndpointB])`, using endpoint addresses obtained from the verified chain deployment/event evidence. Pause first if a staged setup is needed, verify both endpoint reads, then `unpause()`. Until `setPools` succeeds, logging is off and trading/fee collection remain available. More endpoints must be added as adjacent pairs. This setting is never populated with placeholder addresses.
5. **Create/seed Pool B under the actual launch route.** The order's requested parameters are fee 5000 and spacing 100; an IMD launch uses its required fee 12500 instead. Keep this distinction in the operator's deployment record. Choose an initial price from verified genesis state, valid ticks at the chosen spacing, and owner-approved amounts corresponding to $5 of ETH plus proportional SIPH using verified decimals and a contemporaneous quote. Use explicit slippage limits and deadlines. The hook manages no LP or token approvals; the operator must keep the position/recipient under the owner's control.
6. **Produce mainnet acceptance evidence.** For one owner-authorized 0.001 ETH swap, record the tx hash, receipt, full keys/IDs, hook and endpoint addresses, and LP position/liquidity state. Decode exactly one `PoolData` for v0, confirm exactly one manager `Swap`, and inspect the transaction trace for extra swaps. Compare A/B values to callback-time state (a later transaction in the same block can change end-of-block values). Verify the input amount, settlement and LP amounts on-chain. Do not publish local test addresses as mainnet deployment addresses.
7. **Monitor and recover.** Watch endpoint failures and missing events; pause logging or clear configuration to recover swaps, then fix endpoints and unpause. Recovering from a lost immutable owner key requires a new hook and pool migration. There is no ownership transfer or upgrade escape hatch.

`PoolData.blockNumber` is precisely Solidity's `block.number`. On Robinhood this is an estimate of the parent-chain number, not the receipt's L2 number. Keep receipt block hash, L2 number and the event's indexed number as separate fields; “same block” means the event is in the swap receipt, not that the two numeric fields necessarily match. See [Robinhood's execution differences](https://docs.robinhood.com/chain/differences-from-ethereum/) and the pinned L2 reference.

## Configuration record

Conceptual hook type: BaseHook-style observation. The minimal implementation uses official v4 types directly rather than inheriting unused callback implementations, to meet the bytecode limit.

```json
{
  "hook": "BaseHook",
  "name": "SiphonDataLogger",
  "pausable": true,
  "currencySettler": false,
  "safeCast": false,
  "transientStorage": false,
  "shares": { "options": false },
  "permissions": {
    "beforeInitialize": false,
    "afterInitialize": true,
    "beforeAddLiquidity": false,
    "afterAddLiquidity": false,
    "beforeRemoveLiquidity": false,
    "afterRemoveLiquidity": false,
    "beforeSwap": false,
    "afterSwap": true,
    "beforeDonate": false,
    "afterDonate": false,
    "beforeSwapReturnDelta": false,
    "afterSwapReturnDelta": false,
    "afterAddLiquidityReturnDelta": false,
    "afterRemoveLiquidityReturnDelta": false
  },
  "inputs": {},
  "access": "ownable",
  "info": { "license": "MIT" }
}
```

`ownable` here denotes the fixed owner authorization implemented in the contract, not an inherited ownership-transfer API. `pausable` denotes logging pause, not a swap veto.
