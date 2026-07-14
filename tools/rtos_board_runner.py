#!/usr/bin/env python3
"""Two-stage RTOS FPGA uploader: preflight first, selected application second."""

import argparse
import os
import struct
import sys
import threading
import time

try:
    import serial  # type: ignore
except ImportError:  # Kept optional so --dry-run and unit tests remain useful.
    serial = None

try:
    import msvcrt
except ImportError:
    msvcrt = None


SYNC_WORD = 0xC0DE5A5A
DEFAULT_PASS_MARKER = b"RTOS_PREFLIGHT_PASS"
DEFAULT_FAILURE_MARKERS = (
    b"RTOS_PREFLIGHT_FAIL",
    b"[RTOS] fatal",
    b"[TRAP]",
    b"ASSERT",
)
DEFAULT_TARGET_FAILURE_MARKERS = (
    b"[RTOS] fatal",
    b"[VGA] fatal",
    b"[PIPE] fatal",
    b"[TRAP]",
    b"ASSERT",
)


class PreflightError(RuntimeError):
    pass


class MarkerTimeout(PreflightError):
    pass


def load_mem(path):
    data = bytearray()
    with open(path, "r", encoding="ascii") as mem_file:
        for line_number, line in enumerate(mem_file, start=1):
            text = line.strip()
            if not text or text.startswith("//"):
                continue
            try:
                word = int(text, 16)
            except ValueError as exc:
                raise ValueError(f"{path}:{line_number}: invalid hex word {text!r}") from exc
            if word < 0 or word > 0xFFFFFFFF:
                raise ValueError(f"{path}:{line_number}: word exceeds 32 bits")
            data += word.to_bytes(4, "little")
    if not data:
        raise ValueError(f"{path}: image is empty")
    return bytes(data)


def image_frame(payload):
    return struct.pack("<II", SYNC_WORD, len(payload)) + payload


def send_image(ser, payload, preamble=8192):
    remaining = max(0, int(preamble))
    leader = b"\x55" * 4096
    while remaining:
        count = min(remaining, len(leader))
        ser.write(leader[:count])
        remaining -= count
    ser.write(image_frame(payload))
    ser.flush()


def _default_rx_sink(chunk):
    sys.stdout.buffer.write(chunk)
    sys.stdout.buffer.flush()


def wait_for_marker(
    ser,
    timeout_seconds,
    pass_marker,
    failure_markers,
    stage,
    rx_sink=_default_rx_sink,
):
    deadline = time.monotonic() + max(0.0, timeout_seconds)
    history = bytearray()
    ser.timeout = min(0.1, max(0.01, timeout_seconds))

    while time.monotonic() < deadline:
        chunk = ser.read(4096)
        if not chunk:
            continue
        rx_sink(chunk)
        history += chunk
        if len(history) > 16384:
            del history[:-16384]

        for marker in failure_markers:
            if marker and marker in history:
                raise PreflightError(
                    f"{stage} reported failure marker {marker.decode('ascii', errors='replace')!r}"
                )
        if pass_marker in history:
            return bytes(history)

    raise MarkerTimeout(
        f"{stage} did not report {pass_marker.decode('ascii', errors='replace')!r} "
        f"within {timeout_seconds:.1f}s"
    )


def wait_for_preflight(ser, timeout_seconds, rx_sink=_default_rx_sink):
    return wait_for_marker(
        ser,
        timeout_seconds=timeout_seconds,
        pass_marker=DEFAULT_PASS_MARKER,
        failure_markers=DEFAULT_FAILURE_MARKERS,
        stage="preflight",
        rx_sink=rx_sink,
    )


def pump_rx_for(ser, seconds, rx_sink=_default_rx_sink):
    deadline = time.monotonic() + max(0.0, seconds)
    ser.timeout = min(0.05, max(0.01, seconds))
    while time.monotonic() < deadline:
        chunk = ser.read(4096)
        if chunk:
            rx_sink(chunk)


def write_paced(ser, data, char_delay=0.002):
    for byte in data:
        ser.write(bytes((byte,)))
        ser.flush()
        if char_delay > 0:
            time.sleep(char_delay)


def request_console_reload(ser, char_delay=0.002):
    # A leading CR clears any partially typed line from an earlier terminal.
    # A bootloader that is already waiting simply ignores these non-sync bytes.
    write_paced(ser, b"\rreload\r", char_delay=char_delay)


