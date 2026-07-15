#!/usr/bin/env python3
"""End-to-end COM-port probe for the FreeRTOS Lua script service."""

import argparse
import sys

try:
    import serial  # type: ignore
except ImportError:
    raise SystemExit("pyserial not found. Install with: pip install pyserial")

import run_lua_script as tool


def expect_result(ser, source, expected, **kwargs):
    payload = source.encode("utf-8")
    result = tool.upload_and_run(ser, payload, **kwargs)
    if result != expected:
        raise RuntimeError(f"expected {expected!r}, received {result!r}")


def probe_bad_crc(ser):
    payload = b"abc"
    monitor = tool.SerialMonitor(ser)
    tool.write_paced(
        ser,
        b"\r@lua run 3 00000000 1000 10000\r\n",
    )
    monitor.wait_for((b"LUA_SCRIPT_RX_READY length=3",), 5.0)
    tool.write_payload(ser, payload, chunk_delay=0.0)
    monitor.wait_for(
        (
            b"LUA_SCRIPT_CRC_ERROR expected=0x00000000 "
            b"actual=0x352441C2",
        ),
        5.0,
    )


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", required=True)
    parser.add_argument("--baud", type=int, default=115200)
    parser.add_argument(
        "--large-bytes",
        type=int,
        default=4096,
        help="large script size to exercise, up to 65536",
    )
    args = parser.parse_args()
    if not 128 <= args.large_bytes <= tool.MAX_SCRIPT_BYTES:
        parser.error("--large-bytes must be 128..65536")

    with serial.Serial(args.port, args.baud, timeout=0.05) as ser:
        try:
            ser.dtr = False
            ser.rts = False
            ser.reset_input_buffer()
        except Exception:
            pass

        expect_result(
            ser,
            """print("PROBE_MULTILINE_START")
local values = {}
local total = 0
for index = 1, 20 do
    values[index] = index * index
    total = total + values[index]
end
assert(total == 2870 and values[20] == 400)
local before = rtos.heartbeat()
rtos.sleep(1100)
assert(rtos.heartbeat() > before)
print("PROBE_MULTILINE_PASS", total)
""",
            b"LUA_SCRIPT_PASS",
            timeout_ms=5000,
            instruction_limit=2_000_000,
        )

        probe_bad_crc(ser)

        expect_result(
            ser,
            'print("RUNTIME_ERROR_PATH")\nerror("probe runtime error")\n',
            b"LUA_SCRIPT_ERROR ",
        )
        expect_result(
            ser,
            "for value = 1, 3 do\n  print(value)\n",
            b"LUA_SCRIPT_ERROR ",
        )
        expect_result(
            ser,
            'print("RECOVERY_AFTER_ERRORS_PASS")\n',
            b"LUA_SCRIPT_PASS",
        )

        infinite = 'print("GUARD_TEST_START")\nwhile true do end\n'
        expect_result(
            ser,
            infinite,
            b"LUA_SCRIPT_TIMEOUT",
            timeout_ms=500,
            instruction_limit=100_000_000,
        )
        expect_result(
            ser,
            infinite,
            b"LUA_SCRIPT_LIMIT",
            timeout_ms=10000,
            instruction_limit=5000,
        )

        result = tool.upload_and_run(
            ser,
            infinite.encode("ascii"),
            timeout_ms=60000,
            instruction_limit=100_000_000,
            detach=True,
        )
        if result != b"LUA_SCRIPT_START length=":
            raise RuntimeError(f"detach failed: {result!r}")
        if tool.send_stop(ser) != b"LUA_SCRIPT_STOPPED":
            raise RuntimeError("external stop did not stop the script")

        suffix = b"\nprint('PROBE_LARGE_SCRIPT_PASS')\n"
        large_payload = (
            b"--"
            + b"x" * (args.large_bytes - 2 - len(suffix))
            + suffix
        )
        result = tool.upload_and_run(
            ser,
            large_payload,
            timeout_ms=15000,
            instruction_limit=2_000_000,
        )
        if result != b"LUA_SCRIPT_PASS":
            raise RuntimeError(f"large script failed: {result!r}")

        if tool.request_status(ser) != b"LUA_SCRIPT_STATUS ready=":
            raise RuntimeError("final status query failed")

    print("[LUA SCRIPT PROBE] PASS: all script service checks responded.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, RuntimeError, TimeoutError) as exc:
        print(f"[LUA SCRIPT PROBE] FAIL: {exc}", file=sys.stderr)
        raise SystemExit(1)
