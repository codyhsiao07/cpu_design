#!/usr/bin/env python3
"""Verify a running RTOS Platform image through interrupt-driven UART RX."""

import argparse
import sys
import time

try:
    import serial  # type: ignore
except ImportError:
    raise SystemExit("pyserial not found. Install with: pip install pyserial")


CHECKS = (
    ("irqping", b"UART_IRQ_PASS count="),
    ("stats", b"PLATFORM_STATS tick="),
)


def send_paced(ser, text, char_delay):
    for byte in (text + "\r").encode("ascii"):
        ser.write(bytes((byte,)))
        ser.flush()
        time.sleep(char_delay)


def wait_for(ser, marker, timeout):
    deadline = time.monotonic() + timeout
    history = bytearray()
    while time.monotonic() < deadline:
        chunk = ser.read(4096)
        if not chunk:
            continue
        sys.stdout.buffer.write(chunk)
        sys.stdout.buffer.flush()
        history += chunk
        if b"[PLATFORM] FAIL" in history or b"[RTOS] exception" in history:
            return False
        if marker in history:
            return True
        if len(history) > 16384:
            del history[:-16384]
    return False


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", required=True)
    parser.add_argument("--baud", type=int, default=115200)
    parser.add_argument("--char-delay", type=float, default=0.002)
    parser.add_argument("--timeout", type=float, default=4.0)
    args = parser.parse_args()

    with serial.Serial(args.port, args.baud, timeout=0.05) as ser:
        try:
            ser.dtr = False
            ser.rts = False
            ser.reset_input_buffer()
        except Exception:
            pass

        for command, marker in CHECKS:
            print(f"\n[PLATFORM PROBE] command={command}", file=sys.stderr)
            send_paced(ser, command, args.char_delay)
            if not wait_for(ser, marker, args.timeout):
                print(
                    f"[PLATFORM PROBE] FAIL: no marker {marker.decode('ascii')!r}",
                    file=sys.stderr,
                )
                return 1
            print(
                f"[PLATFORM PROBE] PASS: {marker.decode('ascii')}",
                file=sys.stderr,
            )

    print("[PLATFORM PROBE] PASS: interrupt-driven UART is responsive.", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
