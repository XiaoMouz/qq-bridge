// Mac 输入框里的 @ 补全：群聊里打「@」加几个字，输入框上方出一个小列表跟着筛选，
// ↑↓ 选、回车 / Tab 插入、Esc 关掉，光标一直在输入框里。
// 2026-10-17 按 macOS 习惯改：以前一打「@」就弹窗口中间的模态表单，光标离开输入框、要另外搜索。iOS 仍是弹出选人。
import QQBridgeKit
import QQBridgeProto
import SwiftUI

@MainActor
@Observable
final class MentionCompletion {
  struct Candidate: Identifiable, Equatable {
    /// 0 是「全体成员」。
    let id: Int64
    let name: String
    let detail: String?
  }

  /// 「@」后面已经打的字；nil 表示没在补全。
  private(set) var query: String?
  private(set) var candidates: [Candidate] = []
  private(set) var selected = 0
  /// 用户按了 Esc：这一个「@」不再弹，直到再打一个新的「@」。
  private var dismissedAt: Int?

  var isActive: Bool { query != nil && !candidates.isEmpty }

  /// 输入框文字变了就调用（只看末尾：光标在中间改字时不补全，Mac 上绝大多数时候光标在末尾）。
  func update(text: String, members: GroupMembers, canMentionAll: Bool) {
    guard let match = text.firstMatch(of: /(?:^|\s)@([^\s@]{0,20})$/) else { reset(); return }
    let atIndex = text.count - match.output.1.count - 1
    if dismissedAt == atIndex { query = nil; candidates = []; return }
    dismissedAt = nil
    let q = String(match.output.1)
    var list: [Candidate] = []
    if canMentionAll, q.isEmpty || "全体成员".contains(q) || "all".hasPrefix(q.lowercased()) {
      list.append(Candidate(id: 0, name: "全体成员", detail: nil))
    }
    let found = members.list.lazy.filter { q.isEmpty || members.matches($0, q) }.prefix(8)
    list += found.map { m in
      Candidate(id: m.userID, name: !m.card.isEmpty ? m.card : (!m.nickname.isEmpty ? m.nickname : String(m.userID)),
                detail: members.subtitle(m) ?? String(m.userID))
    }
    if q != query || list != candidates { selected = 0 }
    query = q
    candidates = list
  }

  func move(_ offset: Int) {
    guard !candidates.isEmpty else { return }
    selected = (selected + offset + candidates.count) % candidates.count
  }

  func dismiss(text: String) {
    if let query { dismissedAt = text.count - query.count - 1 }
    query = nil
    candidates = []
  }

  /// 把末尾的「@字」换成选中的人。
  func confirm(_ candidate: Candidate? = nil, into composer: Composer) {
    guard let query, let pick = candidate ?? candidates[safe: selected] else { return }
    composer.text.removeLast(query.count)
    if pick.id == 0 { composer.mentionAll() } else { composer.insertMention(userId: pick.id, name: pick.name, replacingTrailingAt: true) }
    reset()
  }

  private func reset() {
    query = nil
    candidates = []
    selected = 0
  }
}

private extension Array {
  subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

/// 输入框上方的候选列表。
struct MentionSuggestionList: View {
  let completion: MentionCompletion
  let avatars: AvatarBook
  let session: Session
  let pick: (MentionCompletion.Candidate) -> Void

  /// 列表高度按行数算死（最多 6 行，多了滚动）：放在输入框上方要知道自己多高才能往上挪，
  /// 2026-10-17 实机：交给布局时拿到的是输入框那一行的高度，列表往下画、盖住输入框又被窗口底边截掉。
  static func height(rows: Int) -> CGFloat { CGFloat(min(rows, 6)) * 32 + 8 }

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView {
        VStack(spacing: 0) {
          ForEach(Array(completion.candidates.enumerated()), id: \.element.id) { index, candidate in
            row(candidate, selected: index == completion.selected).id(candidate.id)
          }
        }
        .padding(4)
      }
      .scrollBounceBehavior(.basedOnSize)
      .onChange(of: completion.selected) { _, index in
        if let id = completion.candidates[safe: index]?.id { proxy.scrollTo(id) }
      }
    }
    .frame(width: 280, height: Self.height(rows: completion.candidates.count))
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.quaternary))
    .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
  }

  private func row(_ candidate: MentionCompletion.Candidate, selected: Bool) -> some View {
    Button { pick(candidate) } label: {
      HStack(spacing: 8) {
        if candidate.id == 0 {
          Image(systemName: "person.3.fill").frame(width: 24, height: 24)
        } else {
          AvatarView(sha256: avatars.sha256[candidate.id], title: candidate.name, seed: candidate.id, size: 24)
            .onAppear { avatars.want(candidate.id, session: session) }
        }
        Text(candidate.name).lineLimit(1)
        if let detail = candidate.detail {
          Text(detail).font(.caption).foregroundStyle(selected ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.secondary)).lineLimit(1)
        }
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 8)
      .frame(height: 32)
      .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
      .background(selected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }
}
