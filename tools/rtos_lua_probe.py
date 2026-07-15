#!/usr/bin/env python3
"""Exercise the interrupt-driven FreeRTOS Lua REPL over UART."""

import argparse
import sys
import time

try:
    import serial  # type: ignore
except ImportError:
    raise SystemExit("pyserial not found. Install with: pip install pyserial")


CHECKS = (
    ("print(_VERSION)", b"\r\nLua 5.4\r\n", 4.0),
    ("6 * 7", b"\r\n=> 42\r\n", 4.0),
    (
        'local t={}; for i=1,10 do t[i]=i*i end; print("TABLE_PASS",t[10],#t)',
        b"\r\nTABLE_PASS\t100\t10\r\n",
        5.0,
    ),
    (
        'print("STRING_MATH_PASS",string.upper("fpga"),string.sub("FreeRTOS",5),math.floor(7.75),math.sqrt(81))',
        b"\r\nSTRING_MATH_PASS\tFPGA\tRTOS\t7.0\t9.0\r\n",
        5.0,
    ),
    ("rtos.ping()", b"\r\nLUA_RTOS_PONG tick=", 4.0),
    ('error("probe_error")', b"\r\nLUA_ERROR ", 4.0),
    ('print("LUA_RECOVERY_PASS")', b"\r\nLUA_RECOVERY_PASS\r\n", 4.0),
    (
        'local s=0; for i=1,10000 do s=s+i end; print("LOOP_PASS",s)',
        b"\r\nLOOP_PASS\t50005000\r\n",
        8.0,
    ),
    (
        'local h=rtos.heartbeat(); rtos.sleep(1100); assert(rtos.heartbeat()>h); print("HEARTBEAT_PASS")',
        b"\r\nHEARTBEAT_PASS\r\n",
        6.0,
    ),
    ("rtos.status()", b"\r\nLUA_RTOS_STATUS tick=", 4.0),
)

FAILURE_MARKERS = (
    b"[LUA] FATAL",
    b"[LUA] PANIC",
    b"[LUA] abort",
    b"[RTOS] exception",
    b"[RTOS] unexpected interrupt",
)


def send_paced(ser, text, char_delay):
    # CRLF gives the FPGA receiver a second line-submit byte if an isolated
    # final CR is lost; the RX task already suppresses LF after a received CR.
    for byte in (text + "\r\n").encode("ascii"):
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
        if any(failure in history for failure in FAILURE_MARKERS):
            return None
        if marker in history:
            return bytes(history)
        if len(history) > 32768:
            del history[:-32768]
    return None


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", required=True)
    parser.add_argument("--baud", type=int, default=115200)
    parser.add_argument("--char-delay", type=float, default=0.002)
    args = parser.parse_args()

    with serial.Serial(args.port, args.baud, timeout=0.05) as ser:
        try:
            ser.dtr = False
            ser.rts = False
            ser.reset_input_buffer()
        except Exception:
            pass

        # Complete and discard any partial line left by an earlier terminal.
        send_paced(ser, "", args.char_delay)
        if wait_for(ser, b"lua> ", 5.0) is None:
            print("[LUA PROBE] FAIL: could not synchronize to lua prompt", file=sys.stderr)
            return 1
        try:
            ser.reset_input_buffer()
        except Exception:
            pass

        for command, marker, timeout in CHECKS:
            print(f"\n[LUA PROBE] command={command}", file=sys.stderr)
            send_paced(ser, command, args.char_delay)
            history = wait_for(ser, marker, timeout)
            if history is None:
                print(
                    f"[LUA PROBE] FAIL: no marker {marker!r}",
                    file=sys.stderr,
                )
                return 1
            if b"lua> " not in history and wait_for(ser, b"lua> ", 5.0) is None:
                print("[LUA PROBE] FAIL: result did not return to prompt", file=sys.stderr)
                return 1
            print(f"[LUA PROBE] PASS: {marker!r}", file=sys.stderr)

    print("[LUA PROBE] PASS: all Lua/RTOS REPL checks responded.", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
