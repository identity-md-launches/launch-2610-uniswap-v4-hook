"""Offline tests for bounded HTTP/JSON-RPC retry behavior and decoding."""

import importlib.util
from pathlib import Path
import subprocess
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("preflight", Path(__file__).parents[1] / "tools/preflight.py")
preflight = importlib.util.module_from_spec(spec)
spec.loader.exec_module(preflight)


def response(body, status="200"):
    return subprocess.CompletedProcess([], 0, body + "\n" + status, "")


class PreflightTest(unittest.TestCase):
    @patch.object(preflight.time, "sleep")
    @patch.object(preflight.subprocess, "run")
    def test_http_429_backs_off_then_reads(self, run, sleep):
        run.side_effect = [response("rate limited", "429"), response('{"result":"0x1237"}')]
        self.assertEqual(preflight.rpc("eth_chainId", []), "0x1237")
        sleep.assert_called_once_with(0.5)
        self.assertEqual(run.call_count, 2)

    @patch.object(preflight.time, "sleep")
    @patch.object(preflight.subprocess, "run")
    def test_json_rpc_rate_limit_is_bounded(self, run, sleep):
        run.return_value = response('{"error":{"code":-32005,"message":"rate limit"}}')
        with self.assertRaisesRegex(RuntimeError, "rate limit"):
            preflight.rpc("eth_call", [])
        self.assertEqual(run.call_count, 4)
        self.assertEqual([call.args[0] for call in sleep.call_args_list], [0.5, 1.0, 2.0])

    @patch.object(preflight.time, "sleep")
    @patch.object(preflight.subprocess, "run")
    def test_permanent_rpc_failure_is_not_retried(self, run, sleep):
        run.return_value = response('{"error":{"code":3,"message":"execution reverted"}}')
        with self.assertRaisesRegex(RuntimeError, "execution reverted"):
            preflight.rpc("eth_call", [])
        self.assertEqual(run.call_count, 1)
        sleep.assert_not_called()

    def test_symbol_empty_malformed_and_valid(self):
        self.assertIsNone(preflight.symbol("0x"))
        self.assertIsNone(preflight.symbol("0x" + "00" * 64))
        data = (32).to_bytes(32, "big") + (4).to_bytes(32, "big") + b"SIPH" + bytes(28)
        self.assertEqual(preflight.symbol("0x" + data.hex()), "SIPH")


if __name__ == "__main__":
    unittest.main()
