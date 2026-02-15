import argparse
from pathlib import Path


def main():
    ap = argparse.ArgumentParser(description="Convert little-endian binary to 32-bit hex .mem")
    ap.add_argument("bin", help="Input binary")
    ap.add_argument("mem", help="Output .mem")
    args = ap.parse_args()

    b = Path(args.bin).read_bytes()
    out = []
    for i in range(0, len(b), 4):
        w = b[i:i + 4]
        if len(w) < 4:
            w = w + bytes(4 - len(w))
        val = w[0] | (w[1] << 8) | (w[2] << 16) | (w[3] << 24)
        out.append(f"{val:08X}")

    Path(args.mem).write_text("\n".join(out) + "\n", encoding="ascii")
    print(f"Wrote {args.mem} with {len(out)} words")


if __name__ == "__main__":
    main()

