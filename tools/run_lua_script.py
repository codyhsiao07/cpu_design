#!/usr/bin/env python3
"""Upload, run, stop, or inspect a Lua script on the FreeRTOS Lua target."""

import argparse
import select
import sys
import time
import zlib

try:
    import serial  # type: ignore
except ImportError:
    serial = None

try:
    import msvcrt
except ImportError:
    msvcrt = None

from uart_keys import windows_key_to_uart


MAX_SCRIPT_BYTES = 65536
DEFAULT_TIMEOUT_MS = 10000
DEFAULT_INSTRUCTION_LIMIT = 2_000_000

FATAL_MARKERS = (
    b"[LUA] FATAL",
    b"[LUA] PANIC",
    b"[LUA] abort",
    b"[RTOS] exception",
    b"[RTOS] unexpected interrupt",
    b"LUA_SCRIPT_ALLOC_ERROR",
    b"LUA_SCRIPT_QUEUE_ERROR",
)

FINAL_MARKERS = (
    b"LUA_SCRIPT_PASS",
    b"LUA_SCRIPT_ERROR ",
    b"LUA_SCRIPT_STOPPED",
    b"LUA_SCRIPT_TIMEOUT",
    b"LUA_SCRIPT_LIMIT",
)


def script_crc32(payload):
    return zlib.crc32(payload) & 0xFFFFFFFF


def build_run_control(payload, timeout_ms, instruction_limit):
    if len(payload) > MAX_SCRIPT_BYTES:
        raise ValueError(f"script exceeds {MAX_SCRIPT_BYTES} bytes")
    if not 1 <= timeout_ms <= 600_000:
        raise ValueError("timeout_ms must be 1..600000")
    if not 100 <= instruction_limit <= 100_000_000:
        raise ValueError("instruction_limit must be 100..100000000")
    return (
        f"@lua run {len(payload)} {script_crc32(payload):08X} "
        f"{timeout_ms} {instruction_limit}\r\n"
    ).encode("ascii")


def write_paced(ser, data, char_delay=0.002):
    for byte in data:
        ser.write(bytes((byte,)))
        ser.flush()
        if char_delay > 0:
            time.sleep(char_delay)


def write_payload(ser, payload, chunk_size=64, chunk_delay=0.001):
    for offset in range(0, len(payload), chunk_size):
        ser.write(payload[offset : offset + chunk_size])
        ser.flush()
        if chunk_delay > 0:
            time.sleep(chunk_delay)


class SerialMonitor:
    def __init__(self, ser, sink=None):
        self.ser = ser
        self.sink = sink if sink is not None else self._stdout_sink
        self.history = bytearray()

    @staticmethod
    def _stdout_sink(chunk):
        sys.stdout.buffer.write(chunk)
        sys.stdout.buffer.flush()

    def feed(self, chunk):
        if not chunk:
            return
        self.sink(chunk)
        self.history += chunk
        if len(self.history) > 262144:
            del self.history[:-262144]

    def find_first(self, markers):
        matches = [
            (self.history.find(marker), marker)
            for marker in markers
            if marker in self.history
        ]
        if not matches:
            return None
        return min(matches, key=lambda item: item[0])[1]

    def wait_for(self, markers, timeout, fatal_markers=FATAL_MARKERS):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            for fatal in fatal_markers:
                if fatal in self.history:
                    raise RuntimeError(f"target failure marker: {fatal!r}")
            match = self.find_first(markers)
            if match is not None:
                return match
            chunk = self.ser.read(4096)
            if not chunk:
                continue
            self.feed(chunk)
        raise TimeoutError(f"no marker {markers!r} within {timeout:.1f}s")


