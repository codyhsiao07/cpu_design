#!/usr/bin/env python3
"""Exercise the interactive Lua game and UART line-input path on a board."""

import argparse
from pathlib import Path
import sys

try:
    import serial  # type: ignore
except ImportError:
    raise SystemExit("pyserial not found. Install with: pip install pyserial")

import run_lua_script as tool


def send_line(ser, monitor, text, expected):
    tool.write_paced(ser, text.encode("ascii") + b"\r\n", char_delay=0.0)
    monitor.wait_for((expected,), 5.0)


def main():
    repo_root = Path(__file__).resolve().parents[1]
    default_game = repo_root / "lua_apps" / "guess_number.lua"

    parser = argparse.ArgumentParser(
        description="Verify the interactive Lua guessing game on an FPGA board."
    )
    parser.add_argument("--port", required=True)
    parser.add_argument("--baud", type=int, default=115200)
    parser.add_argument("--file", type=Path, default=default_game)
    args = parser.parse_args()

    source = args.file.read_bytes()
    payload = b"GAME_TEST_SECRET = 7\n" + source

    with serial.Serial(args.port, args.baud, timeout=0.05) as ser:
        try:
            ser.dtr = False
            ser.rts = False
            ser.reset_input_buffer()
        except Exception:
            pass

        monitor = tool.SerialMonitor(ser)
        result = tool.upload_and_run(
            ser,
            payload,
            timeout_ms=180000,
            instruction_limit=5_000_000,
            detach=True,
            monitor=monitor,
        )
        if result != b"LUA_SCRIPT_START length=":
            raise RuntimeError(f"game did not start: {result!r}")

        monitor.wait_for((b"GAME_READY range=1..20 attempts=6",), 5.0)
        send_line(ser, monitor, "abc", b"GAME_INVALID enter=1..20")
        send_line(ser, monitor, "3", b"GAME_LOW\t3")
        send_line(ser, monitor, "9", b"GAME_HIGH\t9")
        send_line(ser, monitor, "7", b"GAME_WIN attempts=\t3")
        monitor.wait_for((b"LUA_SCRIPT_PASS",), 5.0)

        if tool.request_status(ser) != b"LUA_SCRIPT_STATUS ready=":
            raise RuntimeError("Lua service did not return to idle")

    print("[LUA GAME PROBE] PASS: input, hints, win, and recovery verified.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, RuntimeError, TimeoutError) as exc:
        print(f"[LUA GAME PROBE] FAIL: {exc}", file=sys.stderr)
        raise SystemExit(1)
