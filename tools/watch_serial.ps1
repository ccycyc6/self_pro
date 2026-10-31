# Watch the board's serial output until Ctrl+C.
#
# The port can only be owned by one program at a time: close this before letting
# another tool read COM9.
param(
    [string]$Port = "COM9",
    [int]$Baud = 115200
)

$ErrorActionPreference = "Stop"
$sp = New-Object System.IO.Ports.SerialPort($Port, $Baud, "None", 8, "One")
$sp.ReadTimeout = 500
$sp.Open()
Write-Host "listening on $Port at $Baud -- Ctrl+C to stop" -ForegroundColor Cyan

$buf = ""
try {
    while ($true) {
        try { $buf += $sp.ReadExisting() } catch { }
        while ($true) {
            $i = $buf.IndexOf("`n")
            if ($i -lt 0) { break }
            $line = $buf.Substring(0, $i).TrimEnd("`r")
            $buf = $buf.Substring($i + 1)
            if ($line.Trim()) { Write-Host $line }
        }
        Start-Sleep -Milliseconds 60
    }
} finally {
    if ($sp.IsOpen) { $sp.Close() }
}
