# 通话桥实测记录

QQ 通话桥（NapCat 插件 + AV Host + PulseAudio + call-gateway + LiveKit）的指令、事件和实测结论。方案见 [design.md](design.md) 第 5 节；这里记的是**实际抓到、验证过的东西**，改通话代码前先看。

## 链路

```
QQ 内核（NapCat 进程）⇄ 插件 call/avsdk-bridge.ts ⇄ HTTP ⇄ AV Host（packages/av-host，加载 libAVSDKPlugin.so）
                                                                  ⇅ PulseAudio（qq_speaker / qq_mic）
                                                   call-gateway（@livekit/rtc-node）⇄ LiveKit ⇄ iPhone（LiveKit Swift）
服务端 calls/service.ts：状态落库、推 CallUpdate / VoIP 推送、建房间签令牌、让网关入会
```

## 通话引擎指令（发给 AV Host 的 cmd）

指令号 = `libAVSDKPlugin.so` 里 `QRTCServiceInterfaceWrapper` 方法表（成员函数指针，每项 16 字节）的下标，`CallCpp` 按 `表基址 + cmd*16` 取函数。2026-10-13 从符号表和 `.rela.dyn` 还原；param 是方法除第一个参数（实例 id）以外的参数。

| cmd | 方法 | 参数（实测） | 状态 |
|---|---|---|---|
| 1 | Login | `[selfUid, selfUin, selfUin, accountPath, ""]` | 已用 |
| 4 | StartCall | 一段 JSON：`{"scene":1,"relation_id":0,"sub_business_type":1,"invite_uids":[uid],"invite_count":1,"invite_reason":0,"invite_original":0}` | 已用（1 对 1 语音） |
| 5 | Accept | 来电数组重排：`[invite[0], invite[1], [invite[1]], invite[3], invite[4], Boolean(invite[10]), invite[11]]`（`accept-params.ts`） | 已用 |
| 8 | Quit | `[类型, 0]` | 退出群语音（Close 不会退房间） |
| 9 | Reject | `[类型, 对方 uid, 0]` | 拒接（引擎发 SsoRefuseInvite） |
| 10 | Close | `[类型, 对方 uid, 0]` | 挂断 / 取消呼叫（引擎发 SsoLogOut） |
| 22 / 23 | CloseMic / OpenMic | 未用 | |
| 55 | OnPenetrateEvent | `[actionType, base64]` | 转发内核数据 |

AV Host 默认只放行 `1, 4, 5, 8, 9, 10, 55`（`host.cjs` 的 `DEFAULT_ALLOWED_COMMANDS`），研究模式（`QQBRIDGE_LAB=1`）放开。

**群语音另一套接口 `GroupLiveVideoInterfaceWrapper` 在 Linux 版里全是空函数**（每个方法只有一条 `ret`）。被邀请的群语音走的是上面这套 1 对 1 的接口（invite_type 3）。

## 引擎输出（AV Host 转来的 cmd）

| cmd | 含义 |
|---|---|
| 1 | 登录结果 `[0, ""]` |
| 4 / 5 / 8 / 9 / 10 | 对应指令的结果 `[0, ""]` 成功 |
| 20001 | 网络数据，要交回内核（`setActionFromAVSDK`） |
| 20004 | 进入房间（已接通）`[0, 类型, 群号或房间号, …]` |
| 20006 | 来电详情：`[类型, 邀请人 uid, [被邀请 uid], ?, 群号 / 会话键, ?, 房间号, …]` |
| 20021 | 呼叫送达状态（对方在线、哪个终端） |
| 20040 / 20041 | 音量（20041 是某人的音量） |
| 20050 | **引擎自己的日志行**（不是要求重登，见 lessons L2） |
| 120043 | 要求重新登录 |

## 内核回调

| 回调 | 用途 |
|---|---|
| `onInviteActionToAVSDK` | 来电：`args[0] = { relation_id, invite_type }`（1 = 1 对 1，3 = 群语音，relation_id 是群号） |
| `onActionToAVSDK` | 普通数据，转给引擎（cmd 55） |
| `onS2CActionToAVSDK` | `[ { destroyReason, pushRoomInfoList }, 动作 ]`。**动作 14 或 destroyReason > 0 才是结束**；动作 10 + destroyReason 0 是房间状态（打出去时对方接听就是它） |
| `onGroupVideoInviteMemberUpdate` | 群语音成员变化：`{ groupId, roomId, join, quit, eventType }`。别人发起群语音时只来一次 eventType 2，结束时没有事件 |

内核的 `getAVSDKService` 只有 `addKernelAVSDKListener / removeKernelAVSDKListener / setActionFromAVSDK / sendGroupVideoJsonBuffer / startGroupVideoCmdRequestFromAVSDK`，没有发起、挂断的方法——都要走引擎。

**`removeKernelAVSDKListener` 在插件热重载时不生效**：监听每个进程只注册一次（挂在 `globalThis` 的 Symbol 上），事件转给当前的通话桥。否则重载一次多一个监听，一个事件会被转发几十遍，打出去的电话对方一接就断。

## 实测结论（2026-10-13）

- 来电接听、拒接（对方显示「对方已拒绝」）、挂断（对方通话结束）：通过。
- 打出去：对方手机响铃、接听、保持通话 71 秒、从 App 挂断：通过。
- 被邀请的群语音：接听后能收到邀请人的音量；Close 不会退出，要 Quit。
- 没被邀请的群语音：只能检测到「开始」（一次 `onGroupVideoInviteMemberUpdate`），没有结束事件，也没找到加入的方法 → 未做。
- 模拟器的麦克风、播放会报 -4010（模拟器问题），双向声音要在真机上验。
- 通话桥同一时间只跟踪一通：新来电替换旧的时，旧的不会再有结束状态 → 服务端收新通话时把旧的记为结束，响铃超过 2 分钟的也记为结束。

## 调试

- 当前通话：`POST/GET http://127.0.0.1:6110/v1/calls/{current,accept,hangup,start}`（容器内，Bearer 控制令牌）。
- 直接给引擎发指令：`POST http://127.0.0.1:6111/v1/invoke {"command":8,"params":[3,0]}`（AV Host）。
- 原始数据：`deploy/data/napcat-config/plugins/napcat-plugin-qqbridge/capture/avsdk-*.jsonl`（内核回调、引擎输入输出）、`avsdk-log-*.jsonl`（引擎日志）。
- 网关状态：`curl --noproxy '*' http://127.0.0.1:6120/status -H "authorization: Bearer $CALL_GATEWAY_TOKEN"`（`framesSent` 是 QQ 那边的声音进了房间）。
