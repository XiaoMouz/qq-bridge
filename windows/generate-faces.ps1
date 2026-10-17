$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot
$source = Get-Content -LiteralPath (Join-Path $repo 'ios/QQBridge/App/QQFaceNames.swift') -Raw -Encoding utf8
$pattern = '(\d+): Info\(name: "([^"]+)", type: (\d+), hidden: (true|false)\)'
$rows = @([regex]::Matches($source, $pattern) | ForEach-Object {
    $faceId = $_.Groups[1].Value
    if (Test-Path -LiteralPath (Join-Path $repo "ios/QQBridge/Resources/QQFaces/s$faceId.png")) {
        [ordered]@{ Id = $faceId; Name = $_.Groups[2].Value; Type = [int]$_.Groups[3].Value; Hidden = $_.Groups[4].Value -eq 'true' }
    }
})
if ($rows.Count -eq 0) { throw '共享表情目录为空，请检查 iOS 生成文件格式。' }
$rows | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath (Join-Path $PSScriptRoot 'BetterChat/Assets/FaceCatalog.json') -Encoding utf8
Write-Output "已生成 $($rows.Count) 个共享表情条目。"
