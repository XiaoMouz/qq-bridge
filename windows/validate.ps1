param([string]$Python = 'python')
$ErrorActionPreference = 'Stop'
Push-Location (Join-Path $PSScriptRoot '..')
try {
    & (Join-Path $PSScriptRoot 'generate-api.ps1') -Check
    & $Python (Join-Path $PSScriptRoot 'audit-api.py') --require-parity
    if ($LASTEXITCODE -ne 0) { throw '接口覆盖检查失败。' }
    dotnet run --project windows/BetterChat.Tests
    if ($LASTEXITCODE -ne 0) { throw '核心回归失败。' }
    # 独立输出避免覆盖用户正在运行的程序；不启动客户端、不读取登录凭据。
    dotnet build windows/BetterChat -p:Platform=x64 -p:OutputPath=bin/architecture-validation/ --nologo
    if ($LASTEXITCODE -ne 0) { throw 'WinUI 构建失败。' }
    Write-Output '离线验证通过；真实服务端和 Windows 交互需独立验收。'
} finally { Pop-Location }
