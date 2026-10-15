import QQBridgeProto
import SwiftUI

/// Mac 的名单页面只处理选择和呈现，请求与缓存由独立模型负责。
struct MacReactionUsersPage: View {
  let message: Qqbridge_V1_Message
  let context: MessageContext
  let selectUser: (Int64) -> Void
  @State private var model: MacReactionUsersViewModel
  @Environment(\.dismiss) private var dismiss

  init(message: Qqbridge_V1_Message, context: MessageContext, selected: String, selectUser: @escaping (Int64) -> Void) {
    self.message = message
    self.context = context
    self.selectUser = selectUser
    _model = State(initialValue: MacReactionUsersViewModel(selected: selected,
      service: MacSessionReactionUsersService(session: context.session, chatID: context.chatId, sequence: message.seq)))
  }

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: 6) {
            ForEach(message.reactions, id: \.emojiID) { reaction in
              Button { model.select(reaction.emojiID) } label: {
                HStack(spacing: 3) {
                  QQFace.view(reaction.emojiID, size: 20)
                  Text("\(reaction.count)").monospacedDigit()
                }
                .font(.subheadline)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(model.selected == reaction.emojiID ? AnyShapeStyle(Color.accentColor.opacity(0.25)) : AnyShapeStyle(.quaternary), in: Capsule())
              }
              .buttonStyle(.plain)
              .accessibilityLabel("\(ReactionLabel.name(reaction.emojiID))，\(reaction.count) 人回应")
              .accessibilityValue(model.selected == reaction.emojiID ? "已选择" : "未选择")
              .help(ReactionLabel.name(reaction.emojiID))
            }
          }
          .padding(.horizontal, 16)
          .padding(.vertical, 8)
        }
        List(model.users, id: \.userID) { user in
          Button { selectUser(user.userID) } label: {
            HStack(spacing: 12) {
              AvatarView(sha256: context.avatars.sha256[user.userID], title: name(user), seed: user.userID, size: 36)
              Text(name(user)).foregroundStyle(.primary)
              Spacer()
              if user.userID == context.selfUin { Text("我").font(.caption).foregroundStyle(.secondary) }
            }
          }
          .onAppear { context.avatars.want(user.userID, session: context.session) }
        }
        .listStyle(.plain)
        .modifier(MacGroupListStatus(empty: model.users.isEmpty, isLoading: model.isLoading,
          hasLoaded: model.hasLoaded, error: model.error, emptyText: "暂无回应者", icon: "person.2",
          reload: { model.load() }))
      }
      .navigationTitle(ReactionLabel.name(model.selected))
      .navigationBarTitleDisplayMode(.inline)
      .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
      .onAppear { model.start() }
      .onDisappear { model.cancel() }
    }
  }

  private func name(_ user: Qqbridge_V1_ReactionUser) -> String {
    if user.userID == context.selfUin { return context.name(of: user.userID) }
    if let name = context.members.displayName(user.userID) { return name }
    return user.name.isEmpty ? String(user.userID) : user.name
  }
}
