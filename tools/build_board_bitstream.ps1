param(
  [string]$Project = "C:\Users\a0968\cpu_test_0713\cpu_test_0713.xpr",
  [string]$OutputBit = "build_fpga\board_top_rtos_rearm.bit",
  [int]$Jobs = 4,
  [string]$VivadoBat = "C:\Xilinx\Vivado\2020.2\bin\vivado.bat"
)

$ErrorActionPreference = "Stop"
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$projectPath = (Resolve-Path -LiteralPath $Project).Path
if ([System.IO.Path]::IsPathRooted($OutputBit)) {
  $outputPath = [System.IO.Path]::GetFullPath($OutputBit)
} else {
  $outputPath = [System.IO.Path]::GetFullPath((Join-Path $repoRoot $OutputBit))
}
if (-not (Test-Path -LiteralPath $VivadoBat)) {
  throw "Vivado not found: $VivadoBat"
}

$outputDir = Split-Path -Parent $outputPath
New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
$log = Join-Path $outputDir "vivado_bitstream_build.log"
$journal = Join-Path $outputDir "vivado_bitstream_build.jou"
$tcl = Join-Path $PSScriptRoot "rebuild_vivado_bitstream.tcl"

& $VivadoBat `
  -mode batch `
  -log $log `
  -journal $journal `
  -source $tcl `
  -tclargs $projectPath $outputPath $Jobs
if ($LASTEXITCODE -ne 0) {
  throw "Vivado bitstream build failed. See $log"
}
if (-not (Test-Path -LiteralPath $outputPath)) {
  throw "Vivado completed but output bitstream was not found: $outputPath"
}

Write-Output "BIT: $outputPath"
Write-Output "LOG: $log"
