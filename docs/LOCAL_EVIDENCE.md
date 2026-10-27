# Local verification evidence

This is **Foundry local EVM evidence**, not a mainnet transaction receipt. There is no transaction hash, live hook address, live Pool B, or owner-funded LP position to report. Production status is recorded separately in [PREFLIGHT.json](PREFLIGHT.json).

## Reproduce the swap

```sh
FOUNDRY_FUZZ_SEED=0x51d709cf2bfe2f4a90e373eebd67a85f16553cb6944809625cef649814239a98 \
  forge test --match-test test_onePointZeroZeroOneSwapEmitsActualStateAndNoExtraSwaps -vvvv
```

Fixture: two locally deployed ERC-20s, a real v4 PoolManager, both pools initially at `sqrtPriceX96 = 2**96`, fee 5000, spacing 100, and `10**18` units of active liquidity per pool. Pool A has no hook; Pool B uses the actual mined logger. Test-only endpoints read each pool's actual state. The local ERC-20 input is `10**15` units (0.001 with 18 decimals), currency1 to currency0.

The decoded `PoolData` is:

```json
{
  "blockNumber": "123456",
  "sqrtPriceA": "79228162514264337593543950336",
  "tickA": 0,
  "sqrtPriceB": "79306994535966030609449526566",
  "tickB": 19
}
```

The manager's single `Swap` reports:

```json
{
  "amount0": "994010959095699",
  "amount1": "-1000000000000000",
  "sqrtPriceX96": "79306994535966030609449526566",
  "liquidity": "1000000000000000000",
  "tick": 19,
  "fee": 5000
}
```

The test independently reads PoolManager state and compares every event field, checks the index topic and emitter, counts one manager swap call and one swap log, verifies exactly two hook-originated STATICCALLs with `0xc815641c`, and checks all hook/router settlement deltas. The trace measured 21,959 gas for the callback including test endpoint reads in this fixture; it is not a production gas guarantee.

## Admission rehearsal

The supplied `Hook.protected.t.sol` was copied unchanged to disposable scratch space and run with the built creation code, actual constructor manager/owner arguments, chain ID 4663, declared flags 4160 (`0x1040`), and the toolchain's local factory probe. The local launch probe used fee 12500, spacing 100 and price `2**96`.

All four tests passed, without skips:

- `test_permissionsMatchTheDeclaredFlags`
- `test_runtimeCodeHasNoEscapeHatch`
- `test_callbacksRefuseCallersOtherThanThePoolManager`
- `test_initializesFromTheLaunchFactory`

The disposable copy was removed afterwards. Neither the provided inputs nor the admission assertions were edited. This rehearsal places mock currencies and a locally constructed manager at the requested addresses; it establishes admission compatibility, not live chain compatibility.

The delivered Solidity tests separately verify `afterSwap` authentication, explicit immutable ownership, seeded swaps in both directions, and collection/unwind in every logging state. The independent verifier remains responsible for its full toolchain suites and final deployment parameters.
