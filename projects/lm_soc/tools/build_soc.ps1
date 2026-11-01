# build_soc.ps1 - build the CPU + miniTensor system on its own (no video).
#
# Mirrors this project's rtl/*.sv into build/pango/syn/rtl/*.v with pango_prep.py,
# then runs fpga/pango/flow_soc.tcl for the requested stage.
#
#   ARES_STAGE=b2  CPU + ROM + UART
#   ARES_STAGE=b3  + BRAM behind the DDR port
#   ARES_STAGE=b4  + boot loader firmware
#   ARES_STAGE=b5  + miniTensor   (default here: this project wants the accelerator)
param(
    [string]$Name  = "soc",
    [string]$Stage = "b5",
    [switch]$NoPnr,
    [string]$Pds   = "D:\Pango\PDS_2025.2-SP3-EN-ads\bin\pds_shell.exe"
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot

if (-not (Test-Path $Pds)) { throw "pds_shell.exe not found at $Pds" }

Push-Location $root
try {
    Write-Host "prep: mirroring rtl/*.sv -> build/pango/syn/rtl/*.v"
    python tools\pango_prep.py
    if ($LASTEXITCODE -ne 0) { throw "pango_prep failed" }

    $dir = Join-Path $root ("build\pango\" + $Name)
    New-Item -ItemType Directory -Force $dir | Out-Null
    Push-Location $dir

    $env:ARES_STAGE = $Stage
    if ($NoPnr) { $env:ARES_NO_PNR = "1" } else { Remove-Item Env:ARES_NO_PNR -ErrorAction SilentlyContinue }

    Write-Host ("pds: flow_soc.tcl stage=" + $Stage + " name=" + $Name)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    & $Pds -file (Join-Path $root "fpga\pango\flow_soc.tcl") -project_name $Name *> console.log
    $sw.Stop()

    $log = Join-Path $dir "console.log"
    if (Test-Path $log) {
        Select-String -Path $log -Pattern "ERROR|Error:|bitstream" | Select-Object -Last 6 | ForEach-Object { $_.Line.Trim() }
    }
    Write-Host ("done in " + [math]::Round($sw.Elapsed.TotalMinutes, 1) + " min")

    $sbit = Get-ChildItem -Recurse -Filter *.sbit -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($sbit) {
        Write-Host ("bitstream: " + $sbit.FullName)
        Write-Host ("sha256: " + (Get-FileHash $sbit.FullName -Algorithm SHA256).Hash)
    }
} finally {
    Pop-Location -ErrorAction SilentlyContinue
    Pop-Location -ErrorAction SilentlyContinue
}
