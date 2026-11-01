# Build a Pango bitstream the right way: always re-run the source preparer first.
#
# pango_prep.py mirrors rtl/*.sv into build/pango/syn/rtl/*.v and the PDS flow
# compiles *that* tree, not rtl/.  Running PDS without the prep step silently
# rebuilds the previous RTL -- which is exactly how four "fixed" bitstreams
# ended up unchanged on the board.
param(
    [Parameter(Mandatory = $true)][string]$Name,
    [string]$Pds = "D:\Pango\PDS_2025.2-SP3-EN-ads"
)
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot

Push-Location $root
try {
    Write-Host "prep: mirroring rtl/*.sv -> build/pango/syn/rtl/*.v"
    python tools\pango_prep.py | Select-Object -Last 2

    $dir = Join-Path $root "build\pango\$Name"
    Remove-Item -Recurse -Force $dir -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force $dir | Out-Null
    Push-Location $dir
    try {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        & (Join-Path $Pds "bin\pds_shell.exe") -file (Join-Path $root "fpga\pango\flow_full.tcl") -project_name $Name *> console.log
        $el = [math]::Round($sw.Elapsed.TotalMinutes, 1)
        $errs = Select-String -Path console.log -Pattern "^E: " | Select-Object -First 3
        if ($errs) { $errs | ForEach-Object { $_.Line.Trim() } }
        $bit = Join-Path $dir "prj_tasks\pnr_1\generate_bitstream\video_fb_top.sbit"
        if (Test-Path $bit) {
            $h = (Get-FileHash $bit -Algorithm SHA256).Hash
            Write-Host "OK: $bit"
            Write-Host "sha256: $h  (build $el min)"
        } else {
            Write-Host "FAILED: no bitstream (build $el min)"
        }
    } finally { Pop-Location }
} finally { Pop-Location }
