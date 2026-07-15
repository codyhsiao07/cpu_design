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
            struct.pack(
                "<III", runner.SYNC_WORD_V2, 4, runner.payload_crc32(payload)
            )
            + payload,
        )

    def test_crc32_matches_standard_vector(self):
        self.assertEqual(runner.payload_crc32(b"123456789"), 0xCBF43926)

    def test_v1_frame_remains_available_for_old_bitstreams(self):
        payload = b"old"
        self.assertEqual(
            runner.image_frame(payload, protocol="v1"),
            struct.pack("<II", runner.SYNC_WORD_V1, len(payload)) + payload,
        )

    def test_two_stage_only_uploads_target_after_pass(self):
        fake = FakeSerial([b"RTOS_PREF", b"LIGHT_PASS\r\n"])
        runner.run_two_stage(
            fake,
            b"PRE",
            b"TARGET",
            preamble=2,
            chunk_delay=0.0,
            sync_settle=0.0,
            header_settle=0.0,
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
                chunk_delay=0.0,
                sync_settle=0.0,
                header_settle=0.0,
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
                chunk_delay=0.0,
                sync_settle=0.0,
                header_settle=0.0,
                preflight_timeout=0.01,
                target_delay=0.0,
                rx_sink=lambda _chunk: None,
            )
        self.assertEqual(bytes(fake.written), runner.image_frame(b"PRE"))

    def test_timeout_retries_preflight_before_target(self):
        class RetrySerial(FakeSerial):
            def __init__(self):
                super().__init__()
                self.pre_uploads = 0
                self.pass_sent = False

            def write(self, data):
                if data == b"PRE":
                    self.pre_uploads += 1
                return super().write(data)

            def read(self, _size):
                if self.pre_uploads >= 2 and not self.pass_sent:
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
            chunk_delay=0.0,
            sync_settle=0.0,
            header_settle=0.0,
            rx_sink=lambda _chunk: None,
        )
        self.assertEqual(
            bytes(fake.written),
            runner.image_frame(b"PRE") * 2 + runner.image_frame(b"TARGET"),
        )

    def test_bootloader_crc_rejection_retries_preflight_immediately(self):
        fake = FakeSerial([b"\x15", b"RTOS_PREFLIGHT_PASS\r\n"])
        runner.run_two_stage(
            fake,
            b"PRE",
            b"TARGET",
            preamble=0,
            preflight_timeout=0.1,
            target_delay=0.0,
            preflight_attempts=2,
            retry_delay=0.0,
            chunk_delay=0.0,
            sync_settle=0.0,
            header_settle=0.0,
            rx_sink=lambda _chunk: None,
        )
        self.assertEqual(
            bytes(fake.written),
            runner.image_frame(b"PRE") * 2 + runner.image_frame(b"TARGET"),
        )

    def test_bootloader_ddr_rejection_is_reported(self):
        fake = FakeSerial([b"\x16"])
        with self.assertRaisesRegex(runner.BootloaderReject, "DDR readback"):
            runner.wait_for_marker(
                fake,
                timeout_seconds=0.1,
                pass_marker=b"APP_READY",
                failure_markers=(),
                stage="target",
                rx_sink=lambda _chunk: None,
            )

    def test_bootloader_ack_then_application_marker_passes(self):
        visible = []
        fake = FakeSerial([b"\x06", b"APP_READY\r\n"])
        history = runner.wait_for_marker(
            fake,
            timeout_seconds=0.1,
            pass_marker=b"APP_READY",
            failure_markers=(),
            stage="target",
            rx_sink=visible.append,
            boot_ack_timeout=0.05,
        )
        self.assertIn(b"APP_READY", history)
        self.assertNotIn(b"\x06", b"".join(visible))

    def test_missing_bootloader_reply_requests_fast_retry(self):
        fake = FakeSerial()
        with self.assertRaisesRegex(runner.BootloaderReject, "no bootloader ACK/NAK"):
            runner.wait_for_marker(
                fake,
                timeout_seconds=0.1,
                pass_marker=b"APP_READY",
                failure_markers=(),
                stage="target",
                rx_sink=lambda _chunk: None,
                boot_ack_timeout=0.01,
            )

    def test_console_reload_is_paced_command(self):
        fake = FakeSerial()
        runner.request_console_reload(fake, char_delay=0.0)
        self.assertEqual(bytes(fake.written), b"\rreload\r\n")

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

    def test_platform_failure_marker_stops_target_confirmation(self):
        fake = FakeSerial([b"[PLATFORM] FAIL reason=external_irq\r\n"])
        with self.assertRaises(runner.PreflightError):
            runner.wait_for_marker(
                fake,
                timeout_seconds=0.1,
                pass_marker=b"RTOS_PLATFORM_PASS",
                failure_markers=runner.DEFAULT_TARGET_FAILURE_MARKERS,
                stage="target",
                rx_sink=lambda _chunk: None,
            )

    def test_target_timeout_requests_reload_and_reuploads(self):
        class TargetRetrySerial(FakeSerial):
            def __init__(self):
                super().__init__()
                self.target_writes = 0
                self.pass_sent = False

            def write(self, data):
                if data == b"TARGET":
                    self.target_writes += 1
                return super().write(data)

            def read(self, _size):
                if self.target_writes >= 2 and not self.pass_sent:
                    self.pass_sent = True
                    return b"APP_READY\r\n"
                return b""

        fake = TargetRetrySerial()
        runner.send_image(
            fake,
            b"TARGET",
            preamble=0,
            chunk_delay=0.0,
            sync_settle=0.0,
            header_settle=0.0,
        )
        history = runner.confirm_target_with_retries(
            fake,
            target_payload=b"TARGET",
            target_marker=b"APP_READY",
            target_timeout=0.001,
            preamble=0,
            target_attempts=2,
            retry_delay=0.0,
            chunk_delay=0.0,
            sync_settle=0.0,
            header_settle=0.0,
            rx_sink=lambda _chunk: None,
        )
        self.assertIn(b"APP_READY", history)
        self.assertEqual(fake.target_writes, 2)
        self.assertIn(b"\rreload\r\n", bytes(fake.written))

    def test_target_crc_rejection_reuploads_without_console_reload(self):
        fake = FakeSerial([b"\x15", b"APP_READY\r\n"])
        runner.send_image(
            fake,
            b"TARGET",
            preamble=0,
            chunk_delay=0.0,
            sync_settle=0.0,
            header_settle=0.0,
        )
        history = runner.confirm_target_with_retries(
            fake,
            target_payload=b"TARGET",
            target_marker=b"APP_READY",
            target_timeout=0.1,
            preamble=0,
            target_attempts=2,
            retry_delay=0.0,
            chunk_delay=0.0,
            sync_settle=0.0,
            header_settle=0.0,
            rx_sink=lambda _chunk: None,
        )
        self.assertIn(b"APP_READY", history)
        self.assertEqual(bytes(fake.written).count(b"TARGET"), 2)
        self.assertNotIn(b"reload", bytes(fake.written))


if __name__ == "__main__":
    unittest.main()
