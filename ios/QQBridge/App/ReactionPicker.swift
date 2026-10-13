// 表情回应：QQ 能用来回应的都能选——所有 QQ 小黄脸（QQ 里没藏起来的）和 QQ 的 emoji（用码点做 id）。
// 长按菜单里先列最近用过的几个，「更多表情…」打开完整的面板（可按名字搜）。
import SwiftUI
import UIKit

enum ReactionRecents {
  private static let key = "recentReactions"
  /// 没用过时的默认（QQ 回应里最常见的几个）：赞、爱心、玫瑰、OK、doge、笑哭。
  private static let defaults = ["76", "66", "63", "124", "179", "128514"]

  static var list: [String] {
    let saved = UserDefaults.standard.stringArray(forKey: key) ?? []
    var out = saved
    for d in defaults where !out.contains(d) { out.append(d) }
    return Array(out.prefix(8))
  }

  static func use(_ id: String) {
    var saved = UserDefaults.standard.stringArray(forKey: key) ?? []
    saved.removeAll { $0 == id }
    saved.insert(id, at: 0)
    UserDefaults.standard.set(Array(saved.prefix(16)), forKey: key)
  }
}

/// 回应的显示：小黄脸用图，emoji 用字。
enum ReactionLabel {
  /// 菜单里用的小图标：小黄脸用 QQ 的图，emoji 画成图（和小黄脸对齐）。
  @MainActor static func icon(_ id: String, size: CGFloat) -> UIImage? {
    if let code = Int(id), code > 0x2000, let scalar = Unicode.Scalar(code) {
      let text = String(Character(scalar)) as NSString
      let font = UIFont.systemFont(ofSize: size * 0.85)
      return UIGraphicsImageRenderer(size: CGSize(width: size, height: size)).image { _ in
        let bounds = text.size(withAttributes: [.font: font])
        text.draw(at: CGPoint(x: (size - bounds.width) / 2, y: (size - bounds.height) / 2), withAttributes: [.font: font])
      }
    }
    return QQFace.image(id, size: size)
  }

  static func name(_ id: String) -> String {
    if let code = Int(id), code > 0x2000 {
      return QQFace.emoji.first { $0.code == code }?.name ?? QQFace.text(id)
    }
    if let code = Int(id), let name = QQFace.names[code] { return name }
    return "表情"
  }
}

struct ReactionPicker: View {
  let onPick: (String) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var query = ""

  private let columns = [GridItem(.adaptive(minimum: 44), spacing: 6)]

  private var faces: [(id: Int, name: String)] {
    let q = query.trimmingCharacters(in: .whitespaces)
    return q.isEmpty ? QQFace.pickable : QQFace.pickable.filter { $0.name.contains(q) }
  }

  private var emoji: [(code: Int, name: String)] {
    let q = query.trimmingCharacters(in: .whitespaces)
    return q.isEmpty ? QQFace.emoji : QQFace.emoji.filter { $0.name.contains(q) }
  }

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 14) {
          if query.isEmpty {
            section("最近使用") {
              ForEach(ReactionRecents.list, id: \.self) { id in cell(id: id, name: ReactionLabel.name(id)) }
            }
          }
          if !faces.isEmpty {
            section("QQ 表情") {
              ForEach(faces, id: \.id) { f in cell(id: String(f.id), name: f.name) }
            }
          }
          if !emoji.isEmpty {
            section("Emoji") {
              ForEach(emoji, id: \.code) { e in cell(id: String(e.code), name: e.name) }
            }
          }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
      }
      .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索表情")
      .navigationTitle("回应")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
    }
  }

  private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(title).font(.footnote).foregroundStyle(.secondary)
      LazyVGrid(columns: columns, spacing: 6) { content() }
    }
  }

  private func cell(id: String, name: String) -> some View {
    Button {
      ReactionRecents.use(id)
      onPick(id)
    } label: {
      QQFace.view(id, size: 30)
        .font(.system(size: 28))
        .frame(width: 44, height: 44)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(name)
  }
}
