#!/usr/bin/env python3
"""编译真实生产源码运行状态检查；仅使用临时目录，不连接账号或真实后端。"""

from pathlib import Path
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[2]
SOURCE_ROOTS = (ROOT / "macos/BetterChat/App", ROOT / "ios/QQBridge/App")
CHECKS = {
    "LoginViewModelCheck": ("MacAuthenticationService.swift", "MacLoginViewModel.swift"),
    "ManualSyncCheck": ("MacManualSync.swift",),
    "ChatOpenRequestCheck": ("MacChatOpenRequest.swift",),
    "DownloadFilesCheck": ("MacDownloadFiles.swift",),
    "DownloadSettingsCheck": ("MacDownloadPreferences.swift", "MacDownloadSettingsViewModel.swift"),
    "GroupFileSelectionCheck": ("GroupFileSelection.swift",),
    "NotificationReadCheck": ("NotificationReadPolicy.swift",),
}


def production_source(name: str) -> Path:
    # 允许功能目录迁移，但同名实现重复或源码缺失时必须失败，不能悄悄测试旧副本。
    matches = [p for root in SOURCE_ROOTS for p in root.rglob(name)]
    if len(matches) != 1:
        raise RuntimeError(f"{name} 应对应一份生产源码，实际为 {matches}")
    return matches[0]


def main() -> None:
    with tempfile.TemporaryDirectory(prefix="betterchat-state-checks-") as temporary:
        for check, names in CHECKS.items():
            executable = Path(temporary) / check
            print(f"检查 {check}", flush=True)
            subprocess.run([
                "xcrun", "swiftc", "-swift-version", "6", "-parse-as-library",
                *(str(production_source(name)) for name in names),
                str(Path(__file__).parent / f"{check}.swift"), "-o", str(executable),
            ], check=True, cwd=ROOT)
            subprocess.run([str(executable)], check=True, cwd=ROOT)
    print(f"{len(CHECKS)} 组状态与文件检查全部通过。", flush=True)


if __name__ == "__main__":
    main()
