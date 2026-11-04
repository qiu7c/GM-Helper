$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
$iconSource = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../assets/icon/app_icon.png'))
$iconTarget = Join-Path $PSScriptRoot 'GMSchedule/Assets.xcassets/AppIcon.appiconset'
$originalIcon = [Drawing.Image]::FromFile($iconSource)
$iconDefinitions = @(
    @('iphone',20,2), @('iphone',20,3), @('iphone',29,2), @('iphone',29,3),
    @('iphone',40,2), @('iphone',40,3), @('iphone',60,2), @('iphone',60,3),
    @('ipad',20,1), @('ipad',20,2), @('ipad',29,1), @('ipad',29,2),
    @('ipad',40,1), @('ipad',40,2), @('ipad',76,1), @('ipad',76,2),
    @('ipad',83.5,2), @('ios-marketing',1024,1)
)
$iconItems = @()
foreach ($definition in $iconDefinitions) {
    $pixels = [int]($definition[1] * $definition[2])
    $filename = "$($definition[0])-$($definition[1])-$($definition[2]).png"
    $bitmap = [Drawing.Bitmap]::new($pixels, $pixels, [Drawing.Imaging.PixelFormat]::Format24bppRgb)
    $graphics = [Drawing.Graphics]::FromImage($bitmap)
    $graphics.Clear([Drawing.Color]::White)
    $graphics.InterpolationMode = [Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $graphics.DrawImage($originalIcon, 0, 0, $pixels, $pixels)
    $bitmap.Save((Join-Path $iconTarget $filename), [Drawing.Imaging.ImageFormat]::Png)
    $graphics.Dispose()
    $bitmap.Dispose()
    $iconItems += @{ idiom=$definition[0]; size="$($definition[1])x$($definition[1])"; scale="$($definition[2])x"; filename=$filename }
}
$originalIcon.Dispose()
@{ images=$iconItems; info=@{ version=1; author='xcode' } } | ConvertTo-Json -Depth 5 | Set-Content -Encoding utf8 (Join-Path $iconTarget 'Contents.json')
@{ info=@{ version=1; author='xcode' } } | ConvertTo-Json -Depth 5 | Set-Content -Encoding utf8 (Join-Path $PSScriptRoot 'GMSchedule/Assets.xcassets/Contents.json')
Write-Output 'Generated 18 app icon variants from assets/icon/app_icon.png'
