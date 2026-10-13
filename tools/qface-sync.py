#!/usr/bin/env python3
"""同步 QQ 表情资源（来源：koishijs/QFace，跟着 QQ 新版更新）。

用法：
  python3 tools/qface-sync.py            # 下载到 deploy/data/qface（服务端 /qface/... 提供给客户端：超级表情动画等）
  python3 tools/qface-sync.py --ios      # 另外更新 iOS 自带的小黄脸静态图（Resources/QQFaces）和 QQFaceNames.swift

QQ 出了新表情时重跑一次即可。下载走系统的 HTTP(S)_PROXY。已下载的文件不重复下载。
"""

import json
import os
import shutil
import sys
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor

BASE = "https://raw.githubusercontent.com/koishijs/QFace/master/public/"
REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(REPO, "deploy", "data", "qface")
IOS_FACES = os.path.join(REPO, "ios", "QQBridge", "Resources", "QQFaces")
IOS_NAMES = os.path.join(REPO, "ios", "QQBridge", "App", "QQFaceNames.swift")


def fetch(path: str) -> bytes:
    with urllib.request.urlopen(BASE + urllib.parse.quote(path), timeout=60) as r:
        return r.read()


def download(path: str) -> str | None:
    dest = os.path.join(OUT, path.removeprefix("assets/qq_emoji/"))
    if os.path.exists(dest) and os.path.getsize(dest) > 0:
        return None
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    try:
        data = fetch(path)
    except Exception as e:  # noqa: BLE001
        return f"{path}: {e}"
    with open(dest + ".part", "wb") as f:
        f.write(data)
    os.replace(dest + ".part", dest)
    return None


def main() -> None:
    os.makedirs(OUT, exist_ok=True)
    index = json.loads(fetch("assets/qq_emoji/_index.json"))
    with open(os.path.join(OUT, "_index.json"), "w") as f:
        json.dump(index, f, ensure_ascii=False)
    paths = [a["path"] for e in index for a in e["assets"]]
    with ThreadPoolExecutor(max_workers=8) as pool:
        errors = [e for e in pool.map(download, paths) if e]
    print(f"{len(index)} faces, {len(paths)} files, {len(errors)} failed")
    for e in errors[:20]:
        print("  ", e)
    if "--ios" in sys.argv:
        update_ios(index)


def update_ios(index: list[dict]) -> None:
    """小黄脸（数字编号）的静态图拷进 App；名字、类型、是否隐藏生成 QQFaceNames.swift。"""
    faces = [e for e in index if e["emojiId"].isdigit()]
    copied = 0
    for e in faces:
        fid = e["emojiId"]
        src = os.path.join(OUT, fid, "png", f"{fid}.png")
        if not os.path.exists(src):
            continue
        dest = os.path.join(IOS_FACES, f"s{fid}.png")
        if not os.path.exists(dest):
            shutil.copyfile(src, dest)
            copied += 1
    emoji = [e for e in index if e["emojiType"] == 4 and e["qcid"]]

    def name(e: dict) -> str:
        return e["describe"].removeprefix("/").replace("\\", "\\\\").replace('"', '\\"')

    lines = [
        "// 由 tools/qface-sync.py --ios 生成（来源 koishijs/QFace，跟着 QQ 新版更新），不要手改。",
        "// 小黄脸编号 → 名字、类型（0 普通、1 超级表情、2 互动（骰子等）、3 连发系列、5 大表情）、QQ 里是否隐藏。",
        "",
        "extension QQFace {",
        "  struct Info {",
        "    let name: String",
        "    let type: Int",
        "    let hidden: Bool",
        "  }",
        "",
        "  static let infos: [Int: Info] = [",
    ]
    for e in sorted(faces, key=lambda e: int(e["emojiId"])):
        lines.append(f'    {e["emojiId"]}: Info(name: "{name(e)}", type: {e["emojiType"]}, hidden: {str(e["isHide"]).lower()}),')
    lines += [
        "  ]",
        "",
        "  static let names: [Int: String] = infos.mapValues(\\.name)",
        "",
        "  /// QQ 的 emoji 表情（回应用码点做 id）：码点 → 名字。按 QQ 里的顺序。",
        "  static let emoji: [(code: Int, name: String)] = [",
    ]
    for e in emoji:
        if e["isHide"]:
            continue
        lines.append(f'    ({e["qcid"]}, "{name(e)}"),')
    lines += ["  ]", "}", ""]
    with open(IOS_NAMES, "w") as f:
        f.write("\n".join(lines))
    print(f"iOS: copied {copied} new face images, wrote {len(faces)} faces / {len(emoji)} emoji to QQFaceNames.swift")


if __name__ == "__main__":
    main()
