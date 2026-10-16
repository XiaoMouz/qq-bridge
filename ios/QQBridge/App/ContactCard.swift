// 推荐联系人 / 群名片（light_app，app = com.tencent.contact.lua）。
// 以前走通用小程序卡片：没有 title / desc，解析不出来，只剩一行「推荐联系人：xxx」。
// 2026-10-16 库里 16 条，两种（字段对照过真实消息）：
// - 推荐好友：bizsrc cardshare.cardshare，meta.contact.contact 是「账号：<QQ号>」，jumpUrl 带 uin。
// - 群名片：bizsrc qun.share，jumpUrl 带 card_type=group&uin=<群号>，contact 是「在这里，发现更多~」这种口号。
import SwiftUI

struct ContactCard: Hashable {
  enum Kind { case user, group }
  let kind: Kind
  let uin: Int64
  let name: String
  let avatar: URL?
  /// 卡片上的标签（推荐好友 / 群名片）。
  let tag: String

  static func parse(json: String, app: String) -> ContactCard? {
    guard app == "com.tencent.contact.lua", let data = json.data(using: .utf8),
      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let c = (obj["meta"] as? [String: Any])?["contact"] as? [String: Any]
    else { return nil }
    let jump = URLComponents(string: c["jumpUrl"] as? String ?? "")?.queryItems ?? []
    let isGroup = jump.contains { $0.name == "card_type" && $0.value == "group" } || (obj["bizsrc"] as? String) == "qun.share"
    // QQ 号优先从 jumpUrl 取；推荐好友的「账号：123」兜底。
    let fromText = (c["contact"] as? String)?.firstMatch(of: /\d{5,}/).map { String($0.output) }
    guard let uin = Int64(jump.first { $0.name == "uin" }?.value ?? fromText ?? "") else { return nil }
    let avatar = (c["avatar"] as? String).flatMap { s -> URL? in
      // http 的头像换成 https（qlogo 都支持），否则 iOS 不让加载。
      URL(string: s.hasPrefix("http://") ? "https://" + s.dropFirst(7) : s)
    }
    let tag = (c["tag"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (isGroup ? "群名片" : "推荐好友")
    return ContactCard(kind: isGroup ? .group : .user, uin: uin, name: c["nickname"] as? String ?? "", avatar: avatar, tag: tag)
  }

  var subtitle: String { kind == .group ? "群号 \(uin)" : "QQ \(uin)" }
}

/// 卡片：头像、名字、号码；下面一行写点了会怎样。推荐好友点开看资料，群名片点了复制群号。
struct ContactCardView: View {
  let card: ContactCard
  let onOpen: (ContactCard) -> Void

  var body: some View {
    Button { onOpen(card) } label: {
      VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 10) {
          RemoteImage(url: card.avatar, maxPixel: 160)
            .frame(width: 44, height: 44)
            .clipShape(card.kind == .group ? AnyShape(RoundedRectangle(cornerRadius: 10, style: .continuous)) : AnyShape(Circle()))
          VStack(alignment: .leading, spacing: 2) {
            Text(card.name.isEmpty ? card.subtitle : card.name).font(.subheadline.weight(.semibold)).lineLimit(1)
            Text(card.subtitle).font(.caption).opacity(0.7).lineLimit(1)
          }
        }
        Divider()
        Label(card.tag, systemImage: card.kind == .group ? "person.3" : "person.crop.circle.badge.plus")
          .font(.caption2).opacity(0.7)
      }
      .frame(width: 220, alignment: .leading)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel("\(card.tag)：\(card.name)，\(card.subtitle)")
    .accessibilityHint(card.kind == .group ? "复制群号" : "查看资料")
  }
}
