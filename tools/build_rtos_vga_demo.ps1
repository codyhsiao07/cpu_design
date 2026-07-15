param(
  [string]$FreeRTOSRoot = "C:\Users\a0968\Downloads\FreeRTOSv202406.04-LTS\FreeRTOS-LTS\FreeRTOS\FreeRTOS-Kernel",
  [string]$BuildDir = "build_rtos",
  [string]$OutName = "rtos_vga_demo",
  [string]$ToolchainBin = "C:\riscv\xpack-riscv-none-elf-gcc\bin",
  [string]$Arch = "rv32im_zicsr",
  [uint32]$CpuClockHz = 50000000
)

$ErrorActionPreference = "Stop"
$builder = Join-Path $PSScriptRoot "build_rtos_app.ps1"

& $builder `
  -App vga_demo `
  -FreeRTOSRoot $FreeRTOSRoot `
  -BuildDir $BuildDir `
  -OutName $OutName `
  -ToolchainBin $ToolchainBin `
  -Arch $Arch `
  -CpuClockHz $CpuClockHz

if ($LASTEXITCODE -ne 0) {
  throw "RTOS VGA demo build failed"
}
