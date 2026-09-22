#!/usr/bin/env python3
"""Run the active RTL regressions with checked exit codes and PASS markers.

Run from any directory. Logs, commands and results go under --out-dir.
External FreeRTOS, Vivado and physical-board tests are separate workflows.
"""
import argparse
import json
import re
import subprocess
import time
import sys
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
UNIT_TOPS = (
    "id_illegal_decode_tb", "id_csr_decode_tb", "id_muldiv_decode_tb",
    "csr_file_tb", "csr_privilege_tb", "misalign_check_tb",
    "machine_irq_sources_tb", "booth_multiplier_tb", "restoring_divider_tb",
    "ex_muldiv_tb", "bp_redirect_scenarios_tb", "icache_tb", "dcache_tb",
    "l2_arb_tb", "uart_mmio_tb", "performance_counters_tb", "vga_subsystem_tb",
    "uart_bootloader_tb", "uart_bootloader_stall_tb",
    "uart_bootloader_split_ready_tb",
)
FAILURE = re.compile(r"\bFAIL\b|ASSERT_FAIL|\bFATAL\b|\bTIMEOUT\b|^ERROR:", re.M)
PASS = r"\bPASS\b|All tests passed\."


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out-dir", type=Path, default=ROOT / "build_regression")
    parser.add_argument("--suite", choices=("all", "unit", "cpu", "firmware"), default="all")
    parser.add_argument("--seed-count", type=int, default=0,
                        help="additional randomized seeds for CPU tests 24..27")
    parser.add_argument("--timeout", type=float, default=180,
                        help="wall-clock limit in seconds per compiler/simulator process")
    parser.add_argument("--iverilog", default="iverilog")
    parser.add_argument("--vvp", default="vvp")
    parser.add_argument("--gcc", default="riscv64-unknown-elf-gcc")
    parser.add_argument("--objcopy", default="riscv-none-elf-objcopy")
    parser.add_argument("--boot-image", type=Path,
                        help="also verify a built .mem image through the full-image boot CRC TB")
    args = parser.parse_args()
    if args.timeout <= 0 or args.seed_count < 0:
        parser.error("timeout must be positive and seed-count nonnegative")
    out = args.out_dir.resolve()
    out.mkdir(parents=True, exist_ok=True)
    sources = [str(p) for p in sorted(ROOT.glob("*.v"))]
    rows = []

    def run(name, command, marker=None):
        start = time.monotonic()
        log = out / (name + ".log")
        code = None
        error = None
        with log.open("w", encoding="utf-8") as stream:
            try:
                result = subprocess.run(command, cwd=ROOT, stdout=stream,
                                        stderr=subprocess.STDOUT, timeout=args.timeout)
                code = result.returncode
            except (OSError, subprocess.TimeoutExpired) as exc:
                error = str(exc)
                stream.write("\nRUNNER_ERROR: " + error + "\n")
        output = log.read_text(encoding="utf-8", errors="replace")
        passed = (code == 0 and not FAILURE.search(output)
                  and (marker is None or re.search(marker, output) is not None))
        rows.append(dict(name=name, status="PASS" if passed else "FAIL",
                         returncode=code, seconds=round(time.monotonic() - start, 3),
                         command=command, log=str(log), error=error))
        (out / "summary.json").write_text(json.dumps(rows, indent=2), encoding="utf-8")
        print(f"{rows[-1]['status']}: {name} ({rows[-1]['seconds']}s)", flush=True)
        return passed

    def compile_top(top, parameters=()):
        exe = out / (top + ".out")
        command = [args.iverilog, "-g2005-sv", "-DFAST_SIM", "-s", top,
                   "-o", str(exe), *parameters, *sources]
        return exe if run(top + "_compile", command) else None

    if args.suite in ("all", "unit"):
        for top in UNIT_TOPS:
            exe = compile_top(top)
            if exe:
                run(top, [args.vvp, str(exe)], PASS)
    if args.suite in ("all", "cpu", "firmware"):
        exe = compile_top("icache_pipeline_tb")
        if exe and args.suite in ("all", "cpu"):
            for test in range(1, 28):
                run(f"cpu_t{test}", [args.vvp, str(exe), f"+TEST={test}",
                                    "+ASSERT_EN=1"], rf"PASS: test {test}\b")
            for seed in range(1, args.seed_count + 1):
                for test in range(24, 28):
                    run(f"cpu_t{test}_s{seed}", [args.vvp, str(exe), f"+TEST={test}",
                        "+ASSERT_EN=1", "+RAND_MEM=1", f"+SEED={seed}",
                        "+RAND_BP_PCT=15", "+RAND_I_MAX=9", "+RAND_D_MAX=9",
                        "+STALL_WDOG=512", "+RD_WDOG=256", "+MAXCYCLES=250000"],
                        rf"PASS: test {test}\b")
        if exe and args.suite in ("all", "firmware"):
            for name, sources_c, libs, signature in (
                ("csr_system", ["TEST_FILES/prog_csr_regression.S"], [], "c5a0c0de"),
                ("lua_port", ["tools/crt0.S", "TEST_FILES/prog_lua_port_regression.c",
                              "OS/rtos/src/lua_rtos_port.c"], ["-lm", "-lgcc"], "51a0c0de"),
                ("muldiv_smoke", ["tools/crt0.S", "TEST_FILES/prog_test28_muldiv_smoke.c"],
                 [], "2800c0de"),
            ):
                elf = out / (name + ".elf")
                binary = out / (name + ".bin")
                mem = out / (name + ".mem")
                command = [args.gcc, "-march=rv32im_zicsr", "-mabi=ilp32", "-mno-relax",
                    "-ffreestanding", "-fno-builtin", "-ffunction-sections", "-fdata-sections",
                    "-nostdlib", "-O2", "-Wall", "-Wextra", "-IOS/rtos/src",
                    "-Wl,-T,tools/link_ddr.ld", "-Wl,--gc-sections", "-o", str(elf),
                    *sources_c, *libs]
                if not run(name + "_build", command):
                    continue
                if not run(name + "_objcopy", [args.objcopy, "-O", "binary", str(elf), str(binary)]):
                    continue
                if not run(name + "_mem", [sys.executable, str(ROOT / "tools/bin_to_mem.py"),
                                           str(binary), str(mem)]):
                    continue
                run(name, [args.vvp, str(exe), "+TEST=0", f"+MEMFILE={mem}", "+EXPECT_RD=8",
                           f"+EXPECT_VAL={signature}", "+ASSERT_EN=1", "+MAXCYCLES=500000"],
                    rf"PASS: test 0 expect x8 = 0x{signature}\b")
    if args.boot_image:
        memfile = args.boot_image.resolve()
        try:
            payload = b"".join(int(line, 16).to_bytes(4, "little")
                               for line in memfile.read_text(encoding="ascii").splitlines()
                               if line.strip() and not line.strip().startswith("//"))
        except (OSError, ValueError, OverflowError) as exc:
            parser.error(f"invalid boot image: {exc}")
        if not 0 < len(payload) <= 524288:
            parser.error("boot CRC TB supports 1..524288 bytes")
        top = "uart_bootloader_large_crc_tb"
        exe = compile_top(top, [f"-P{top}.IMAGE_BYTES={len(payload)}",
                                f"-P{top}.IMAGE_CRC32={zlib.crc32(payload)}"])
        if exe:
            run(top, [args.vvp, str(exe), f"+MEMFILE={memfile}"],
                rf"\[LARGE_CRC_TB\] PASS bytes={len(payload)}\b")
    failed = sum(row["status"] == "FAIL" for row in rows)
    print(f"Checks: {len(rows)}, passed: {len(rows) - failed}, failed: {failed}")
    print(f"Report: {out / 'summary.json'}")
    return int(failed != 0)


if __name__ == "__main__":
    raise SystemExit(main())
