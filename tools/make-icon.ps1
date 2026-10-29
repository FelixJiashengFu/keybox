# Draws the KeyBox icon (amber key on a dark navy tile) and writes
# src/KeyBox/Assets/KeyBox.ico (16-256 px, PNG frames) and KeyBox.png (256 px), plus
# mac/Resources/AppIcon.iconset (16-1024 px, macOS layout: smaller tile with a soft shadow).
# Keep this file pure ASCII: Windows PowerShell 5.1 reads scripts as the ANSI code page.
Add-Type -AssemblyName System.Drawing

$assets = Join-Path $PSScriptRoot '..\src\KeyBox\Assets'
New-Item -ItemType Directory -Force $assets | Out-Null

function Circle([double]$cx, [double]$cy, [double]$r, [bool]$ccw) {
    $pts = New-Object 'System.Drawing.PointF[]' 96
    for ($i = 0; $i -lt 96; $i++) {
        $a = 2 * [Math]::PI * $i / 96
        if ($ccw) { $a = -$a }
        $pts[$i] = New-Object System.Drawing.PointF ([float]($cx + $r * [Math]::Cos($a))), ([float]($cy + $r * [Math]::Sin($a)))
    }
    return ,$pts
}

function Rect([double]$x1, [double]$y1, [double]$x2, [double]$y2) {
    # clockwise on screen (y grows downward)
    return ,[System.Drawing.PointF[]]@(
        (New-Object System.Drawing.PointF $x1, $y1),
        (New-Object System.Drawing.PointF $x2, $y1),
        (New-Object System.Drawing.PointF $x2, $y2),
        (New-Object System.Drawing.PointF $x1, $y2))
}

function Draw([int]$size, [bool]$mac = $false) {
    $bmp = New-Object System.Drawing.Bitmap $size, $size, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $g.Clear([System.Drawing.Color]::Transparent)
    $s = $size / 256.0
    $g.ScaleTransform($s, $s)
    if ($mac) {
        # macOS grid: the tile fills ~80% of the canvas and sits on a soft shadow
        $g.TranslateTransform(128, 128); $g.ScaleTransform(0.86, 0.86); $g.TranslateTransform(-128, -128)
    }

    # tile
    $tile = New-Object System.Drawing.Drawing2D.GraphicsPath
    $r = 56; $x = 8; $y = 8; $w = 240
    $tile.AddArc($x, $y, 2 * $r, 2 * $r, 180, 90)
    $tile.AddArc($x + $w - 2 * $r, $y, 2 * $r, 2 * $r, 270, 90)
    $tile.AddArc($x + $w - 2 * $r, $y + $w - 2 * $r, 2 * $r, 2 * $r, 0, 90)
    $tile.AddArc($x, $y + $w - 2 * $r, 2 * $r, 2 * $r, 90, 90)
    $tile.CloseFigure()
    $bg = New-Object System.Drawing.Drawing2D.LinearGradientBrush (New-Object System.Drawing.PointF 8, 8), (New-Object System.Drawing.PointF 248, 248), ([System.Drawing.Color]::FromArgb(255, 0x26, 0x34, 0x55)), ([System.Drawing.Color]::FromArgb(255, 0x0B, 0x12, 0x20))
    if ($mac) {
        for ($i = 6; $i -ge 1; $i--) {
            $m = New-Object System.Drawing.Drawing2D.Matrix
            $m.Translate(128, 132); $m.Scale(1 + $i * 0.012, 1 + $i * 0.012); $m.Translate(-128, -128)
            $shadow = $tile.Clone(); $shadow.Transform($m)
            $g.FillPath((New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(9, 0, 0, 0))), $shadow)
        }
    }
    $g.FillPath($bg, $tile)

    # key, drawn horizontally and turned 45 degrees about the centre
    $g.TranslateTransform(128, 128)
    $g.RotateTransform(45)
    $g.TranslateTransform(-128, -128)
    $key = New-Object System.Drawing.Drawing2D.GraphicsPath ([System.Drawing.Drawing2D.FillMode]::Winding)
    $key.AddPolygon((Circle 80 128 44 $false))
    $key.AddPolygon((Circle 80 128 17 $true))
    $key.AddPolygon((Rect 112 115 214 141))
    $key.AddPolygon((Rect 180 141 200 172))
    $key.AddPolygon((Rect 152 141 170 164))
    $gold = New-Object System.Drawing.Drawing2D.LinearGradientBrush (New-Object System.Drawing.PointF 36, 84), (New-Object System.Drawing.PointF 214, 172), ([System.Drawing.Color]::FromArgb(255, 0xFF, 0xD2, 0x6B)), ([System.Drawing.Color]::FromArgb(255, 0xE8, 0x95, 0x22))
    $g.FillPath($gold, $key)

    $g.Dispose()
    return $bmp
}

$sizes = 16, 20, 24, 32, 40, 48, 64, 128, 256
$frames = @()
foreach ($size in $sizes) {
    $bmp = Draw $size
    $ms = New-Object System.IO.MemoryStream
    $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
    if ($size -eq 256) { $bmp.Save((Join-Path $assets 'KeyBox.png'), [System.Drawing.Imaging.ImageFormat]::Png) }
    $bmp.Dispose()
    $frames += , @($size, $ms.ToArray())
}

$out = New-Object System.IO.MemoryStream
$bw = New-Object System.IO.BinaryWriter $out
$bw.Write([UInt16]0); $bw.Write([UInt16]1); $bw.Write([UInt16]$frames.Count)
$offset = 6 + 16 * $frames.Count
foreach ($f in $frames) {
    $dim = if ($f[0] -ge 256) { 0 } else { $f[0] }
    $bw.Write([byte]$dim); $bw.Write([byte]$dim); $bw.Write([byte]0); $bw.Write([byte]0)
    $bw.Write([UInt16]1); $bw.Write([UInt16]32)
    $bw.Write([UInt32]$f[1].Length); $bw.Write([UInt32]$offset)
    $offset += $f[1].Length
}
foreach ($f in $frames) { $bw.Write([byte[]]$f[1]) }
$bw.Flush()
[System.IO.File]::WriteAllBytes((Join-Path $assets 'KeyBox.ico'), $out.ToArray())
Write-Host "wrote $assets\KeyBox.ico and KeyBox.png"

$iconset = Join-Path $PSScriptRoot '..\mac\Resources\AppIcon.iconset'
New-Item -ItemType Directory -Force $iconset | Out-Null
foreach ($pt in 16, 32, 128, 256, 512) {
    foreach ($scale in 1, 2) {
        $name = if ($scale -eq 1) { "icon_${pt}x${pt}.png" } else { "icon_${pt}x${pt}@2x.png" }
        $bmp = Draw ($pt * $scale) $true
        $bmp.Save((Join-Path $iconset $name), [System.Drawing.Imaging.ImageFormat]::Png)
        $bmp.Dispose()
    }
}
Write-Host "wrote $iconset"
