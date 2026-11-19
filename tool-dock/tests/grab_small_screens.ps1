# Runs show_small_screens.lua and grabs the top left corner of the screen for each faked screen size.
# Pictures: <out>\small_<n>.png (the faked screen's size; a red line marks its right and bottom edge).
# Run: powershell -ExecutionPolicy Bypass -File tests\grab_small_screens.ps1 [out folder]
param([string]$Out = $env:TEMP)
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$env:TOOLDOCK_SHOT_DIR = $Out
Remove-Item "$Out\ready_*.txt" -ErrorAction SilentlyContinue
$job = Start-Process powershell -ArgumentList "-ExecutionPolicy Bypass -File `"$here\run_lua55.ps1`" `"$here\show_small_screens.lua`"" -PassThru -WindowStyle Hidden
$py = @'
import ctypes, sys
ctypes.windll.user32.SetProcessDPIAware()
from PIL import ImageGrab, ImageDraw
w, h = int(sys.argv[2]), int(sys.argv[3])
img = ImageGrab.grab(bbox=(0, 0, w + 40, h + 40), all_screens=True)
d = ImageDraw.Draw(img)
d.line([(w, 0), (w, h)], fill=(255, 0, 0), width=3)
d.line([(0, h), (w, h)], fill=(255, 0, 0), width=3)
img.save(sys.argv[1])
'@
$pyFile = "$Out\grab_small.py"
Set-Content -Encoding ascii $pyFile $py
foreach ($n in 1..3) {
    $t = 0
    while (-not (Test-Path "$Out\ready_$n.txt") -and $t -lt 60) { Start-Sleep -Milliseconds 250; $t++ }
    if (-not (Test-Path "$Out\ready_$n.txt")) { "screen $n : not ready"; continue }
    Start-Sleep -Milliseconds 600
    $line = Get-Content "$Out\ready_$n.txt" -Raw
    $m = [regex]::Match($line, "screen (\d+)x(\d+)")
    python $pyFile "$Out\small_$n.png" $m.Groups[1].Value $m.Groups[2].Value
    $line
}
$job.WaitForExit(30000) | Out-Null
