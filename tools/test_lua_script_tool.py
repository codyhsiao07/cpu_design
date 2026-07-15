import os
import sys
import unittest
from unittest import mock

sys.path.insert(0, os.path.dirname(__file__))
import run_lua_script as tool


class FakeSerial:
    def __init__(self, reads=()):
        self.reads = list(reads)
        self.written = bytearray()

    def write(self, data):
        self.written += data
        return len(data)

    def flush(self):
        pass

    def read(self, _size):
        if self.reads:
            return self.reads.pop(0)
        return b""


class FakeConsole:
    def __init__(self, keys):
        self.keys = list(keys)

    def kbhit(self):
        return bool(self.keys)

    def getwch(self):
        return self.keys.pop(0)


class LuaScriptToolTests(unittest.TestCase):
    def test_crc32_matches_standard_vector(self):
        self.assertEqual(tool.script_crc32(b"123456789"), 0xCBF43926)

    def test_run_control_contains_length_crc_and_limits(self):
        self.assertEqual(
            tool.build_run_control(b"abc", 1234, 5678),
            b"@lua run 3 352441C2 1234 5678\r\n",
        )

    def test_upload_waits_for_ready_then_sends_payload(self):
        fake = FakeSerial(
            [
                b"LUA_SCRIPT_RX_READY length=3\r\n",
                (
                    b"LUA_SCRIPT_ACCEPTED length=3 crc=0x352441C2\r\n"
                    b"LUA_SCRIPT_START length=3\r\n"
                    b"LUA_SCRIPT_PASS\r\n"
                ),
            ]
        )
        result = tool.upload_and_run(
            fake,
            b"abc",
            timeout_ms=1234,
            instruction_limit=5678,
            char_delay=0.0,
            chunk_delay=0.0,
            sink=lambda _chunk: None,
        )
        self.assertEqual(result, b"LUA_SCRIPT_PASS")
        self.assertEqual(
            bytes(fake.written),
            b"\r@lua run 3 352441C2 1234 5678\r\nabc",
        )

    def test_detach_returns_after_start(self):
        fake = FakeSerial(
            [
                b"LUA_SCRIPT_RX_READY length=3\r\n",
                (
                    b"LUA_SCRIPT_ACCEPTED length=3 crc=0x352441C2\r\n"
                    b"LUA_SCRIPT_START length=3\r\n"
                ),
            ]
        )
        result = tool.upload_and_run(
            fake,
            b"abc",
            detach=True,
            char_delay=0.0,
            chunk_delay=0.0,
            sink=lambda _chunk: None,
        )
        self.assertEqual(result, b"LUA_SCRIPT_START length=")

    def test_detach_can_reuse_monitor_for_interactive_result(self):
        fake = FakeSerial(
            [
                b"LUA_SCRIPT_RX_READY length=3\r\n",
                (
                    b"LUA_SCRIPT_ACCEPTED length=3 crc=0x352441C2\r\n"
                    b"LUA_SCRIPT_START length=3\r\n"
                ),
                b"GAME_READY\r\n",
                b"LUA_SCRIPT_PASS\r\n",
            ]
        )
        monitor = tool.SerialMonitor(fake, sink=lambda _chunk: None)
        result = tool.upload_and_run(
            fake,
            b"abc",
            detach=True,
            char_delay=0.0,
            chunk_delay=0.0,
            monitor=monitor,
        )
        self.assertEqual(result, b"LUA_SCRIPT_START length=")

        with mock.patch.object(tool, "msvcrt", FakeConsole(["7", "\r"])):
            result = tool.interactive_session(fake, monitor=monitor, timeout=1.0)

        self.assertEqual(result, b"LUA_SCRIPT_PASS")
        self.assertTrue(bytes(fake.written).endswith(b"7\r\n"))

    def test_stop_waits_for_final_stop_marker(self):
        fake = FakeSerial(
            [
                b"LUA_SCRIPT_STOP_REQUESTED\r\n",
                b"LUA_SCRIPT_STOPPED\r\n",
            ]
        )
        result = tool.send_stop(
            fake,
            wait=True,
            char_delay=0.0,
            sink=lambda _chunk: None,
        )
        self.assertEqual(result, b"LUA_SCRIPT_STOPPED")
        self.assertEqual(bytes(fake.written), b"\r@lua stop\r\n")

    def test_rejects_oversize_script(self):
        with self.assertRaises(ValueError):
            tool.build_run_control(
                b"x" * (tool.MAX_SCRIPT_BYTES + 1),
                tool.DEFAULT_TIMEOUT_MS,
                tool.DEFAULT_INSTRUCTION_LIMIT,
            )


if __name__ == "__main__":
    unittest.main()
