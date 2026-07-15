import argparse
import os
import struct
import sys
import threading
import time
import zlib

try:
    import serial  # pyserial
except ImportError:
    raise SystemExit("pyserial not found. Install with: pip install pyserial")

try:
    import msvcrt
except ImportError:
    msvcrt = None

from tools.uart_keys import windows_key_to_uart

SYNC_WORD_V1 = 0xC0DE5A5A
SYNC_WORD_V2 = 0xC0DE5A5B


def load_mem(path):
    data = bytearray()
    with open(path, "r") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("//"):
                continue
            word = int(line, 16) & 0xFFFFFFFF
            data += word.to_bytes(4, "little")
    return data


def payload_crc32(payload):
    return zlib.crc32(payload) & 0xFFFFFFFF


def image_header(payload, protocol):
    if protocol == "v1":
        return struct.pack("<II", SYNC_WORD_V1, len(payload))
    return struct.pack("<III", SYNC_WORD_V2, len(payload), payload_crc32(payload))


def write_all(ser, data):
    offset = 0
    while offset < len(data):
        written = ser.write(data[offset:])
        if written is None:
            written = len(data) - offset
        if written <= 0:
            raise OSError("serial write made no progress")
        offset += written


def send_image(
    ser,
    payload,
    protocol="v2",
    preamble=4096,
    chunk_size=32,
    chunk_delay=0.001,
    sync_settle=0.02,
    header_settle=0.005,
):
    leader = b"\x55" * 4096
    remaining = preamble
    while remaining > 0:
        count = min(remaining, len(leader))
        write_all(ser, leader[:count])
        remaining -= count
    ser.flush()

    header = image_header(payload, protocol)
    write_all(ser, header[:4])
    ser.flush()
    if sync_settle > 0:
        time.sleep(sync_settle)
    write_all(ser, header[4:])
    ser.flush()
    if header_settle > 0:
        time.sleep(header_settle)

    for offset in range(0, len(payload), chunk_size):
        write_all(ser, payload[offset : offset + chunk_size])
        ser.flush()
        if chunk_delay > 0 and offset + chunk_size < len(payload):
            time.sleep(chunk_delay)


def wait_for_boot_reply(ser, timeout_seconds):
    deadline = time.monotonic() + max(0.0, timeout_seconds)
    pending_output = bytearray()
    ser.timeout = min(0.1, max(0.01, timeout_seconds))
    while time.monotonic() < deadline:
        chunk = ser.read(4096)
        if not chunk:
            continue
        pending_output += chunk.replace(b"\x06", b"").replace(
            b"\x15", b""
        ).replace(b"\x16", b"")
        if b"\x15" in chunk:
            return False, "payload CRC mismatch", bytes(pending_output)
        if b"\x16" in chunk:
            return False, "DDR readback mismatch", bytes(pending_output)
        if b"\x06" in chunk:
            return True, "accepted", bytes(pending_output)
    return False, "no ACK/NAK", bytes(pending_output)


def listen_for_rx(ser, idle_seconds):
    ser.timeout = 0.1
    idle_deadline = time.time() + max(idle_seconds, 0.0)
    got_any = False
    last_chunk = b""
    print(f"Listening on {ser.port} for up to {idle_seconds:.1f}s of RX idle time...",
          file=sys.stderr)
    while time.time() < idle_deadline:
        chunk = ser.read(4096)
        if not chunk:
            continue
        got_any = True
        last_chunk = chunk
        idle_deadline = time.time() + max(idle_seconds, 0.0)
        sys.stdout.buffer.write(chunk)
        sys.stdout.buffer.flush()
    if got_any:
        if not last_chunk.endswith(b"\n"):
            sys.stdout.write("\n")
            sys.stdout.flush()
    else:
        print("No RX data observed during listen window.", file=sys.stderr)


def interactive_hint_for_mem(mem_path):
    name = os.path.basename(mem_path).lower()

    if "gomoku" in name:
        return "Menu: w/s select, Space or Enter confirm. Game: w/a/s/d move, Space or Enter place, r restart, m menu, q quit."
    if "breakout" in name:
        return "Keys: a/d move paddle, Space launch, r restart, q quit."
    if "tetris" in name:
        return "Keys: a/d move, w/x rotate, s soft drop, Space hard drop, q quit."
    if ("tic" in name) or ("game" in name):
        return "Enter board input directly, e.g. 11 or 23."
    return "Keyboard input is forwarded directly to the board UART."


