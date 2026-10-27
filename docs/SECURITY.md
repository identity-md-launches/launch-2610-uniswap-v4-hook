# Security review and verification scope

This is an implementation review against the supplied v4 and Ethereum security references, not an independent security audit. The mainnet pre-flight is Red; deployment, fork compatibility and funded transactions are unverified.

| Area | Implementation and evidence |
| --- | --- |
| Permissions | Exact low-14-bit mask `0x1040`, validated in the constructor and through actual CREATE2 deployment tests. Only initialization acknowledgement and post-swap logging; all delta flags false. |
| Callback authority | Both callbacks require the immutable PoolManager. The router/sender argument cannot authenticate callers. Tests include unauthorized calls while paused. |
| Administrative authority | Explicit immutable constructor owner; never deployer, factory or transaction origin. Only `setPools`, `pause`, `unpause` mutate state. No proxy, external initializer, ownership transfer or renunciation. |
| Unconfigured launch | Empty list means no reads/logs and returns the successful callback selector with zero delta. Initialization, swaps and factory fee collection work. |
| Bounds | At most eight unique addresses in pairs; no dynamic loop over traders, positions or history. Configuration validation is atomic and checks deployed code. |
| Call safety | Hook runtime contains STATICCALL only; exact four-byte payload and bounded 64-byte copy. Failed/short/noncanonical replies revert. Larger replies are ignored beyond two words. |
| Reentrancy | EVM static context prohibits storage writes, logs and value-moving descendants. Endpoint-originated callback reentry also fails the manager gate. There is no transient/persistent reentrancy lock because callback state never changes and no mutable external calls are made. |
| Delta accounting | Always returns `(selector, 0)`; no settlement, minting, taking, fees or swaps in the hook. Local integration checks zero outstanding deltas and no balances at the hook after actual swaps. |
| Liquidity access | No add/remove hooks. Factory zero-liquidity fee collection and full LP withdrawal tested while active, unset, paused and with a broken read endpoint. |
| Event integrity | Values are freshly read after actual local swap state changes. Exact event signature, indexed EVM block, signed ticks, read order and count are tested. One log for two endpoints; no admin logs. |
| Funds/tokens | No token issuance, custody, approvals, payout recipient or ETH receive function. Token quirks affect the operator's router/pool, not this observer; mainnet token behavior has not been verified beyond the recorded reads. |
| Escape hatches | Runtime scan excludes PUSH data and rejects TLOAD, TSTORE, CALL, CALLCODE, DELEGATECALL, CREATE, CREATE2 and SELFDESTRUCT. No linked external libraries. |
| Bytecode | 1,991 deployed bytes with solc 0.8.26 and checked settings. Test asserts strictly less than 2,000 bytes, also satisfying a 2,048-byte interpretation. |

## Trust and availability

The owner chooses endpoints and may replace the data sources or stop observations at any time. A malicious or broken configured endpoint can revert or exhaust gas and thus block swaps until the owner pauses, clears or repairs configuration. A correct `uint160`/`int24` response does not prove truthful data. Code-length checks do not validate an ABI or stop an external endpoint proxy changing later.

These are spot observations. They must not be treated as manipulation-resistant prices for lending, collateral or other value-bearing decisions. Zero prices and out-of-market ticks are preserved if they are well-formed ABI values; endpoint/state validation belongs to configuration and consumers.

Any pool using this hook can trigger observation of the owner's configured pair. Logs do not contain endpoint addresses or triggering PoolId. Off-chain consumers must correlate manager events, owner configuration transactions and event ordering, and account for reorgs. Logging after static reads is intentional; no state-changing callback can occur in the intervening static context.

Owner immutability and the absence of upgrade/migration authority make behavior final, but also mean an incorrect owner argument or lost owner key cannot be repaired. Explicit constructor arguments and deployment-plan tests address accidental factory ownership; the operator must verify the real values before broadcast.

## Checks and remaining work

The delivered suite uses a real vendored PoolManager and test-only endpoints. It has unit, failure, fuzz, deployment and lifecycle tests; eight fuzz functions use the assignment's seed and 256 runs each. Python tests independently cover RPC retry bounds and response decoding. The pinned hook floor is also rehearsed locally from an unchanged scratch copy with explicit test launch parameters. The independent verifier must still run its own admission and owner checks against the final deployment parameters.

No custom token is delivered, so the pinned Token and OwnToken suites have no project token to exercise. The pinned Owners suite imports a toolchain-only `OwnerChecks.sol` that was not supplied; local lifecycle tests independently exercise explicit ownership and fee collection. This document does not claim that unavailable suite passed.

Slither, Mythril, formal verification and an independent audit were not run. The source contains none of the six prohibited patterns identified by the assignment: selfdestruct, arbitrary token pulls, an unprotected initializer/upgrade, uninitialized storage pointers, assembly shifts, or hashing two packed dynamic values. Foundry lint comments explain bounded-loop reverts and static-read-before-log ordering; they do not change runtime behavior or disable the independent verifier.

Mainnet/fork rehearsal, custom endpoint ABI verification, genesis event discovery, source verification on an explorer, transaction traces, actual LP ownership and funded swap evidence remain outstanding. A successful local test does not satisfy any of those deployment checks.
