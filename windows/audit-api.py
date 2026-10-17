"""核对 proto、Apple 实际调用与 Windows 调用证据；生成层不能代表业务已验收。"""
from pathlib import Path
import json
import re
import sys

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "windows" / "docs"
OUT.mkdir(exist_ok=True)

# 用户明确选择 Subscribe + Windows 本地通知；APNs 专用接口不属于 Windows 业务基线。
PLATFORM_EXEMPTIONS = {
    "AuthService.RegisterPush": "APNs 专用注册；Windows 使用 Subscribe 事件与原生本地通知，不注册 APNs，也不扩展 WNS。",
}

def sources(roots, suffix):
    return [(p, p.read_text(encoding="utf-8-sig")) for root in roots for p in (ROOT / root).rglob("*" + suffix)
            if not {"bin", "obj", ".build", "Tests", "tests", "Generated"}.intersection(p.parts) and not p.name.endswith(".g.cs")]

apple = sources(["ios/QQBridge/App", "ios/QQBridge/NotificationService", "ios/QQBridgeKit/Sources/QQBridgeKit", "macos/BetterChat"], ".swift")
windows = sources(["windows/BetterChat", "windows/BetterChat.Application", "windows/BetterChat.Infrastructure"], ".cs")

def evidence(files, pattern):
    result = []
    for path, source in files:
        for match in re.finditer(pattern, source, re.I):
            result.append(str(path.relative_to(ROOT)).replace("\\", "/") + ":" + str(source.count("\n", 0, match.start()) + 1))
    return result

rows = []
contracts = (ROOT / "windows/BetterChat.Application/BackendContracts.g.cs").read_text(encoding="utf-8-sig")
implementation = (ROOT / "windows/BetterChat.Infrastructure/BridgeApi.g.cs").read_text(encoding="utf-8-sig")
for proto in sorted((ROOT / "packages/protocol/proto/qqbridge/v1").glob("*.proto")):
    for service, body in re.findall(r"service\s+(\w+)\s*\{([^}]+)\}", proto.read_text(encoding="utf-8")):
        for method, request, stream, response in re.findall(r"rpc\s+(\w+)\((\w+)\)\s+returns\s+\((stream\s+)?(\w+)\)", body):
            apple_calls = evidence(apple, r"\.\s*" + method + r"\s*\(")
            windows_calls = evidence(windows, r"\.\s*" + method + r"Async\b")
            rows.append(dict(service=service, method=method, request=request, response=response, streaming=bool(stream),
                contract=method+"Async(" in contracts, transport=f"qqbridge.v1.{service}/{method}" in implementation,
                apple=apple_calls, windows=windows_calls,
                platform_exemption=PLATFORM_EXEMPTIONS.get(f"{service}.{method}")))
(OUT / "api-coverage.json").write_text(json.dumps(rows, ensure_ascii=False, indent=2)+"\n", encoding="utf-8")
lines = ["# 后端接口对齐清单", "", "由 `windows/audit-api.py` 从当前源码生成。Apple 列扫描 iOS App、QQBridgeKit 和 macOS App 的实际方法调用，排除生成代码与测试；Windows 列同样排除生成客户端。静态调用证据不等同于运行验收，也不能证明间接封装没有使用该接口。", "", "要求：Apple 实际使用的接口是最低覆盖线；Windows 的协议与注入契约覆盖全部后端 RPC。除用户明确排除的平台接口外，缺少业务调用的接口必须继续补齐，不能以生成方法代替。", "", "| 服务 / RPC | 契约 / 传输 | Apple 调用证据 | Windows 调用证据 |", "|---|---|---|---|"]
for row in rows:
    def link(items):
        if not items: return "未发现直接调用"
        return "<br>".join("`"+p+"`" for p in items[:3]) + (f"（共 {len(items)} 处）" if len(items)>3 else "")
    lines.append(f"| {row['service']}.{row['method']} | {'齐全' if row['contract'] and row['transport'] else '缺失'} | {link(row['apple'])} | {link(row['windows'])} |")
exempt = [r for r in rows if r['apple'] and r['platform_exemption']]
missing = [r for r in rows if r['apple'] and not r['windows'] and not r['platform_exemption']]
lines += ["", f"共 {len(rows)} 个 RPC；Apple 有直接调用证据 {sum(bool(r['apple']) for r in rows)} 个；明确平台豁免 {len(exempt)} 个；未豁免且 Windows 尚无直接业务调用证据 {len(missing)} 个。", "", "## Apple 基线下的业务缺口", ""]
lines += [f"- `{r['service']}.{r['method']}`" for r in missing]
if not missing: lines += ["无未豁免的静态调用缺口；不代表流程、宿主绑定或平台实现已验收。"]
lines += ["", "## 用户明确排除的平台接口", ""]
lines += [f"- `{r['service']}.{r['method']}`：{r['platform_exemption']}保留生成契约与传输实现，不伪造业务调用。" for r in exempt]
lines += ["", "Windows 原生通知适配已接入，实际弹出与点击仍待实机验收。方案仅覆盖程序运行且 Subscribe 可用期间；程序完全退出后的后台推送不在当前范围。"]
(OUT / "api-coverage.md").write_text("\n".join(lines)+"\n", encoding="utf-8")
print(json.dumps(dict(rpcs=len(rows),apple=sum(bool(r['apple']) for r in rows),platform_exemptions=len(exempt),missing_workflows=len(missing))))
if any(not r['contract'] or not r['transport'] for r in rows): raise SystemExit("missing RPC contract or transport")

if "--require-parity" in sys.argv and missing:
    raise SystemExit(f"Apple baseline not met: {len(missing)} missing Windows call sites")
