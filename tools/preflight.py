#!/usr/bin/env python3
"""Read-only Robinhood probes. Never signs, broadcasts, or reads wallet configuration."""

import datetime
import hashlib
import json
import subprocess
import sys
import time

RPC = "https://rpc.mainnet.chain.robinhood.com"
MANAGER = "0x8366a39CC670B4001A1121B8F6A443A643e40951"
SIPHON = "0x60013a6f087cb84b3c28129dac9a568e94d2b384"
ETH = "0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7"


def rpc(method, params):
    payload = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params})
    for attempt in range(4):
        result = subprocess.run(
            ["curl", "--disable", "--silent", "--show-error", "--max-time", "15",
             "--write-out", "\n%{http_code}", "--header", "Content-Type: application/json",
             "--data", payload, RPC],
            capture_output=True, text=True, check=False, timeout=20,
        )
        if result.returncode:
            raise RuntimeError(f"{method}: curl exited {result.returncode}: {result.stderr.strip()}")
        body, status = result.stdout.rsplit("\n", 1)
        retry = status == "429" or status in {"502", "503", "504"}
        response = None
        if status == "200":
            response = json.loads(body)
            error = response.get("error")
            retry = bool(error and (error.get("code") == -32005 or "429" in str(error)
                                   or "rate limit" in str(error).lower()))
            if not error:
                return response["result"]
        if retry and attempt < 3:
            time.sleep(0.5 * (2 ** attempt))
            continue
        raise RuntimeError(f"{method}: HTTP {status}; {(response or body)!r}")
    raise AssertionError("unreachable")


def symbol(raw):
    data = bytes.fromhex(raw.removeprefix("0x"))
    if len(data) < 64 or int.from_bytes(data[:32], "big") != 32:
        return None
    length = int.from_bytes(data[32:64], "big")
    if 64 + length > len(data):
        return None
    return data[64:64 + length].decode("utf-8")


def probe():
    report = {
        "status": "RED",
        "scope": "Read-only probes; not deployment, fork simulation, LP funding, or a swap",
        "observedAtUtc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "rpc": RPC,
        "transactionsSent": 0,
        "deployment": {"hookAddress": None, "transactionHash": None},
        "poolA": {"address": None, "poolId": None, "status": "not located"},
        "poolB": {"address": None, "poolId": None, "status": "not created"},
        "lp": {"status": "not added", "transactionHash": None},
        "testSwap": {"transactionHash": None, "decodedEvent": None, "status": "not performed"},
        "reasons": ["Mandatory signed mainnet pre-flight steps have not been performed."],
        "contracts": {},
    }
    try:
        report["chainId"] = int(rpc("eth_chainId", []), 16)
        if report["chainId"] != 4663:
            raise RuntimeError("RPC chain ID differs from Robinhood mainnet 4663")
        block = rpc("eth_blockNumber", [])
        report["rpcBlockNumber"] = block
        for label, address in (("poolManager", MANAGER), ("SIPHON", SIPHON), ("ETH", ETH)):
            raw_code = rpc("eth_getCode", [address, block])
            code = bytes.fromhex(raw_code.removeprefix("0x"))
            entry = {"address": address, "codeBytes": len(code), "codeSha256": hashlib.sha256(code).hexdigest()}
            report["contracts"][label] = entry
            if label != "poolManager":
                raw_symbol = rpc("eth_call", [{"to": address, "data": "0x95d89b41"}, block])
                raw_decimals = rpc("eth_call", [{"to": address, "data": "0x313ce567"}, block])
                entry.update({"symbolResponse": raw_symbol, "symbol": symbol(raw_symbol),
                              "decimalsResponse": raw_decimals,
                              "decimals": int(raw_decimals, 16) if len(raw_decimals) == 66 else None})
            if not code:
                report["reasons"].append(f"{label} address has no deployed code at the recorded block.")
    except (RuntimeError, ValueError, KeyError, subprocess.TimeoutExpired) as error:
        report["reasons"].append(str(error))
    report["reasons"].append(
        "No pool endpoint is verified to accept the four-byte-only 0xc815641c payload. "
        "That selector is getSlot0(bytes32) in standard v4 StateView; the argument cannot be guessed."
    )
    return report


if __name__ == "__main__":
    print(json.dumps(probe(), indent=2))
    sys.exit(1)  # A read-only check cannot turn the mandatory transactional pre-flight Green.