def upload_and_run(
    ser,
    payload,
    timeout_ms=DEFAULT_TIMEOUT_MS,
    instruction_limit=DEFAULT_INSTRUCTION_LIMIT,
    detach=False,
    char_delay=0.002,
    chunk_size=64,
    chunk_delay=0.001,
    result_timeout=None,
    sink=None,
    monitor=None,
):
    if monitor is None:
        monitor = SerialMonitor(ser, sink=sink)
    control = build_run_control(payload, timeout_ms, instruction_limit)

    write_paced(ser, b"\r" + control, char_delay=char_delay)
    ready = f"LUA_SCRIPT_RX_READY length={len(payload)}".encode("ascii")
    monitor.wait_for(
        (ready,),
        5.0,
        fatal_markers=FATAL_MARKERS
        + (
            b"LUA_SCRIPT_HEADER_ERROR",
            b"LUA_SCRIPT_BUSY",
            b"LUA_SCRIPT_NOT_READY",
        ),
    )
    write_payload(
        ser,
        payload,
        chunk_size=chunk_size,
        chunk_delay=chunk_delay,
    )
    monitor.wait_for(
        (b"LUA_SCRIPT_ACCEPTED length=",),
        5.0,
        fatal_markers=FATAL_MARKERS
        + (b"LUA_SCRIPT_CRC_ERROR", b"LUA_SCRIPT_RX_TIMEOUT"),
    )
    monitor.wait_for((b"LUA_SCRIPT_START length=",), 5.0)
    if detach:
        return b"LUA_SCRIPT_START length="
    if result_timeout is None:
        result_timeout = timeout_ms / 1000.0 + 5.0
    return monitor.wait_for(FINAL_MARKERS, result_timeout)


def interactive_session(ser, monitor=None, timeout=300.0):
    """Forward keyboard input until the active Lua script reports a result."""
    if monitor is None:
        monitor = SerialMonitor(ser)
    deadline = time.monotonic() + timeout
    print(
        "Interactive Lua script. Enter sends a line; Ctrl+C stops the script.",
        file=sys.stderr,
    )

    try:
        while time.monotonic() < deadline:
            fatal = monitor.find_first(FATAL_MARKERS)
            if fatal is not None:
                raise RuntimeError(f"target failure marker: {fatal!r}")
            result = monitor.find_first(FINAL_MARKERS)
            if result is not None:
                return result

            chunk = ser.read(4096)
            monitor.feed(chunk)

            if msvcrt is not None:
                while msvcrt.kbhit():
                    char = msvcrt.getwch()
                    if char == "\x03":
                        raise KeyboardInterrupt
                    extended = None
                    if char in ("\x00", "\xe0"):
                        extended = msvcrt.getwch()
                    data = windows_key_to_uart(char, extended)
                    if data:
                        ser.write(data)
                        ser.flush()
            else:
                readable, _, _ = select.select([sys.stdin], [], [], 0)
                if readable:
                    line = sys.stdin.readline()
                    if line == "":
                        raise KeyboardInterrupt
                    ser.write(line.rstrip("\r\n").encode("utf-8") + b"\r\n")
                    ser.flush()
            time.sleep(0.005)
    except KeyboardInterrupt:
        print("Stopping the active Lua script...", file=sys.stderr)
        write_paced(ser, b"\r@lua stop\r\n", char_delay=0.0)
        return monitor.wait_for(FINAL_MARKERS, 5.0)

    raise TimeoutError(f"interactive script did not finish within {timeout:.1f}s")


def send_stop(ser, wait=True, char_delay=0.002, sink=None):
    monitor = SerialMonitor(ser, sink=sink)
    write_paced(ser, b"\r@lua stop\r\n", char_delay=char_delay)
    marker = monitor.wait_for(
        (b"LUA_SCRIPT_STOP_REQUESTED", b"LUA_SCRIPT_IDLE"),
        5.0,
    )
    if marker == b"LUA_SCRIPT_STOP_REQUESTED" and wait:
        return monitor.wait_for(
            (
                b"LUA_SCRIPT_STOPPED",
                b"LUA_SCRIPT_TIMEOUT",
                b"LUA_SCRIPT_LIMIT",
            ),
            5.0,
        )
    return marker


