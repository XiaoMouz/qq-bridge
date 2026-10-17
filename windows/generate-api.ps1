param([switch]$Check)
$ErrorActionPreference = 'Stop'
$protoRoot = Join-Path $PSScriptRoot '../packages/protocol/proto/qqbridge/v1'
$header = '// 从 packages/protocol 自动生成；运行 windows/generate-api.ps1 更新，不手改。'
$contracts = [System.Collections.Generic.List[string]]::new()
$implementation = [System.Collections.Generic.List[string]]::new()
$services = [System.Collections.Generic.List[string]]::new()
$contracts.Add($header); $contracts.Add('using Qqbridge.V1;'); $contracts.Add('namespace BetterChat.Core;')
$implementation.Add($header); $implementation.Add('using Qqbridge.V1;'); $implementation.Add('namespace BetterChat.Core;')
$implementation.Add('public sealed class BridgeApi(ConnectClient transport) : IBridgeApi')
$implementation.Add('{'); $implementation.Add('    public ConnectClient Transport { get; } = transport;')
foreach ($file in Get-ChildItem $protoRoot -Filter '*.proto' | Sort-Object Name) {
    $source = Get-Content $file.FullName -Raw -Encoding utf8
    foreach ($block in [regex]::Matches($source, 'service\s+(\w+)\s*\{([^}]+)\}')) {
        $service = $block.Groups[1].Value
        $services.Add("I$service")
        $contracts.Add("public interface I$service"); $contracts.Add('{')
        foreach ($rpc in [regex]::Matches($block.Groups[2].Value, 'rpc\s+(\w+)\((\w+)\)\s+returns\s+\((stream\s+)?(\w+)\)')) {
            $method, $request, $stream, $response = $rpc.Groups[1..4].Value
            $returnType = if ($stream) { "IAsyncEnumerable<$response>" } else { "Task<$response>" }
            $call = if ($stream) { 'StreamAsync' } else { 'UnaryAsync' }
            $contracts.Add("    $returnType ${method}Async($request request, CancellationToken ct = default);")
            $implementation.Add("    public $returnType ${method}Async($request request, CancellationToken ct = default) => Transport.$call(`"qqbridge.v1.$service/$method`", request, $response.Parser, ct);")
        }
        $contracts.Add('}')
    }
}
$contracts.Add('public interface IBridgeApi : ' + ($services -join ', ') + ' { }')
$implementation.Add('}')
foreach ($output in @(
    @{ Path = 'BetterChat.Application/BackendContracts.g.cs'; Lines = $contracts },
    @{ Path = 'BetterChat.Infrastructure/BridgeApi.g.cs'; Lines = $implementation }
)) {
    $path = Join-Path $PSScriptRoot $output.Path
    if ($Check) {
        $expected = ($output.Lines -join "`n") + "`n"
        if (!(Test-Path -LiteralPath $path) -or [IO.File]::ReadAllText($path).Replace("`r`n", "`n") -cne $expected) {
            throw "协议生成文件已过期：$($output.Path)。请运行 windows/generate-api.ps1 后检查差异。"
        }
    } else { [IO.File]::WriteAllLines($path, $output.Lines) }
}
if ($Check) { Write-Output "协议生成检查通过：$($services.Count) 个服务与当前 proto 一致，未修改文件。" }
else { Write-Output "已生成 $($services.Count) 个后端服务接口和 Connect 实现。" }
