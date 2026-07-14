import os
import struct
import sys
import unittest

sys.path.insert(0, os.path.dirname(__file__))
import rtos_board_runner as runner


class FakeSerial:
    def __init__(self, reads=()):
        self.reads = list(reads)
        self.written = bytearray()
        self.timeout = 0.1

    def write(self, data):
        self.written += data
        return len(data)

    def flush(self):
        pass

    def read(self, _size):
        if self.reads:
            return self.reads.pop(0)
        return b""


class BoardRunnerTests(unittest.TestCase):
    def test_image_frame_is_little_endian(self):
        payload = b"\x11\x22\x33\x44"
        self.assertEqual(
            runner.image_frame(payload),
            struct.pack("<II", runner.SYNC_WORD, 4) + payload,
        )

    def test_two_stage_only_uploads_target_after_pass(self):
        fake = FakeSerial([b"RTOS_PREF", b"LIGHT_PASS\r\n"])
        runner.run_two_stage(
            fake,
            b"PRE",
            b"TARGET",
            preamble=2,
            preflight_timeout=0.1,
            target_delay=0.0,
            rx_sink=lambda _chunk: None,
        )
        expected = (
            b"\x55\x55"
            + runner.image_frame(b"PRE")
            + b"\x55\x55"
            + runner.image_frame(b"TARGET")
        )
        self.assertEqual(bytes(fake.written), expected)

    def test_failure_marker_blocks_target(self):
        fake = FakeSerial([b"RTOS_PREFLIGHT_FAIL reason=queue"])
        with self.assertRaises(runner.PreflightError):
            runner.run_two_stage(
                fake,
                b"PRE",
                b"TARGET",
                preamble=0,
                preflight_timeout=0.1,
                target_delay=0.0,
                rx_sink=lambda _chunk: None,
            )
        self.assertEqual(bytes(fake.written), runner.image_frame(b"PRE"))

    def test_timeout_blocks_target(self):
        fake = FakeSerial()
        with self.assertRaises(runner.PreflightError):
            runner.run_two_stage(
                fake,
                b"PRE",
                b"TARGET",
                preamble=0,
                preflight_timeout=0.01,
                target_delay=0.0,
                rx_sink=lambda _chunk: None,
            )
        self.assertEqual(bytes(fake.written), runner.image_frame(b"PRE"))

    def test_timeout_retries_preflight_before_target(self):
        class RetrySerial(FakeSerial):
            def __init__(self):
                super().__init__()
                self.write_count = 0
                self.pass_sent = False

            def write(self, data):
                self.write_count += 1
                return super().write(data)

            def read(self, _size):
                if self.write_count >= 2 and not self.pass_sent:
                    self.pass_sent = True
                    return b"RTOS_PREFLIGHT_PASS\r\n"
                return b""

        fake = RetrySerial()
        runner.run_two_stage(
            fake,
            b"PRE",
            b"TARGET",
            preamble=0,
            preflight_timeout=0.001,
            target_delay=0.0,
            preflight_attempts=2,
            retry_delay=0.0,
            rx_sink=lambda _chunk: None,
        )
        self.assertEqual(
            bytes(fake.written),
            runner.image_frame(b"PRE") * 2 + runner.image_frame(b"TARGET"),
        )

    def test_console_reload_is_paced_command(self):
        fake = FakeSerial()
        runner.request_console_reload(fake, char_delay=0.0)
        self.assertEqual(bytes(fake.written), b"\rreload\r")

    def test_target_marker_can_be_confirmed(self):
        fake = FakeSerial([b"RTOS_SMOKE_", b"PASS\r\n"])
        history = runner.wait_for_marker(
            fake,
            timeout_seconds=0.1,
            pass_marker=b"RTOS_SMOKE_PASS",
            failure_markers=runner.DEFAULT_TARGET_FAILURE_MARKERS,
            stage="target",
            rx_sink=lambda _chunk: None,
        )
        self.assertIn(b"RTOS_SMOKE_PASS", history)

    def test_target_timeout_requests_reload_and_reuploads(self):
        target_frame = runner.image_frame(b"TARGET")

        class TargetRetrySerial(FakeSerial):
            def __init__(self):
                super().__init__()
                self.target_writes = 0
                self.pass_sent = False

            def write(self, data):
                if data == target_frame:
                    self.target_writes += 1
                return super().write(data)

            def read(self, _size):
                if self.target_writes >= 2 and not self.pass_sent:
                    self.pass_sent = True
                    return b"APP_READY\r\n"
                return b""

        fake = TargetRetrySerial()
        runner.send_image(fake, b"TARGET", preamble=0)
        history = runner.confirm_target_with_retries(
            fake,
            target_payload=b"TARGET",
            target_marker=b"APP_READY",
            target_timeout=0.001,
            preamble=0,
            target_attempts=2,
            retry_delay=0.0,
            rx_sink=lambda _chunk: None,
        )
        self.assertIn(b"APP_READY", history)
        self.assertEqual(fake.target_writes, 2)
        self.assertIn(b"\rreload\r", bytes(fake.written))


if __name__ == "__main__":
    unittest.main()
