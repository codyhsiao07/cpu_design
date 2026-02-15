#!/usr/bin/env python3
import argparse
import re
import sys


def parse_trace(path):
    rows = []
    with open(path, "r", encoding="utf-8", errors="ignore") as f:
        for ln_no, raw in enumerate(f, 1):
            s = raw.strip()
            if not s or s.startswith("#"):
                continue

            # Preferred format: "<cycle> <rd> <wdata_hex>"
            m = re.match(r"^\s*(\d+)\s+(\d+)\s+([0-9a-fA-F]+)\s*$", s)
            if m:
                cyc = int(m.group(1))
                rd = int(m.group(2))
                val = int(m.group(3), 16) & 0xFFFFFFFF
                rows.append((ln_no, cyc, rd, val))
                continue

            # Compatibility format: "WB: xN <= 0xXXXXXXXX"
            m = re.search(r"WB:\s*x(\d+)\s*<=\s*0x([0-9a-fA-F]+)", s)
            if m:
                rd = int(m.group(1))
                val = int(m.group(2), 16) & 0xFFFFFFFF
                rows.append((ln_no, -1, rd, val))
                continue

            raise ValueError(f"{path}:{ln_no}: unrecognized trace line: {s}")
    return rows


def squash_consecutive_duplicates(rows):
    out = []
    prev = None
    for row in rows:
        _, _, rd, val = row
        key = (rd, val)
        if prev is not None and key == prev:
            continue
        out.append(row)
        prev = key
    return out


def main():
    ap = argparse.ArgumentParser(description="Compare DUT commit trace against reference trace")
    ap.add_argument("ref", help="reference trace file")
    ap.add_argument("dut", help="DUT trace file")
    ap.add_argument("--strict-cycle", action="store_true", help="also require cycle to match")
    ap.add_argument(
        "--squash-dup",
        action="store_true",
        help="squash consecutive duplicate commits with same rd/value before compare",
    )
    args = ap.parse_args()

    ref_rows = parse_trace(args.ref)
    dut_rows = parse_trace(args.dut)
    if args.squash_dup:
        ref_rows = squash_consecutive_duplicates(ref_rows)
        dut_rows = squash_consecutive_duplicates(dut_rows)

    n_ref = len(ref_rows)
    n_dut = len(dut_rows)
    n = min(n_ref, n_dut)

    for i in range(n):
        r_ln, r_cyc, r_rd, r_val = ref_rows[i]
        d_ln, d_cyc, d_rd, d_val = dut_rows[i]
        if (r_rd != d_rd) or (r_val != d_val) or (args.strict_cycle and (r_cyc != d_cyc)):
            print("DIFF_FAIL")
            print(f"  index={i}")
            print(f"  ref: line={r_ln} cycle={r_cyc} rd=x{r_rd} val=0x{r_val:08x}")
            print(f"  dut: line={d_ln} cycle={d_cyc} rd=x{d_rd} val=0x{d_val:08x}")
            return 1

    if n_ref != n_dut:
        print("DIFF_FAIL")
        print(f"  commit count mismatch: ref={n_ref} dut={n_dut}")
        if n_ref > n_dut:
            r_ln, r_cyc, r_rd, r_val = ref_rows[n]
            print(f"  first extra ref: line={r_ln} cycle={r_cyc} rd=x{r_rd} val=0x{r_val:08x}")
        else:
            d_ln, d_cyc, d_rd, d_val = dut_rows[n]
            print(f"  first extra dut: line={d_ln} cycle={d_cyc} rd=x{d_rd} val=0x{d_val:08x}")
        return 1

    print("DIFF_PASS")
    print(f"  commits={n_ref}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