def run_two_stage(
    ser,
    preflight_payload,
    target_payload,
    preamble=8192,
    preflight_timeout=20.0,
    target_delay=5.0,
    preflight_attempts=1,
    retry_delay=0.5,
    rx_sink=_default_rx_sink,
    status_sink=None,
):
    attempts = max(1, int(preflight_attempts))
    for attempt in range(1, attempts + 1):
        send_image(ser, preflight_payload, preamble=preamble)
        try:
            wait_for_preflight(
                ser,
                timeout_seconds=preflight_timeout,
                rx_sink=rx_sink,
            )
            break
        except MarkerTimeout:
            if attempt >= attempts:
                raise
            if status_sink is not None:
                status_sink(
                    f"Preflight attempt {attempt}/{attempts} timed out; retrying upload..."
                )
            pump_rx_for(ser, retry_delay, rx_sink=rx_sink)

    # The preflight drains UART TX, then hardware uses a 100 ms arm interval
    # before bootloader rearm. Keep receiving during a conservative margin.
    pump_rx_for(ser, target_delay, rx_sink=rx_sink)
    send_image(ser, target_payload, preamble=preamble)


def confirm_target_with_retries(
    ser,
    target_payload,
    target_marker,
    target_timeout,
    preamble=8192,
    target_attempts=1,
    retry_delay=5.0,
    rx_sink=_default_rx_sink,
    status_sink=None,
):
    attempts = max(1, int(target_attempts))
    for attempt in range(1, attempts + 1):
        try:
            return wait_for_marker(
                ser,
                timeout_seconds=target_timeout,
                pass_marker=target_marker,
                failure_markers=DEFAULT_TARGET_FAILURE_MARKERS,
                stage="target",
                rx_sink=rx_sink,
            )
        except MarkerTimeout:
            if attempt >= attempts:
                raise
            if status_sink is not None:
                status_sink(
                    f"Target attempt {attempt}/{attempts} timed out; "
                    "requesting reload and retrying upload..."
                )
            # If the target did start but its marker was lost, this returns a
            # compatible Console to the loader. If it never started, the
            # waiting bootloader safely ignores the non-sync command bytes.
            request_console_reload(ser)
            pump_rx_for(ser, retry_delay, rx_sink=rx_sink)
            send_image(ser, target_payload, preamble=preamble)


def listen_for_rx(ser, idle_seconds, rx_sink=_default_rx_sink):
    ser.timeout = 0.1
    deadline = time.monotonic() + max(0.0, idle_seconds)
    while time.monotonic() < deadline:
        chunk = ser.read(4096)
        if chunk:
            rx_sink(chunk)
            deadline = time.monotonic() + max(0.0, idle_seconds)


def interactive_terminal(ser, rx_sink=_default_rx_sink):
    stop_event = threading.Event()

    def rx_worker():
        ser.timeout = 0.1
        while not stop_event.is_set():
            try:
                chunk = ser.read(4096)
            except Exception:
                break
            if chunk:
                rx_sink(chunk)

    thread = threading.Thread(target=rx_worker, daemon=True)
    thread.start()
    print("Interactive UART terminal. Ctrl+C to exit.", file=sys.stderr)
    try:
        if msvcrt is not None:
            while True:
                if not msvcrt.kbhit():
                    time.sleep(0.01)
                    continue
                char = msvcrt.getwch()
                if char == "\x03":
                    raise KeyboardInterrupt
                if char == "\r":
                    write_paced(ser, b"\r\n")
                elif char != "\x08":
                    write_paced(ser, char.encode("ascii", errors="ignore"))
        else:
            for line in sys.stdin:
                write_paced(ser, line.encode("ascii", errors="ignore"))
    except KeyboardInterrupt:
        pass
    finally:
        stop_event.set()
        thread.join(timeout=0.5)


