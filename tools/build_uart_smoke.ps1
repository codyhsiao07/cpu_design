param(
  [string]$Source = "OS/uart_smoke.c",
  [string]$OutMem = "build_rv32/uart_smoke.mem",
  [string]$BuildDir = "build_rv32/uart_smoke"
)

$ErrorActionPreference = "Stop"

powershell -ExecutionPolicy Bypass -File .\tools\build_mem_from_c.ps1 `
  -Source $Source `
  -BuildDir $BuildDir `
  -OutMem $OutMem `
  -Arch "rv32im_zicsr"