def request_status(ser, char_delay=0.002, sink=None):
    monitor = SerialMonitor(ser, sink=sink)
    write_paced(ser, b"\r@lua status\r\n", char_delay=char_delay)
    return monitor.wait_for((b"LUA_SCRIPT_STATUS ready=",), 5.0)


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Upload and execute a multiline Lua script over UART."
    )
    parser.add_argument("--port", required=True)
    parser.add_argument("--baud", type=int, default=115200)
    action = parser.add_mutually_exclusive_group(required=True)
    action.add_argument("--file", help="Lua source file to upload and run")
    action.add_argument("--stop", action="store_true", help="stop the active script")
    action.add_argument("--status", action="store_true", help="query script state")
    parser.add_argument("--timeout-ms", type=int, default=DEFAULT_TIMEOUT_MS)
    parser.add_argument(
        "--instruction-limit", type=int, default=DEFAULT_INSTRUCTION_LIMIT
    )
    parser.add_argument(
        "--detach",
        action="store_true",
        help="return after the script starts so another process can send --stop",
    )
    parser.add_argument(
        "--interactive",
        action="store_true",
        help="forward keyboard input after the uploaded script starts",
    )
    parser.add_argument("--result-timeout", type=float)
    parser.add_argument("--char-delay", type=float, default=0.002)
    parser.add_argument("--chunk-size", type=int, default=64)
    parser.add_argument("--chunk-delay", type=float, default=0.001)
    args = parser.parse_args(argv)

    if serial is None:
        parser.error("pyserial not found. Install with: pip install pyserial")
    if args.chunk_size < 1 or args.chunk_size > 4096:
        parser.error("--chunk-size must be 1..4096")
    if args.interactive and not args.file:
        parser.error("--interactive requires --file")
    if args.interactive and args.detach:
        parser.error("choose either --interactive or --detach")

    payload = None
    if args.file:
        try:
            with open(args.file, "rb") as source_file:
                payload = source_file.read(MAX_SCRIPT_BYTES + 1)
            if len(payload) > MAX_SCRIPT_BYTES:
                parser.error(f"script exceeds {MAX_SCRIPT_BYTES} bytes")
            build_run_control(payload, args.timeout_ms, args.instruction_limit)
        except OSError as exc:
            parser.error(str(exc))
        except ValueError as exc:
            parser.error(str(exc))

    try:
        with serial.Serial(args.port, args.baud, timeout=0.05) as ser:
            try:
                ser.dtr = False
                ser.rts = False
                ser.reset_input_buffer()
            except Exception:
                pass

            if args.stop:
                result = send_stop(
                    ser,
                    wait=not args.detach,
                    char_delay=args.char_delay,
                )
            elif args.status:
                result = request_status(ser, char_delay=args.char_delay)
            elif args.interactive:
                monitor = SerialMonitor(ser)
                upload_and_run(
                    ser,
                    payload,
                    timeout_ms=args.timeout_ms,
                    instruction_limit=args.instruction_limit,
                    detach=True,
                    char_delay=args.char_delay,
                    chunk_size=args.chunk_size,
                    chunk_delay=args.chunk_delay,
                    monitor=monitor,
                )
                interactive_timeout = args.result_timeout
                if interactive_timeout is None:
                    interactive_timeout = args.timeout_ms / 1000.0 + 5.0
                result = interactive_session(
                    ser,
                    monitor=monitor,
                    timeout=interactive_timeout,
                )
            else:
                result = upload_and_run(
                    ser,
                    payload,
                    timeout_ms=args.timeout_ms,
                    instruction_limit=args.instruction_limit,
                    detach=args.detach,
                    char_delay=args.char_delay,
                    chunk_size=args.chunk_size,
                    chunk_delay=args.chunk_delay,
                    result_timeout=args.result_timeout,
                )
    except (OSError, RuntimeError, TimeoutError) as exc:
        print(f"Lua script tool failed: {exc}", file=sys.stderr)
        return 2

    if result in (b"LUA_SCRIPT_PASS", b"LUA_SCRIPT_START length="):
        print("[LUA SCRIPT] PASS", file=sys.stderr)
        return 0
    if args.stop or args.status:
        print(f"[LUA SCRIPT] {result.decode('ascii', errors='replace')}", file=sys.stderr)
        return 0
    print(f"[LUA SCRIPT] target result: {result!r}", file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
