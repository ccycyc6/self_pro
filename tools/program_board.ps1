<#
.SYNOPSIS
  Program a bitstream onto the Pangu 200Pro+ without touching the PDS IDE.

.DESCRIPTION
  Works around two problems that make the vendor flow fail on this machine:

    * cdt_js cannot bind port 65420 because Windows reserves 65389-65488 for
      Hyper-V/WSL, so the server dies with "Socket bind error" and the client
      reports "connection refused".  This script starts the server on a port
      outside the reserved ranges and tells program.tcl about it;
    * -args must use forward slashes or PowerShell eats the backslashes.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File tools\program_board.ps1 `
      -Bitstream build\pango\p1c\generate_bitstream\video_fb_top.sbit
#>
param(
    [Parameter(Mandatory = $true)][string]$Bitstream,
    [int]$Port = 60000
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$bin  = "D:\PDS_2022.2-SP6.4\bin"

function Port-Free([int]$p) {
    try {
        $l = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $p)
        $l.Start(); $l.Stop(); return $true
    } catch { return $false }
}

# Pick a port the hypervisor did not reserve.
while (-not (Port-Free $Port) -and (Get-NetTCPConnection -LocalPort $Port -ErrorAction SilentlyContinue)) {
    Write-Host "port $Port busy, trying next"
    $Port++
}

if (-not (Get-Process cdt_js -ErrorAction SilentlyContinue)) {
    Write-Host "starting cdt_js on port $Port"
    Start-Process -FilePath (Join-Path $bin "cdt_js.exe") -ArgumentList "-port", "$Port" `
        -WindowStyle Hidden | Out-Null
    Start-Sleep -Seconds 3
}

$env:CDT_JS_PORT = "$Port"
$sbit = ((Resolve-Path $Bitstream).Path -replace '\\', '/')
$tcl  = ((Resolve-Path (Join-Path $root "fpga\pango\program.tcl")).Path -replace '\\', '/')

Write-Host "programming $sbit"
$out = & (Join-Path $bin "cdt_cfg.exe") -file $tcl -args "{$sbit}" 2>&1 | Out-String
if ($out -match "done bit is 1") {
    Write-Host "OK: done bit is 1"
} else {
    Write-Host $out
    throw "programming failed"
}
