import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class TraceCompareTests(unittest.TestCase):
    def compare(self, reference, dut):
        with tempfile.TemporaryDirectory() as directory:
            ref = Path(directory) / "ref.trace"
            trace = Path(directory) / "dut.trace"
            ref.write_text(reference, encoding="utf-8")
            trace.write_text(dut, encoding="utf-8")
            return subprocess.run([sys.executable, str(ROOT / "tools/compare_commit_trace.py"),
                                   str(ref), str(trace)], capture_output=True, text=True)

    def test_empty_traces_are_not_evidence_of_success(self):
        self.assertNotEqual(self.compare("# no commits\n", "").returncode, 0)

    def test_valid_traces_ignore_timing(self):
        self.assertEqual(self.compare("1 8 deadbeef\n", "70 8 deadbeef\n").returncode, 0)

    def test_duplicate_commit_is_not_silently_removed(self):
        self.assertNotEqual(self.compare("1 8 deadbeef\n",
                            "70 8 deadbeef\n71 8 deadbeef\n").returncode, 0)

    def test_out_of_range_register_is_rejected(self):
        self.assertNotEqual(self.compare("1 32 deadbeef\n", "1 32 deadbeef\n").returncode, 0)

    def test_overwide_value_is_not_silently_truncated(self):
        self.assertNotEqual(self.compare("1 8 1deadbeef\n", "1 8 deadbeef\n").returncode, 0)


@unittest.skipUnless(shutil.which("iverilog") and shutil.which("vvp"), "Icarus required")
class SimulatorPathTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.directory = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.directory.cleanup)
        cls.base = Path(cls.directory.name)
        cls.exe = cls.base / "cpu.out"
        result = subprocess.run(["iverilog", "-g2005-sv", "-DFAST_SIM", "-s",
            "icache_pipeline_tb", "-o", str(cls.exe),
            *(str(path) for path in sorted(ROOT.glob("*.v")))],
            cwd=ROOT, capture_output=True, text=True, timeout=60)
        if result.returncode:
            raise RuntimeError(result.stdout + result.stderr)

    def simulate(self, cwd, *args):
        result = subprocess.run(["vvp", str(self.exe), "+TEST=1", "+ASSERT_EN=1", *args],
                                cwd=cwd, capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("PASS: test 1", result.stdout)

    def test_long_memory_trace_and_coverage_paths(self):
        directory = self.base / ("long_paths_" + "x" * 100)
        directory.mkdir()
        mem = directory / "image.mem"
        trace = directory / "commits.trace"
        cov = directory / "coverage.txt"
        shutil.copyfile(ROOT / "TEST_FILES/mem_test1_alu_fwd.mem", mem)
        self.simulate(ROOT, f"+MEMFILE={mem}", "+TRACE_EN=1", f"+TRACE_FILE={trace}",
                      "+COV_EN=1", f"+COV_FILE={cov}")
        self.assertGreater(trace.stat().st_size, 0)
        self.assertGreater(cov.stat().st_size, 0)

    def test_memory_search_in_parent_directory(self):
        parent = self.base / "parent"
        cwd = parent / "child" / "work"
        cwd.mkdir(parents=True)
        shutil.copyfile(ROOT / "TEST_FILES/mem_test1_alu_fwd.mem", parent / "image.mem")
        self.simulate(cwd, "+MEMFILE=image.mem")

    def test_missing_explicit_image_does_not_use_default(self):
        missing = self.base / "missing.mem"
        result = subprocess.run(["vvp", str(self.exe), "+TEST=1", f"+MEMFILE={missing}"],
                                cwd=ROOT, capture_output=True, text=True, timeout=30)
        self.assertIn(f"FATAL: MIG model cannot open MEMFILE={missing}", result.stdout)


@unittest.skipUnless(os.name == "nt" and shutil.which("powershell"), "PowerShell/Windows required")
class RegressionScriptTests(unittest.TestCase):
    def invoke_fake_sim(self, lines, code):
        with tempfile.TemporaryDirectory() as directory:
            out = Path(directory)
            vvp = out / "fake_vvp.cmd"
            vvp.write_text("@echo off\n" + "".join(f"echo {line}\n" for line in lines)
                           + f"exit /b {code}\n", encoding="ascii")
            return subprocess.run(["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass",
                "-File", str(ROOT / "tools/run_multiseed_regression.ps1"),
                "-Compile", "0", "-Tests", "1", "-SeedCount", "1", "-OutDir", str(out),
                "-Vvp", str(vvp)], cwd=ROOT, capture_output=True, text=True, timeout=20)

    def test_nonzero_simulator_exit_overrides_pass_text(self):
        result = self.invoke_fake_sim(["PASS: test 1"], 7)
        self.assertNotEqual(result.returncode, 0, result.stdout)

    def test_error_marker_overrides_pass_text(self):
        result = self.invoke_fake_sim(["ERROR: cannot open memory file", "PASS: test 1"], 0)
        self.assertNotEqual(result.returncode, 0, result.stdout)

    def test_missing_pass_marker_fails(self):
        self.assertNotEqual(self.invoke_fake_sim([], 0).returncode, 0)

    def test_valid_simulator_result_passes(self):
        self.assertEqual(self.invoke_fake_sim(["PASS: test 1"], 0).returncode, 0)

    def test_long_run_requires_new_trace_and_coverage(self):
        with tempfile.TemporaryDirectory() as directory:
            out = Path(directory)
            vvp = out / "fake_vvp.cmd"
            vvp.write_text("@echo off\necho PASS: test 1\nexit /b 0\n", encoding="ascii")
            (out / "traces").mkdir()
            (out / "coverage").mkdir()
            (out / "traces/t1_s1.trace").write_text("1 8 deadbeef\n")
            (out / "coverage/t1_s1.cov").write_text("wb_commits=1\n")
            result = subprocess.run(["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass",
                "-File", str(ROOT / "tools/run_long_verification.ps1"),
                "-Compile", "0", "-Tests", "1", "-SeedCount", "1", "-OutDir", str(out),
                "-Vvp", str(vvp)], cwd=ROOT, capture_output=True, text=True, timeout=20)
            self.assertNotEqual(result.returncode, 0, result.stdout)
            self.assertFalse((out / "traces/t1_s1.trace").exists())


if __name__ == "__main__":
    unittest.main()
