param(
  [string]$Bitstream = "build_fpga\board_top_rtos_rearm.bit",
  [string]$VivadoBat = "C:\Xilinx\Vivado\2020.2\bin\vivado.bat"
)

$ErrorActionPreference = "Stop"
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
if ([System.IO.Path]::IsPathRooted($Bitstream)) {
  $bitPath = (Resolve-Path -LiteralPath $Bitstream).Path
} else {
  $bitPath = (Resolve-Path -LiteralPath (Join-Path $repoRoot $Bitstream)).Path
}
if (-not (Test-Path -LiteralPath $VivadoBat)) {
  throw "Vivado not found: $VivadoBat"
}

$log = Join-Path (Split-Path -Parent $bitPath) "vivado_program_board.log"
$journal = Join-Path (Split-Path -Parent $bitPath) "vivado_program_board.jou"
$tcl = Join-Path $PSScriptRoot "program_board_bitstream.tcl"
& $VivadoBat `
  -mode batch `
  -log $log `
  -journal $journal `
  -source $tcl `
  -tclargs $bitPath
if ($LASTEXITCODE -ne 0) {
  throw "FPGA programming failed. See $log"
}

Write-Output "PROGRAMMED: $bitPath"