def parse_args(argv=None):
    parser = argparse.ArgumentParser(
        description="Run an RTOS preflight image, then upload a selected target image."
    )
    parser.add_argument("--port", help="UART port, for example COM5")
    parser.add_argument("--baud", type=int, default=115200)
    parser.add_argument("--preflight-mem", required=True)
    parser.add_argument("--target-mem", required=True)
    parser.add_argument("--startup-delay", type=float, default=5.0)
    parser.add_argument("--target-delay", type=float, default=5.0)
    parser.add_argument("--preflight-timeout", type=float, default=20.0)
    parser.add_argument("--preflight-attempts", type=int, default=2)
    parser.add_argument("--target-marker", default="")
    parser.add_argument("--target-timeout", type=float, default=20.0)
    parser.add_argument("--target-attempts", type=int, default=2)
    parser.add_argument("--preamble", type=int, default=8192)
    parser.add_argument(
        "--skip-auto-reload",
        action="store_true",
        help="do not send a paced reload command before the first upload",
    )
    parser.add_argument(
        "--monitor", choices=("interactive", "listen", "none"), default="interactive"
    )
    parser.add_argument("--listen-seconds", type=float, default=5.0)
    parser.add_argument("--log", default="", help="optional raw UART log file")
    parser.add_argument("--dry-run", action="store_true", help="validate images without opening UART")
    args = parser.parse_args(argv)
    if not args.dry_run and not args.port:
        parser.error("--port is required unless --dry-run is used")
    if args.preamble < 0:
        parser.error("--preamble must be non-negative")
    if args.preflight_attempts < 1:
        parser.error("--preflight-attempts must be at least 1")
    if args.target_attempts < 1:
        parser.error("--target-attempts must be at least 1")
    return args


def main(argv=None):
    args = parse_args(argv)
    try:
        preflight_payload = load_mem(args.preflight_mem)
        target_payload = load_mem(args.target_mem)
    except (OSError, ValueError) as exc:
        print(f"Image error: {exc}", file=sys.stderr)
        return 2

    print(f"Preflight: {os.path.abspath(args.preflight_mem)} ({len(preflight_payload)} bytes)")
    print(f"Target:    {os.path.abspath(args.target_mem)} ({len(target_payload)} bytes)")
    if args.dry_run:
        print("Dry run passed: both images and upload frames are valid.")
        return 0
    if serial is None:
        print("pyserial not found. Install with: pip install pyserial", file=sys.stderr)
        return 2

    log_file = None

    def rx_sink(chunk):
        _default_rx_sink(chunk)
        if log_file is not None:
            log_file.write(chunk)
            log_file.flush()

    try:
        if args.log:
            log_file = open(args.log, "ab")
        with serial.Serial(args.port, args.baud, timeout=0.1) as ser:
            try:
                ser.dtr = False
                ser.rts = False
                ser.reset_input_buffer()
                ser.reset_output_buffer()
            except Exception:
                pass

            if not args.skip_auto_reload:
                print(
                    "Requesting bootloader rearm from any running RTOS Console...",
                    file=sys.stderr,
                )
                time.sleep(0.1)
                request_console_reload(ser)
                pump_rx_for(ser, 0.5, rx_sink=rx_sink)

            if args.startup_delay > 0:
                print(
                    f"Waiting {args.startup_delay:.1f}s for FPGA DDR/bootloader...",
                    file=sys.stderr,
                )
                time.sleep(args.startup_delay)

            print(
                f"Uploading RTOS preflight (up to {args.preflight_attempts} attempts)...",
                file=sys.stderr,
            )
            try:
                run_two_stage(
                    ser,
                    preflight_payload,
                    target_payload,
                    preamble=args.preamble,
                    preflight_timeout=args.preflight_timeout,
                    target_delay=args.target_delay,
                    preflight_attempts=args.preflight_attempts,
                    rx_sink=rx_sink,
                    status_sink=lambda message: print(message, file=sys.stderr),
                )
            except MarkerTimeout as exc:
                raise PreflightError(
                    f"{exc}; automatic Console reload and upload retry did not recover "
                    "the board. Press CPU RESET and try again"
                ) from exc
            print("Preflight passed; target image sent for bootloader verification.", file=sys.stderr)
            if args.target_marker:
                marker = args.target_marker.encode("ascii")
                confirm_target_with_retries(
                    ser,
                    target_payload=target_payload,
                    target_marker=marker,
                    target_timeout=args.target_timeout,
                    preamble=args.preamble,
                    target_attempts=args.target_attempts,
                    retry_delay=args.target_delay,
                    rx_sink=rx_sink,
                    status_sink=lambda message: print(message, file=sys.stderr),
                )
                print(f"Target confirmed by marker: {args.target_marker}", file=sys.stderr)

            if args.monitor == "listen":
                listen_for_rx(ser, args.listen_seconds, rx_sink=rx_sink)
            elif args.monitor == "interactive":
                interactive_terminal(ser, rx_sink=rx_sink)
    except PreflightError as exc:
        print(f"RTOS board run stopped: {exc}", file=sys.stderr)
        return 3
    except Exception as exc:
        print(f"UART error: {exc}", file=sys.stderr)
        return 4
    finally:
        if log_file is not None:
            log_file.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
