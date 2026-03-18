param(
  [string]$OutDir = "build_muldiv_verification",
  [string]$Iverilog = "C:/iverilog/bin/iverilog.exe",
  [string]$Vvp = "vvp",
  [string]$Gcc = "C:/riscv/xpack-riscv-none-elf-gcc/bin/riscv64-unknown-elf-gcc",
  [string]$Objcopy = "C:/riscv/xpack-riscv-none-elf-gcc/bin/riscv-none-elf-objcopy",
  [string]$Objdump = "C:/riscv/xpack-riscv-none-elf-gcc/bin/riscv-none-elf-objdump",
  [string]$PythonExe = "python"
)

$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $RepoRoot
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null

function Get-VerilogSources {
  return @(Get-ChildItem -Name *.v)
}

function Invoke-CompileOnly {
  param(
    [string]$Top,
    [string]$OutName
  )

  $outExe = Join-Path $OutDir $OutName
  & $Iverilog "-g2005-sv" "-DFAST_SIM" "-i" "-o" $outExe "-s" $Top @(Get-VerilogSources)
  if ($LASTEXITCODE -ne 0) {
    throw "Compile-only failed for $Top"
  }
}

function Invoke-Tb {
  param(
    [string]$Top,
    [string[]]$Sources
  )

  $outExe = Join-Path $OutDir ($Top + ".out")
  $logPath = Join-Path $OutDir ($Top + ".log")
  & $Iverilog "-g2005-sv" "-i" "-o" $outExe "-s" $Top $Sources
  if ($LASTEXITCODE -ne 0) {
    throw "Compile failed for $Top"
  }

  $lines = & $Vvp $outExe 2>&1
  $lines | Set-Content -Path $logPath
  if ($LASTEXITCODE -ne 0) {
    throw "Run failed for $Top. See $logPath"
  }

  return $logPath
}

function Invoke-SmokeBuild {
  $elf = Join-Path $OutDir "test28_muldiv_smoke.elf"
  $bin = Join-Path $OutDir "test28_muldiv_smoke.bin"
  $mem = Join-Path $OutDir "test28_muldiv_smoke.mem"
  $map = Join-Path $OutDir "test28_muldiv_smoke.map"
  $dis = Join-Path $OutDir "test28_muldiv_smoke.dis"

  $gccArgs = @(
    "-march=rv32im",
    "-mabi=ilp32",
    "-ffreestanding",
    "-nostdlib",
    "-O2",
    "-Wall",
    "-Wextra",
    "-Wl,-T,tools/link_ddr.ld",
    "-Wl,-Map,$map",
    "-o", $elf,
    "tools/crt0.S",
    "TEST_FILES/prog_test28_muldiv_smoke.c"
  )

  & $Gcc @gccArgs
  if ($LASTEXITCODE -ne 0) {
    throw "RV32IM smoke build failed"
  }

  & $Objcopy "-O" "binary" $elf $bin
  if ($LASTEXITCODE -ne 0) {
    throw "Objcopy failed for smoke build"
  }

  & $PythonExe "tools/bin_to_mem.py" $bin $mem
  if ($LASTEXITCODE -ne 0) {
    throw "bin_to_mem failed for smoke build"
  }

  & $Objdump "-d" $elf > $dis
  if ($LASTEXITCODE -ne 0) {
    throw "Objdump failed for smoke build"
  }

  $required = @("mul", "mulh", "mulhsu", "mulhu", "div", "divu", "rem", "remu")
  foreach ($mnemonic in $required) {
    if (-not (Select-String -Path $dis -Pattern ("\b" + $mnemonic + "\b") -Quiet)) {
      throw "Smoke disassembly missing instruction '$mnemonic'"
    }
  }

  return @{
    elf = $elf
    bin = $bin
    mem = $mem
    dis = $dis
  }
}

$results = @()

$results += [pscustomobject]@{ Name = "booth_multiplier_tb"; Log = Invoke-Tb -Top "booth_multiplier_tb" -Sources @("booth_multiplier_tb.v","booth_multiplier.v"); Status = "PASS" }
$results += [pscustomobject]@{ Name = "restoring_divider_tb"; Log = Invoke-Tb -Top "restoring_divider_tb" -Sources @("restoring_divider_tb.v","restoring_divider.v"); Status = "PASS" }
$results += [pscustomobject]@{ Name = "ex_muldiv_tb"; Log = Invoke-Tb -Top "ex_muldiv_tb" -Sources @("ex_muldiv_tb.v","EX.v","booth_multiplier.v","restoring_divider.v"); Status = "PASS" }
$results += [pscustomobject]@{ Name = "id_muldiv_decode_tb"; Log = Invoke-Tb -Top "id_muldiv_decode_tb" -Sources @("id_muldiv_decode_tb.v","ID.v"); Status = "PASS" }
$results += [pscustomobject]@{ Name = "uart_mmio_tb"; Log = Invoke-Tb -Top "uart_mmio_tb" -Sources @(Get-VerilogSources); Status = "PASS" }
$results += [pscustomobject]@{ Name = "bp_redirect_scenarios_tb"; Log = Invoke-Tb -Top "bp_redirect_scenarios_tb" -Sources @(Get-VerilogSources); Status = "PASS" }
$results += [pscustomobject]@{ Name = "uart_bootloader_tb"; Log = Invoke-Tb -Top "uart_bootloader_tb" -Sources @(Get-VerilogSources); Status = "PASS" }
$results += [pscustomobject]@{ Name = "uart_bootloader_stall_tb"; Log = Invoke-Tb -Top "uart_bootloader_stall_tb" -Sources @(Get-VerilogSources); Status = "PASS" }
$results += [pscustomobject]@{ Name = "icache_tb"; Log = Invoke-Tb -Top "icache_tb" -Sources @(Get-VerilogSources); Status = "PASS" }

Invoke-CompileOnly -Top "icache_pipeline_top" -OutName "icache_pipeline_top_check.out"
$results += [pscustomobject]@{ Name = "icache_pipeline_top_compile"; Log = Join-Path $OutDir "icache_pipeline_top_check.out"; Status = "PASS" }

Invoke-CompileOnly -Top "board_top_vga" -OutName "board_top_vga_check.out"
$results += [pscustomobject]@{ Name = "board_top_vga_compile"; Log = Join-Path $OutDir "board_top_vga_check.out"; Status = "PASS" }

$smoke = Invoke-SmokeBuild
$results += [pscustomobject]@{ Name = "test28_muldiv_smoke_build"; Log = $smoke.dis; Status = "PASS" }

$csvPath = Join-Path $OutDir "summary.csv"
$txtPath = Join-Path $OutDir "summary.txt"
$results | Export-Csv -NoTypeInformation -Path $csvPath

$summary = @()
$summary += "Mul/Div Verification Summary"
$summary += ("Repo: {0}" -f $RepoRoot)
$summary += ("Total checks: {0}" -f $results.Count)
$summary += ("CSV: {0}" -f $csvPath)
$summary += ""
$summary += "Checks:"
foreach ($r in $results) {
  $summary += ("  {0}: {1} ({2})" -f $r.Name, $r.Status, $r.Log)
}
$summary += ""
$summary += "Notes:"
$summary += "  TEST_FILES/prog_test28_muldiv_smoke.c is compiled with -march=rv32im."
$summary += "  The smoke build verifies all eight RV32M mnemonics appear in disassembly."
$summary += "  icache_pipeline_tb is not part of this script because its FAST_SIM path is not a stable pass/fail signal in this repo."

$summary | Set-Content -Path $txtPath
$summary | ForEach-Object { Write-Host $_ }

exit 0
