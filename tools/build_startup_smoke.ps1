param(
  [string]$Source = "OS/startup_smoke.S",
  [string]$BuildDir = "build_rv32/startup_smoke",
  [string]$OutMem = "build_rv32/startup_smoke.mem",
  [string]$ToolchainBin = "C:\riscv\xpack-riscv-none-elf-gcc\bin"
)

$ErrorActionPreference = "Stop"

function Find-Tool([string[]]$candidates) {
  foreach ($t in $candidates) {
    $cmd = Get-Command $t -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
  }
  return $null
}

if (Test-Path $ToolchainBin) {
  $env:PATH = "$ToolchainBin;$env:PATH"
}

$gcc = Find-Tool @("riscv-none-elf-gcc","riscv32-unknown-elf-gcc","riscv64-unknown-elf-gcc")
$objcopy = Find-Tool @("riscv-none-elf-objcopy","riscv32-unknown-elf-objcopy","riscv64-unknown-elf-objcopy")

if (-not $gcc -or -not $objcopy) {
  throw "RISC-V toolchain not found"
}

New-Item -ItemType Directory -Path $BuildDir -Force | Out-Null

$elf = Join-Path $BuildDir "startup_smoke.elf"
$bin = Join-Path $BuildDir "startup_smoke.bin"

$args = @(
  "-march=rv32im_zicsr",
  "-mabi=ilp32",
  "-ffreestanding",
  "-nostdlib",
  "-Wl,-T,tools/link_ddr.ld",
  "-o", $elf,
  $Source
)

& $gcc @args
if ($LASTEXITCODE -ne 0) { throw "gcc failed" }

& $objcopy -O binary $elf $bin
if ($LASTEXITCODE -ne 0) { throw "objcopy failed" }

& python tools/bin_to_mem.py $bin $OutMem
if ($LASTEXITCODE -ne 0) { throw "bin_to_mem failed" }

Write-Output "Done: $OutMem"
