// 还不支持的 QQ 消息元素（服务端存成 unknown 段，原文在 data_json 里）：
// 不再在气泡里写一行「[暂不支持的消息]」，而是一张卡片说明是什么（红包、长消息、没认出的灰条……），
// 点开能按字段名 / 内容即时筛选原始数据，方便以后照着加支持。
import QQBridgeProto
import SwiftUI
import UIKit

/// 一个不支持的元素：从原文里读出能看懂的几项，其余原样保留。
struct UnsupportedItem: Identifiable {
  let id = UUID()
  /// 服务端给的类型（`nt:9` 这样的 NT 元素类型，或 OneBot 段的类型名）。
  let original: String
  let title: String
  let subtitle: String
  let icon: String
  let tint: Color
  /// 原文（JSON），没有时为空。
  let json: Any?
  let rawText: String

  init(_ u: Qqbridge_V1_UnknownSegment) {
    original = u.original
    rawText = u.dataJson
    let parsed = u.dataJson.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) }
    json = parsed
    let root = parsed as? [String: Any] ?? [:]
    switch u.original {
    case "nt:9":
      // QQ 红包（walletElement，2026-10-15 库里 57 条）：标题在 receiver.title，「[QQ红包]恭喜发财」在 receiver.notice。
      let receiver = (root["walletElement"] as? [String: Any])?["receiver"] as? [String: Any]
      title = "QQ红包"
      subtitle = Self.string(receiver?["title"]) ?? Self.string(receiver?["notice"]) ?? "在 QQ 里领取"
      icon = "gift.fill"
      tint = .red
    case "nt:13":
      // 长消息（structLongMsgElement）：xml 里 brief / summary 是 QQ 给的提示语。
      let xml = Self.string((root["structLongMsgElement"] as? [String: Any])?["xmlContent"]) ?? ""
      title = "长消息"
      subtitle = Self.xmlValue(xml, tag: "summary") ?? Self.xmlAttribute(xml, name: "brief") ?? "完整内容只能在 QQ 里看"
      icon = "text.alignleft"
      tint = .indigo
    case "nt:8":
      let sub = (root["grayTipElement"] as? [String: Any])?["subElementType"]
      title = "灰色提示"
      subtitle = sub.map { "子类型 \($0)，还没认出来" } ?? "还没认出来"
      icon = "info.circle.fill"
      tint = .gray
    default:
      // 其他：用原文里第一个有内容的 xxxElement 的名字说明是哪一类。
      let element = root.keys.sorted().first { $0.hasSuffix("Element") && !(root[$0] is NSNull) && $0 != "extBufForUI" }
      title = "暂不支持的消息"
      subtitle = element ?? u.original
      icon = "questionmark.square.dashed"
      tint = .orange
    }
  }

  /// 会话列表、搜索结果里的一句话。
  var preview: String { subtitle.isEmpty || title == "暂不支持的消息" ? "[\(title)]" : "[\(title)] \(subtitle)" }

  /// 所有有内容的叶子字段（路径 → 值），空字符串、0、空对象不列出；详情页按它筛选。
  var fields: [(path: String, value: String)] {
    var out: [(String, String)] = []
    Self.flatten(json, path: "", into: &out)
    return out
  }

  var prettyJSON: String {
    guard let json, JSONSerialization.isValidJSONObject(json),
      let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    else { return rawText }
    return String(decoding: data, as: UTF8.self)
  }

  private static func flatten(_ value: Any?, path: String, into out: inout [(String, String)]) {
    switch value {
    case let dict as [String: Any]:
      // 字节数组被序列化成了 {"0": 8, "1": 2, …}：整个当成一项，不逐个列。
      if !dict.isEmpty, dict.keys.allSatisfy({ Int($0) != nil }) {
        out.append((path, "\(dict.count) 字节"))
        return
      }
      for key in dict.keys.sorted() { flatten(dict[key], path: path.isEmpty ? key : "\(path).\(key)", into: &out) }
    case let array as [Any]:
      for (i, item) in array.enumerated() { flatten(item, path: "\(path)[\(i)]", into: &out) }
    case let s as String:
      if !s.isEmpty { out.append((path, s)) }
    case let n as NSNumber:
      if n != 0 { out.append((path, n.stringValue)) }
    default:
      break
    }
  }

  private static func string(_ v: Any?) -> String? {
    guard let s = v as? String, !s.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
    return s
  }

  private static func xmlValue(_ xml: String, tag: String) -> String? {
    guard let r = xml.range(of: "<\(tag)>(.*?)</\(tag)>", options: .regularExpression) else { return nil }
    let inner = xml[r].replacingOccurrences(of: "</?\(tag)>", with: "", options: .regularExpression)
    return inner.isEmpty ? nil : inner
  }

  private static func xmlAttribute(_ xml: String, name: String) -> String? {
    guard let r = xml.range(of: "\(name)=\"[^\"]*\"", options: .regularExpression) else { return nil }
    let value = xml[r].dropFirst(name.count + 2).dropLast()
    return value.isEmpty ? nil : String(value)
  }
}

