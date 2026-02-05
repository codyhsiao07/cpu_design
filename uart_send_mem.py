import argparse
import struct
import time

try:
    import serial  # pyserial
except ImportError:
    raise SystemExit("pyserial not found. Install with: pip install pyserial")


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


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--port", required=True, help="UART port, e.g. COM3")
    p.add_argument("--baud", type=int, default=115200)
    p.add_argument("--mem", required=True, help="mem file with 32-bit hex words")
    p.add_argument("--delay", type=float, default=0.0, help="delay before send (sec)")
    args = p.parse_args()

    payload = load_mem(args.mem)
    length = len(payload)
    hdr = struct.pack("<I", length)

    with serial.Serial(args.port, args.baud, timeout=1) as ser:
        if args.delay > 0:
            time.sleep(args.delay)
        ser.write(hdr)
        ser.write(payload)
        ser.flush()
        print(f"Sent {length} bytes from {args.mem} to {args.port} @ {args.baud}")


if __name__ == "__main__":
    main()
