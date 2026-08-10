<#
  Eyes Up - Copyright (c) 2026 KTM (abitofmoss). All Rights Reserved.
  No redistribution or reuse of this code or assets without permission. See LICENSE.

  make-icon.ps1 - draw the addon's own thumbnail, the one the AddOns list shows
  beside the name (## IconTexture in the .toc).

      pwsh tools\make-icon.ps1                    # previews only
      pwsh tools\make-icon.ps1 -Ship eye          # ...and write textures\logo-icon.tga

  Three candidates are always drawn as PNG previews so they can be compared
  side by side; -Ship picks which one becomes the shipped TGA. PNGs are source
  art -- keep them out of the package (build.ps1 strips them) and out of git.

  Drawn at 4x and scaled down rather than trusting the graphics anti-aliaser.
  GDI+ anti-aliases against the background colour, which leaves a fringe;
  supersampling averages coverage instead, which is what an edge actually wants.
  Same reasoning as CueTip's make-masks.ps1.

  The ground is OPAQUE. A mask wants transparency; a thumbnail does not -- the
  AddOns list draws it against whatever is behind the panel, and a see-through
  tile picks up the frame art and looks like a mistake.

  Output is 128x128 uncompressed 32-bit TGA. WoW loads no other kind reliably,
  and it reports neither failure -- the texture just draws blank.
#>
param(
	[int] $Size = 128,
	[ValidateSet('eye', 'ring', 'peak', 'none')] [string] $Ship = 'none',
	[string] $PreviewDir
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$repo = Split-Path -Parent $PSScriptRoot
if (-not $PreviewDir) { $PreviewDir = Join-Path $repo 'source-art' }
if (-not (Test-Path $PreviewDir)) { New-Item -ItemType Directory -Path $PreviewDir -Force | Out-Null }

if ($Size -band ($Size - 1)) { throw "Size must be a power of two, got $Size" }
$SS = 4                                  # supersample factor
$N = $Size * $SS

# Ore-vein amber from Constants.lua (0.95, 0.70, 0.25), pushed brighter so it
# still reads as gold at the ~20px the AddOns list actually draws it at.
$GOLD = [System.Drawing.Color]::FromArgb(255, 252, 191, 74)
$GROUND = [System.Drawing.Color]::FromArgb(255, 12, 12, 14)

function New-Pen {
	param([double] $Width)
	$pen = New-Object System.Drawing.Pen($GOLD, [float]$Width)
	$pen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
	$pen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
	$pen.LineJoin = [System.Drawing.Drawing2D.LineJoin]::Round
	return $pen
}

# --- the three candidates -----------------------------------------------------
#
# All of them are one flat gold mark on black, no gradients and no outline: the
# thumbnail is ~20px on screen, and anything with interior detail turns to mush
# at that size. CueTip's icon is drawn to the same rule.

$draw = @{
	# An eye. The name says it, so the mark may as well.
	eye = {
		param($g)
		$cy = 0.5 * $N
		$x0 = 0.07 * $N; $x1 = 0.93 * $N
		$c0 = 0.30 * $N; $c1 = 0.70 * $N
		$path = New-Object System.Drawing.Drawing2D.GraphicsPath
		$path.AddBezier($x0, $cy, $c0, 0.05 * $N, $c1, 0.05 * $N, $x1, $cy)
		$path.AddBezier($x1, $cy, $c1, 0.95 * $N, $c0, 0.95 * $N, $x0, $cy)
		$pen = New-Pen (0.085 * $N)
		try { $g.DrawPath($pen, $path) } finally { $pen.Dispose(); $path.Dispose() }

		$r = 0.145 * $N
		$brush = New-Object System.Drawing.SolidBrush($GOLD)
		try { $g.FillEllipse($brush, [float](0.5 * $N - $r), [float]($cy - $r), [float](2 * $r), [float](2 * $r)) }
		finally { $brush.Dispose() }
	}

	# What the addon actually puts on screen: the ring, and one blip in it.
	ring = {
		param($g)
		$r = 0.355 * $N
		$pen = New-Pen (0.095 * $N)
		try { $g.DrawEllipse($pen, [float](0.5 * $N - $r), [float](0.5 * $N - $r), [float](2 * $r), [float](2 * $r)) }
		finally { $pen.Dispose() }

		# Up and to the right, well inside the ring so the two never touch and
		# fuse into one blob when the tile is drawn small.
		$a = -[Math]::PI / 4
		$d = 0.155 * $N
		$br = 0.115 * $N
		$bx = 0.5 * $N + $d * [Math]::Cos($a)
		$by = 0.5 * $N + $d * [Math]::Sin($a)
		$brush = New-Object System.Drawing.SolidBrush($GOLD)
		try { $g.FillEllipse($brush, [float]($bx - $br), [float]($by - $br), [float](2 * $br), [float](2 * $br)) }
		finally { $brush.Dispose() }
	}

	# The eye again, with the upper lid pitched into a peak -- an eye that is
	# looking up rather than straight ahead.
	peak = {
		param($g)
		$cy = 0.54 * $N
		$x0 = 0.07 * $N; $x1 = 0.93 * $N
		$path = New-Object System.Drawing.Drawing2D.GraphicsPath
		$path.AddLine([float]$x0, [float]$cy, [float](0.5 * $N), [float](0.13 * $N))
		$path.AddLine([float](0.5 * $N), [float](0.13 * $N), [float]$x1, [float]$cy)
		$path.AddBezier($x1, $cy, 0.70 * $N, 0.97 * $N, 0.30 * $N, 0.97 * $N, $x0, $cy)
		$pen = New-Pen (0.085 * $N)
		try { $g.DrawPath($pen, $path) } finally { $pen.Dispose(); $path.Dispose() }

		$r = 0.135 * $N
		$brush = New-Object System.Drawing.SolidBrush($GOLD)
		try { $g.FillEllipse($brush, [float](0.5 * $N - $r), [float](0.60 * $N - $r), [float](2 * $r), [float](2 * $r)) }
		finally { $brush.Dispose() }
	}
}

function Write-TGA {
	param([System.Drawing.Bitmap] $Bitmap, [string] $Path)
	$rect = New-Object System.Drawing.Rectangle(0, 0, $Size, $Size)
	$data = $Bitmap.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly,
		[System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
	$bytes = New-Object byte[] ($data.Stride * $Size)
	[System.Runtime.InteropServices.Marshal]::Copy($data.Scan0, $bytes, 0, $bytes.Length)
	$Bitmap.UnlockBits($data)

	$fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Create)
	try {
		# datatypecode 2 = uncompressed true-colour; descriptor 0x08 = 8 alpha bits
		# with a bottom-left origin, so rows go out bottom-up.
		$hdr = [byte[]](0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0,
			($Size -band 0xFF), (($Size -shr 8) -band 0xFF),
			($Size -band 0xFF), (($Size -shr 8) -band 0xFF), 32, 8)
		$fs.Write($hdr, 0, $hdr.Length)
		for ($y = $Size - 1; $y -ge 0; $y--) { $fs.Write($bytes, $y * $data.Stride, $Size * 4) }
	} finally { $fs.Dispose() }
}

foreach ($name in ($draw.Keys | Sort-Object)) {
	$big = New-Object System.Drawing.Bitmap($N, $N, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
	$g = [System.Drawing.Graphics]::FromImage($big)
	try {
		$g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::None
		$g.Clear($GROUND)
		& $draw[$name] $g
	} finally { $g.Dispose() }

	$small = New-Object System.Drawing.Bitmap($Size, $Size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
	$gs = [System.Drawing.Graphics]::FromImage($small)
	try {
		$gs.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
		$gs.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
		$gs.Clear($GROUND)
		$gs.DrawImage($big, 0, 0, $Size, $Size)
	} finally { $gs.Dispose(); $big.Dispose() }

	$png = Join-Path $PreviewDir "logo-icon-$name.png"
	$small.Save($png, [System.Drawing.Imaging.ImageFormat]::Png)
	"preview  $png"

	if ($name -eq $Ship) {
		$dir = Join-Path $repo 'textures'
		if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
		$tga = Join-Path $dir 'logo-icon.tga'
		Write-TGA -Bitmap $small -Path $tga
		"SHIPPED  $tga  ${Size}x${Size} uncompressed 32-bit  (candidate '$name')"
	}

	$small.Dispose()
}

if ($Ship -eq 'none') { "`nNothing shipped. Re-run with -Ship eye|ring|peak to write textures\logo-icon.tga" }
