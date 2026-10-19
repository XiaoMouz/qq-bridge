param([string]$Source = "$PSScriptRoot\..\..\..\ios\QQBridge\Resources\Assets.xcassets\AppIcon.appiconset\AppIcon.png", [string]$OutDir = $PSScriptRoot)
# Windows 图标：和 iOS / Mac 同一张 AppIcon.png，切成圆角（iOS 那样约 22% 的圆角半径）。
# 每个尺寸从原图单独缩放再切圆角（用纹理画刷填圆角路径，边缘抗锯齿），生成 AppIcon.ico（exe、安装程序、开始菜单、任务栏）
# 和 AppLogo.png（标题栏、引导页、关于页）。换了 iOS 图标后重跑：powershell -File windows/BetterChat/Assets/make-icon.ps1
Add-Type -AssemblyName System.Drawing
$src = [Drawing.Image]::FromFile((Resolve-Path $Source))

function Rounded([int]$s) {
  # 先高质量缩到目标尺寸，再用它当纹理填圆角矩形。
  $scaled = New-Object Drawing.Bitmap $s, $s, ([Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $sg = [Drawing.Graphics]::FromImage($scaled); $sg.InterpolationMode = 'HighQualityBicubic'; $sg.PixelOffsetMode = 'HighQuality'
  $sg.DrawImage($src, 0, 0, $s, $s); $sg.Dispose()
  $b = New-Object Drawing.Bitmap $s, $s, ([Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $g = [Drawing.Graphics]::FromImage($b); $g.SmoothingMode = 'AntiAlias'; $g.PixelOffsetMode = 'HighQuality'; $g.Clear([Drawing.Color]::Transparent)
  $r = [Math]::Max(2.0, $s * 0.225); $d = $r * 2
  $p = New-Object Drawing.Drawing2D.GraphicsPath
  $p.AddArc(0, 0, $d, $d, 180, 90); $p.AddArc($s - $d, 0, $d, $d, 270, 90)
  $p.AddArc($s - $d, $s - $d, $d, $d, 0, 90); $p.AddArc(0, $s - $d, $d, $d, 90, 90); $p.CloseFigure()
  $g.FillPath((New-Object Drawing.TextureBrush $scaled), $p); $g.Dispose(); $scaled.Dispose()
  return $b
}

# 小尺寸存成 32 位 BMP（带 alpha）：ICO 里 256 以下的 PNG 有些地方（System.Drawing、老的外壳组件）解不出来，显示成噪点。
function Dib([Drawing.Bitmap]$bmp) {
  $s = $bmp.Width; $ms = New-Object IO.MemoryStream; $w = New-Object IO.BinaryWriter $ms
  $w.Write([uint32]40); $w.Write([int32]$s); $w.Write([int32]($s * 2)); $w.Write([uint16]1); $w.Write([uint16]32)
  $w.Write([uint32]0); $w.Write([uint32]0); $w.Write([int32]0); $w.Write([int32]0); $w.Write([uint32]0); $w.Write([uint32]0)
  for ($y = $s - 1; $y -ge 0; $y--) { for ($x = 0; $x -lt $s; $x++) { $c = $bmp.GetPixel($x, $y); $w.Write([byte]$c.B); $w.Write([byte]$c.G); $w.Write([byte]$c.R); $w.Write([byte]$c.A) } }
  # AND 掩码：每行按 32 位对齐，全 0（透明由 alpha 决定）。
  $stride = [int]([Math]::Ceiling($s / 32.0) * 4); $w.Write((New-Object byte[] ($stride * $s)))
  return , $ms.ToArray()  # 逗号：别让 PowerShell 把 byte[] 展开成 object[]
}

$sizes = 16, 20, 24, 32, 40, 48, 64, 256
$pngs = @{}
foreach ($s in $sizes) {
  $bmp = Rounded $s
  if ($s -ge 256) { $ms = New-Object IO.MemoryStream; $bmp.Save($ms, [Drawing.Imaging.ImageFormat]::Png); $pngs[$s] = $ms.ToArray(); $bmp.Save((Join-Path $OutDir "AppLogo.png")) }
  else { $pngs[$s] = Dib $bmp }
  $bmp.Dispose()
}
$src.Dispose()

# ICO：256 用 PNG，其余用 BMP。
$out = New-Object IO.MemoryStream; $w = New-Object IO.BinaryWriter $out
$w.Write([uint16]0); $w.Write([uint16]1); $w.Write([uint16]$sizes.Count)
$offset = 6 + 16 * $sizes.Count
foreach ($s in $sizes) { $len = $pngs[$s].Length; $dim = if ($s -ge 256) { 0 } else { $s }; $w.Write([byte]$dim); $w.Write([byte]$dim); $w.Write([byte]0); $w.Write([byte]0); $w.Write([uint16]1); $w.Write([uint16]32); $w.Write([uint32]$len); $w.Write([uint32]$offset); $offset += $len }
foreach ($s in $sizes) { $w.Write($pngs[$s]) }
[IO.File]::WriteAllBytes((Join-Path $OutDir "AppIcon.ico"), $out.ToArray())
"ok"
