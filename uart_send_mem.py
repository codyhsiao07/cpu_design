import argparse
import struct
import sys
import threading
import time

try:
    import serial  # pyserial
except ImportError:
    raise SystemExit("pyserial not found. Install with: pip install pyserial")

try:
    import msvcrt
except ImportError:
    msvcrt = None

SYNC_WORD = 0xC0DE5A5A


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


def interactive_terminal(ser):
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
    print("Type game input directly, e.g. 11 or 23.", file=sys.stderr)

    try:
        if msvcrt is not None:
            while True:
                if not msvcrt.kbhit():
                    time.sleep(0.01)
                    continue
                ch = msvcrt.getwch()
                if ch == "\x03":
                    raise KeyboardInterrupt
                if ch == "\r":
                    ser.write(b"\r\n")
                    ser.flush()
                elif ch == "\x08":
                    # Ignore local backspace handling; the board-side input parser
                    # only accepts digits/spaces/newlines.
                    continue
                else:
                    ser.write(ch.encode("ascii", errors="ignore"))
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
    p.add_argument("--preamble", type=int, default=64, help="number of 0x55 bytes before sync")
    p.add_argument("--zero", action="store_true", help="send sync + zero length only")
    p.add_argument("--listen", action="store_true",
                   help="keep the port open after upload and print RX bytes")
    p.add_argument("--listen-seconds", type=float, default=5.0,
                   help="seconds to keep listening after the last received byte")
    p.add_argument("--interactive", action="store_true",
                   help="after upload, keep COM open and forward keyboard input to UART")
    args = p.parse_args()

    payload = b"" if args.zero else load_mem(args.mem)
    length = len(payload)
    sync = struct.pack("<I", SYNC_WORD)
    hdr = struct.pack("<I", length)

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
        if args.preamble > 0:
            ser.write(b"\x55" * args.preamble)
        ser.write(sync)
        ser.write(hdr)
        ser.write(payload)
        ser.flush()
        mode = "zero-length" if args.zero else f"{length} bytes from {args.mem}"
        print(f"Sent sync+{mode} to {args.port} @ {args.baud}")
        if args.listen:
            listen_for_rx(ser, args.listen_seconds)
        if args.interactive:
            interactive_terminal(ser)


if __name__ == "__main__":
    main()
