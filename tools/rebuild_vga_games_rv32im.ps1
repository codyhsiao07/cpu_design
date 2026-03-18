param(
  [string]$OutDir = "build_game_rv32im_audit",
  [string]$MakeExe = "make",
  [string]$Objdump = "C:/riscv/xpack-riscv-none-elf-gcc/bin/riscv-none-elf-objdump"
)

$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $RepoRoot
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null

$games = @(
  @{ Target = "tetris-vga";   Name = "tetris_vga";   Elf = "build_os/tetris_vga.elf";   Mem = "TEST_FILES/mem_tetris_vga.mem" },
  @{ Target = "gomoku-vga";   Name = "gomoku_vga";   Elf = "build_os/gomoku_vga.elf";   Mem = "TEST_FILES/mem_gomoku_vga.mem" },
  @{ Target = "breakout-vga"; Name = "breakout_vga"; Elf = "build_os/breakout_vga.elf"; Mem = "TEST_FILES/mem_breakout_vga.mem" },
  @{ Target = "snake-vga";    Name = "snake_vga";    Elf = "build_os/snake_vga.elf";    Mem = "TEST_FILES/mem_snake_vga.mem" },
  @{ Target = "mines-vga";    Name = "mines_vga";    Elf = "build_os/mines_vga.elf";    Mem = "TEST_FILES/mem_mines_vga.mem" },
  @{ Target = "bomber-vga";   Name = "bomber_vga";   Elf = "build_os/bomber_vga.elf";   Mem = "TEST_FILES/mem_bomber_vga.mem" },
  @{ Target = "sokoban-vga";  Name = "sokoban_vga";  Elf = "build_os/sokoban_vga.elf";  Mem = "TEST_FILES/mem_sokoban_vga.mem" },
  @{ Target = "pacman-vga";   Name = "pacman_vga";   Elf = "build_os/pacman_vga.elf";   Mem = "TEST_FILES/mem_pacman_vga.mem" },
  @{ Target = "chess-vga";    Name = "chess_vga";    Elf = "build_os/chess_vga.elf";    Mem = "TEST_FILES/mem_chess_vga.mem" }
)

$mnemonicPattern = '\b(mul|mulh|mulhsu|mulhu|div|divu|rem|remu)\b'
$helperPattern = '__mulsi3|__divsi3|__udivsi3|__modsi3|__umodsi3|__muldi3|__divdi3|__udivdi3'
$results = @()

function Invoke-Step {
  param([string[]]$Command)
  & $Command[0] $Command[1..($Command.Length - 1)]
  if ($LASTEXITCODE -ne 0) {
    throw "Command failed: $($Command -join ' ')"
  }
}

foreach ($game in $games) {
  Invoke-Step @($MakeExe, $game.Target)

  $dis = Join-Path $OutDir ($game.Name + ".dis")
  & $Objdump "-d" $game.Elf > $dis
  if ($LASTEXITCODE -ne 0) {
    throw "Objdump failed for $($game.Elf)"
  }

  $disText = Get-Content $dis -Raw
  $mnemonics = [System.Text.RegularExpressions.Regex]::Matches($disText, $mnemonicPattern) |
    ForEach-Object { $_.Groups[1].Value } |
    Select-Object -Unique
  $helperHits = [System.Text.RegularExpressions.Regex]::Matches($disText, $helperPattern) |
    ForEach-Object { $_.Value } |
    Select-Object -Unique
  $memInfo = Get-Item $game.Mem

  $results += [pscustomobject]@{
    Name = $game.Name
    Target = $game.Target
    Elf = $game.Elf
    Mem = $game.Mem
    MemBytes = $memInfo.Length
    UsesMInstructions = [bool]($mnemonics.Count)
    MMnemonics = ($mnemonics -join " ")
    SoftwareHelpers = ($helperHits -join " ")
    Status = if ($helperHits.Count -eq 0) { "PASS" } else { "FAIL" }
  }
}

Invoke-Step @($MakeExe, "vga-games-menu")

$slotDisDir = Join-Path $OutDir "slot_dis"
New-Item -ItemType Directory -Path $slotDisDir -Force | Out-Null
$slotNames = @("menu", "gomoku", "tetris", "breakout", "snake", "mines", "bomber", "sokoban", "pacman", "chess")
foreach ($slot in $slotNames) {
  $elf = Join-Path "build_os/vga_slot_suite" ($slot + ".elf")
  $dis = Join-Path $slotDisDir ($slot + ".dis")
  & $Objdump "-d" $elf > $dis
  if ($LASTEXITCODE -ne 0) {
    throw "Objdump failed for $elf"
  }
}

$csv = Join-Path $OutDir "summary.csv"
$txt = Join-Path $OutDir "summary.txt"
$results | Export-Csv -NoTypeInformation -Path $csv

$summary = @()
$summary += "RV32IM VGA Game Rebuild Summary"
$summary += ("Repo: {0}" -f $RepoRoot)
$summary += ("Games checked: {0}" -f $results.Count)
$summary += ""
$summary += "Results:"
foreach ($r in $results) {
  $summary += ("  {0}: {1} mem={2} m_ext={3} mnemonics=[{4}] helpers=[{5}]" -f
    $r.Name, $r.Status, $r.MemBytes, $r.UsesMInstructions, $r.MMnemonics, $r.SoftwareHelpers)
}
$summary += ""
$summary += "Notes:"
$summary += "  All game builds use -march=rv32im through Makefile and slot-suite build."
$summary += "  PASS means rebuild succeeded and objdump did not show software mul/div helper calls."
$summary += "  slot_dis/ contains disassembly for integrated menu and all 9 slot images."

$summary | Set-Content -Path $txt
$summary | ForEach-Object { Write-Host $_ }

exit 0
