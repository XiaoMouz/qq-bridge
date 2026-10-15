import QQBridgeKit
import SwiftUI

struct MacContactGroupView: View {
  let session: Session
  @Environment(AppModel.self) private var app
  @State private var model: MacContactGroupViewModel
  @State private var members = GroupMembers()
  @State private var avatars = AvatarBook()

  init(session: Session, groupID: Int64) {
    self.session = session
    _model = State(initialValue: MacContactGroupViewModel(service: MacSessionContactGroupService(session: session, groupID: groupID)))
  }

  var body: some View {
    Group {
      if let dialog = model.dialog {
        GroupInfoView(session: session, dialog: dialog, members: members, avatars: avatars,
                      onOpenChat: { app.pendingChat = dialog.chatID })
      } else if let error = model.error {
        ContentUnavailableView {
          Label("无法打开群资料", systemImage: "exclamationmark.triangle")
        } description: {
          Text(error)
        } actions: {
          Button("重试") { model.load() }
        }
        .navigationTitle("群资料")
      } else {
        ProgressView("正在加载群资料…")
          .navigationTitle("群资料")
      }
    }
    .onAppear { model.start() }
    .onDisappear { model.cancel() }
  }
}
