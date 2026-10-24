# 迁出 Ext1：数据库和 QQ 数据到内置盘，媒体到 HDD-1（2026-10-24）

上海时间。取代 [迁移到 Ext1](migration-ext1.md) 里的运行位置；Ext1 上的旧副本保留作备份，没有删除。

## 为什么迁

- Ext1（RTL9210B 盒子 + 120 GB NVMe）用 USB 2.0 线时稳定但慢（约 40 MB/s，随机读不中缓存时会话、媒体都卡）。
- 换成高速连接后反复掉盘：直连雷雳口 10 Gb/s、USB 口 5 Gb/s、经集线器 5 Gb/s 三种接法都掉过（05:47、06:05、06:31、06:35、08:01），
  每次数据库 PANIC 重启、NapCat 登录态写到一半丢失要重新扫码。共同点是这个盒子和盘本身，不是线或 Mac mini。
- 期间一次 12 Mb/s（USB 1.1）连接读出的 git 包校验不对，换到稳定连接后重读全部正确：那是读路径出错，盘上数据没坏。

## 实测（各 1 GiB 文件，F_NOCACHE 绕过缓存，每项 8 秒）

| | 顺序写 | 顺序读 | 4K 随机读 | 4K 写 + fsync |
|---|---|---|---|---|
| 内置 SSD | 1441 MB/s | 1147 MB/s | 10757 IOPS，p50 0.08 ms | 5986/s，p99 0.49 ms |
| Ext1（5 Gb/s） | 198 MB/s | 328 MB/s | 3772 IOPS，p50 0.26 ms | 1298/s，p99 1.01 ms |
| HDD-1 | 153 MB/s | 191 MB/s | 127 IOPS，p50 8 ms | 39/s，p99 38 ms |

数据库是小块随机读写，放 HDD 比 Ext1 还慢；媒体是整文件顺序读写，HDD 够用。

## 现在的位置

| 内容 | 位置 |
|---|---|
| 代码（仓库） | `~/Workspace/qq-bridge`（原来是指向 Ext1 的符号链接，现在是内置盘上的目录） |
| PostgreSQL | `~/deploy/postgres` |
| NapCat 配置 / 事件队列 | `~/deploy/napcat-config` |
| QQ 外层配置、登录态 | `~/deploy/qq`、`~/deploy/qq-user` |
| `.env`、APNs 密钥 | `~/deploy/.env`、`~/deploy/AuthKey_*.p8`；仓库里 `deploy/.env` 是指向它的符号链接 |
| 媒体、QQ 表情、诊断材料 | `/Volumes/HDD-1/XiaoMouz's Files/Depoly/QQ-Bridge/{media,qface,diagnostics}` |

- compose 的数据挂载改为 `${QQBRIDGE_DATA:-./data}/…`，`.env` 里 `QQBRIDGE_DATA=/Users/xiaomouz/deploy`；
  `MEDIA_ROOT` 指向 HDD-1（路径有空格和撇号，`.env` 里用双引号）；QQ 表情目录由服务端按 `MEDIA_ROOT/../qface` 推出。
- 仓库里 `deploy/data/` 是一组指向上面位置的符号链接（已被 .gitignore），`tools/` 和文档里的 `deploy/data/...` 路径照常可用。
- launchd 的 WorkingDirectory 改为 `~/Workspace/qq-bridge/packages/server`。
- OrbStack 在内置盘目录上跑 PostgreSQL 先单独测过：自动处理所有权（`fixing permissions ... ok`），PGroonga 正常。

## 验证

- 迁移前所有服务已停（08:01 掉盘时由守护脚本停下）；数据用 rsync 复制，复制后干跑对比 0 差异。
- 在新位置启动后：数据库自动恢复（只重放几 KB WAL）；全部 24 张表 `verify_heapam` 无问题，33 个核心 B-tree 索引 `bt_index_check(heapallindexed)` 通过；
  消息 961,077 条，全文搜索正常；清了 PGroonga 残留锁（当时没有写入方）。
- QQ 登录态复制完好，插件直接连上，不用扫码；启动后 5 分钟内入库 330 条（追平队列积压），实时入库 p50 62 ms（Ext1 上约 171 ms）。
- 新下载的媒体写进 HDD-1（5 分钟 12 个文件），Ext1 上 0 个；签名链接取媒体 200，1.37 MB 用时 0.11 s。

## 注意

- HDD-1 没挂载时媒体读写会失败（消息、数据库不受影响）；不要为了启动成功手工创建空的媒体目录。
- Ext1 上的旧副本（`/Volumes/Ext1/Workspace/qq-bridge`）不再使用，确认新位置稳定后再决定是否清理；不要在两份仓库里同时改代码。
