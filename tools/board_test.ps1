<#
.SYNOPSIS
  Flash a bitstream and run a firmware image on the Pangu 200Pro+, then report.

.DESCRIPTION
  One command for the whole loop: JTAG program, serial upload, capture.
  Handles the two traps that cost time earlier:
    * cdt_cfg needs forward slashes in -args (backslashes are eaten by
      PowerShell before the tool sees them);
    * the serial port is exclusive, so any sscom / -Follow session is stopped
      first.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File tools\board_test.ps1 `
      -Bitstream build\pango\p1b\generate_bitstream\video_fb_top.sbit `
      -Firmware build\fw\cam_board.bin -Seconds 8
#>
param(
    [Parameter(Mandatory = $true)][string]$Bitstream,
    [Parameter(Mandatory = $true)][string]$Firmware,
    [string]$Port = "COM9",
    [int]$Seconds = 8
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot

function To-Slash([string]$p) {
    return ((Resolve-Path $p).Path -replace '\\', '/')
}

# --- free the serial port -------------------------------------------------
foreach ($name in @("sscom5.13.1", "sscom5", "putty", "MobaXterm")) {
    Get-Process -Name $name -ErrorAction SilentlyContinue | ForEach-Object {
        if (-not $_.CloseMainWindow()) { $_.Kill() }
        Start-Sleep -Milliseconds 500
    }
}
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.CommandLine -match "upload\.ps1" } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

# --- program --------------------------------------------------------------
$sbit = To-Slash $Bitstream
Write-Host "[1/3] programming $sbit"
$out = & "D:\PDS_2022.2-SP6.4\bin\cdt_cfg.exe" `
        -file ((To-Slash "$root\fpga\pango\program.tcl")) `
        -args "{$sbit}" 2>&1 | Out-String
if ($out -notmatch "done bit is 1") {
    Write-Host $out
    throw "programming failed (no done bit)"
}
Write-Host "      done bit is 1"

# --- upload ---------------------------------------------------------------
Write-Host "[2/3] uploading $Firmware"
& powershell -ExecutionPolicy Bypass -File "$PSScriptRoot\upload.ps1" `
    -Port $Port -File $Firmware -ListenSeconds 2 | Out-Null

# --- capture --------------------------------------------------------------
Write-Host "[3/3] capturing $Seconds s from $Port"
$sp = New-Object System.IO.Ports.SerialPort($Port, 115200, "None", 8, "One")
$sp.Open()
$sp.DiscardInBuffer()
$text = ""
$deadline = (Get-Date).AddSeconds($Seconds)
while ((Get-Date) -lt $deadline) {
    try { $text += $sp.ReadExisting() } catch { }
    Start-Sleep -Milliseconds 40
}
$sp.Close()

$log = Join-Path $root ("build/board_capture.txt")
Set-Content -Path $log -Value $text -Encoding UTF8

$lines = $text -split "`r?`n" | Where-Object { $_.Trim() -ne "" }
$head = $lines | Select-Object -First 12
$tail = $lines | Select-Object -Last 6
Write-Host "----- first lines -----"
$head | ForEach-Object { Write-Host $_ }
Write-Host "----- last lines -----"
$tail | ForEach-Object { Write-Host $_ }
Write-Host "----- $($lines.Count) lines -> $log -----"