extension Qqbridge_V1_Message {
  /// 消息里不支持的元素（不含机器人按钮、骰子、猜拳这些已经单独处理的）。
  var unsupportedItems: [UnsupportedItem] {
    segments.compactMap { seg in
      guard case .unknown(let u) = seg.kind, !["keyboard", "dice", "rps"].contains(u.original) else { return nil }
      return UnsupportedItem(u)
    }
  }
}

/// 聊天里的卡片：不画气泡，直接一张卡。
struct UnsupportedCard: View {
  let item: UnsupportedItem
  let onOpen: (UnsupportedItem) -> Void

  var body: some View {
    Button { onOpen(item) } label: {
      VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 10) {
          Image(systemName: item.icon)
            .font(.title3)
            .foregroundStyle(.white)
            .frame(width: 36, height: 36)
            .background(item.tint.gradient, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
          VStack(alignment: .leading, spacing: 2) {
            Text(item.title).font(.subheadline.weight(.semibold))
            Text(item.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
          }
        }
        Divider()
        HStack(spacing: 4) {
          Text(item.original).font(.caption2.monospaced())
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(.quaternary, in: Capsule())
          Text("点开看原始数据").font(.caption2)
          Image(systemName: "chevron.right").font(.caption2.bold())
          // 右下角留给发送时间的小胶囊。
          Spacer(minLength: 48)
        }
        .foregroundStyle(.secondary)
      }
      .padding(12)
      .frame(width: 236, alignment: .leading)
      .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
      .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(item.tint.opacity(0.35), lineWidth: 1))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel("\(item.title)，\(item.subtitle)")
    .accessibilityHint("打开原始数据")
  }
}

/// 详情：顶部摘要；字段列表能按名字或内容即时筛选；原始 JSON 能复制。
struct UnsupportedDetailView: View {
  let item: UnsupportedItem
  @Environment(\.dismiss) private var dismiss
  @State private var query = ""
  @State private var showRaw = false
  @State private var copied: String?

  private var shown: [(path: String, value: String)] {
    let q = query.trimmingCharacters(in: .whitespaces)
    guard !q.isEmpty else { return item.fields }
    return item.fields.filter { $0.path.localizedCaseInsensitiveContains(q) || $0.value.localizedCaseInsensitiveContains(q) }
  }

  var body: some View {
    NavigationStack {
      List {
        Section {
          HStack(spacing: 12) {
            Image(systemName: item.icon).font(.title2).foregroundStyle(.white)
              .frame(width: 44, height: 44)
              .background(item.tint.gradient, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
              Text(item.title).font(.headline)
              Text(item.subtitle).font(.subheadline).foregroundStyle(.secondary)
            }
          }
          LabeledContent("类型", value: item.original).font(.subheadline.monospaced())
        }
        Section {
          if shown.isEmpty {
            Text(item.fields.isEmpty ? "原文里没有可显示的字段" : "没有匹配「\(query)」的字段").foregroundStyle(.secondary)
          }
          ForEach(Array(shown.enumerated()), id: \.offset) { _, field in
            VStack(alignment: .leading, spacing: 2) {
              Text(field.path).font(.caption.monospaced()).foregroundStyle(.secondary)
              Text(field.value).font(.callout).textSelection(.enabled).lineLimit(6)
            }
            .contextMenu {
              Button("复制值", systemImage: "doc.on.doc") { copy(field.value, "已复制值") }
              Button("复制字段名", systemImage: "character.cursor.ibeam") { copy(field.path, "已复制字段名") }
            }
          }
        } header: {
          Text("字段（\(shown.count)/\(item.fields.count)）")
        } footer: {
          Text("长按一项可复制。空值、0 和字节数组已省略，完整内容见下面的原始数据。")
        }
        Section {
          DisclosureGroup("原始数据（JSON）", isExpanded: $showRaw) {
            ScrollView(.horizontal) {
              Text(item.prettyJSON).font(.caption2.monospaced()).textSelection(.enabled).padding(.vertical, 4)
            }
          }
          Button("复制原始数据", systemImage: "doc.on.doc") { copy(item.prettyJSON, "已复制原始数据") }
        }
      }
      .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "按字段名或内容筛选")
      .navigationTitle("消息详情")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
      .overlay(alignment: .bottom) {
        if let copied {
          Text(copied).font(.subheadline).padding(.horizontal, 14).padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule()).padding(.bottom, 24)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
      }
      .animation(.default, value: copied)
    }
  }

  private func copy(_ text: String, _ note: String) {
    UIPasteboard.general.string = text
    copied = note
    Task {
      try? await Task.sleep(for: .seconds(1.5))
      if copied == note { copied = nil }
    }
  }
}

/// 聊天页弹出详情（单独的 ViewModifier：聊天页的 body 已经很长，见 lessons L5）。
struct UnsupportedSheet: ViewModifier {
  @Binding var item: UnsupportedItem?

  func body(content: Content) -> some View {
    content.sheet(item: $item) { UnsupportedDetailView(item: $0) }
  }
}