def interactive_terminal(ser, hint_text=None):
    stop_evt = threading.Event()

    def rx_worker():
        ser.timeout = 0.1
        while not stop_evt.is_set():
            try:
                chunk = ser.read(4096)
            except serial.SerialException:
                break
            if not chunk:
                continue
            sys.stdout.buffer.write(chunk)
            sys.stdout.buffer.flush()

    rx_thread = threading.Thread(target=rx_worker, daemon=True)
    rx_thread.start()

    print("Interactive UART terminal. Ctrl+C to exit.", file=sys.stderr)
    if hint_text:
        print(hint_text, file=sys.stderr)

    try:
        if msvcrt is not None:
            while True:
                if not msvcrt.kbhit():
                    time.sleep(0.01)
                    continue
                ch = msvcrt.getwch()
                if ch == "\x03":
                    raise KeyboardInterrupt
                extended = None
                if ch in ("\x00", "\xe0"):
                    extended = msvcrt.getwch()
                data = windows_key_to_uart(ch, extended)
                if data:
                    ser.write(data)
                    ser.flush()
        else:
            while True:
                line = sys.stdin.readline()
                if line == "":
                    break
                if not line.endswith("\n"):
                    line += "\n"
                ser.write(line.encode("ascii", errors="ignore"))
                ser.flush()
    except KeyboardInterrupt:
        pass
    finally:
        stop_evt.set()
        rx_thread.join(timeout=0.5)
        print("\nInteractive terminal closed.", file=sys.stderr)


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--port", required=True, help="UART port, e.g. COM3")
    p.add_argument("--baud", type=int, default=115200)
    p.add_argument("--mem", required=True, help="mem file with 32-bit hex words")
    p.add_argument("--delay", type=float, default=0.0, help="delay before send (sec)")
    p.add_argument("--preamble", type=int, default=4096, help="number of 0x55 bytes before sync")
    p.add_argument("--preamble-seconds", type=float, default=0.0,
                   help="send 0x55 preamble for this many UART line seconds before sync")
    p.add_argument(
        "--protocol",
        choices=("v1", "v2"),
        default="v2",
        help="v2 adds full-payload CRC32; use v1 only with an old bitstream",
    )
    p.add_argument("--chunk-size", type=int, default=32)
    p.add_argument("--chunk-delay", type=float, default=0.001)
    p.add_argument("--sync-settle", type=float, default=0.02)
    p.add_argument("--header-settle", type=float, default=0.005)
    p.add_argument("--attempts", type=int, default=5,
                   help="maximum v2 frame attempts after ACK/NAK failure")
    p.add_argument("--ack-timeout", type=float, default=2.0,
                   help="seconds to wait for the v2 loader reply")
    p.add_argument(
        "--zero",
        action="store_true",
        help="send a legacy v1 sync + zero length only",
    )
    p.add_argument("--listen", action="store_true",
                   help="keep the port open after upload and print RX bytes")
    p.add_argument("--listen-seconds", type=float, default=5.0,
                   help="seconds to keep listening after the last received byte")
    p.add_argument("--interactive", action="store_true",
                   help="after upload, keep COM open and forward keyboard input to UART")
    p.add_argument("--input-hint", default="",
                   help="override the interactive input hint text")
    args = p.parse_args()

    if args.preamble < 0:
        p.error("--preamble must be non-negative")
    if args.chunk_size < 1 or args.chunk_size > 4096:
        p.error("--chunk-size must be between 1 and 4096")
    if min(args.chunk_delay, args.sync_settle, args.header_settle) < 0:
        p.error("upload delays must be non-negative")
    if args.attempts < 1:
        p.error("--attempts must be at least 1")
    if args.ack_timeout <= 0:
        p.error("--ack-timeout must be positive")

    payload = b"" if args.zero else load_mem(args.mem)
    length = len(payload)
    protocol = "v1" if args.zero else args.protocol

    with serial.Serial(args.port, args.baud, timeout=1) as ser:
        # Keep sideband control lines inactive during upload.
        try:
            ser.dtr = False
            ser.rts = False
        except Exception:
            pass
        try:
            ser.reset_input_buffer()
            ser.reset_output_buffer()
        except Exception:
            pass
        if args.delay > 0:
            time.sleep(args.delay)
        if args.preamble_seconds > 0:
            # UART sends roughly 10 line bits per 8N1 byte.  A long 0x55 leader
            # lets the board finish DDR calibration/memtest before the real sync.
            timed_preamble = max(1, int(args.baud * args.preamble_seconds / 10.0))
            chunk = b"\x55" * 4096
            while timed_preamble > 0:
                n = min(timed_preamble, len(chunk))
                write_all(ser, chunk[:n])
                timed_preamble -= n
        pending_output = bytearray()
        attempts = 1 if protocol == "v1" else args.attempts
        for attempt in range(1, attempts + 1):
            send_image(
                ser,
                payload,
                protocol=protocol,
                preamble=args.preamble,
                chunk_size=args.chunk_size,
                chunk_delay=args.chunk_delay,
                sync_settle=args.sync_settle,
                header_settle=args.header_settle,
            )
            if protocol == "v1":
                accepted = True
                reason = "legacy v1 sent"
            else:
                accepted, reason, early_output = wait_for_boot_reply(
                    ser, args.ack_timeout
                )
                pending_output += early_output
            if accepted:
                break
            print(
                f"Upload attempt {attempt}/{attempts} failed ({reason}); retrying...",
                file=sys.stderr,
            )
        else:
            raise SystemExit(
                f"Upload failed after {attempts} attempts; last result: {reason}"
            )
        mode = "zero-length" if args.zero else f"{length} bytes from {args.mem}"
        crc_text = (
            f", CRC32=0x{payload_crc32(payload):08X}" if protocol == "v2" else ""
        )
        print(f"Sent {protocol} sync+{mode}{crc_text} to {args.port} @ {args.baud}")
        if pending_output and (args.listen or args.interactive):
            sys.stdout.buffer.write(pending_output)
            sys.stdout.buffer.flush()
        if args.listen:
            listen_for_rx(ser, args.listen_seconds)
        if args.interactive:
            hint_text = args.input_hint if args.input_hint else interactive_hint_for_mem(args.mem)
            interactive_terminal(ser, hint_text)


if __name__ == "__main__":
    main()
