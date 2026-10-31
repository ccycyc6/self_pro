# Capture 32x32 patches from the board.
#
# Sends 'r' to start recording, captures the raw serial stream to a .bin file,
# sends 'r' again to stop.  The firmware sends A5 5A id <1024 bytes> csum per
# track per frame and prints nothing else while recording, so parsing is a
# straight scan (done afterwards by tools/ml/parse_capture.py).
param(
    [string]$Port  = "COM9",
    [int]$Seconds  = 20,
    [string]$Out   = "build/capture.bin"
)
$ErrorActionPreference = "Stop"
# the script lives in tools/ml, so the repo root is two levels up
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

$sp = New-Object System.IO.Ports.SerialPort($Port, 115200, "None", 8, "One")
$sp.ReadTimeout = 2000
$sp.Open()
Start-Sleep -Milliseconds 200
$sp.DiscardInBuffer()

$sp.Write("r")
Start-Sleep -Milliseconds 100

$target = Join-Path $root $Out
$fs = [System.IO.File]::Create($target)
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$total = 0
$buf = New-Object byte[] 4096

while ($sw.Elapsed.TotalSeconds -lt $Seconds) {
    try {
        $n = $sp.Read($buf, 0, $buf.Length)
        if ($n -gt 0) { $fs.Write($buf, 0, $n); $total += $n }
    } catch { }
}
$fs.Close()
$sp.Write("r")
Start-Sleep -Milliseconds 100
$sp.Close()

Write-Host ("captured {0} bytes in {1:N1}s -> {2}" -f $total, $sw.Elapsed.TotalSeconds, $target)
