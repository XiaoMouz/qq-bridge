import Charts
import QQBridgeKit
import QQBridgeProto
import SwiftUI

struct MacChatStorageView: View {
  let session: Session
  let chatID: Int64
  let title: String
  @Environment(\.colorScheme) private var colorScheme
  @State private var model: MacStorageSummaryModel<Qqbridge_V1_GetChatStorageResponse>

  init(session: Session, chatID: Int64, title: String,
       fetch: (@MainActor () async throws -> Qqbridge_V1_GetChatStorageResponse)? = nil) {
    self.session = session; self.chatID = chatID; self.title = title
    let service = MacStorageSummaryService(session: session)
    _model = State(initialValue: MacStorageSummaryModel(fetch: fetch ?? { try await service.detail(chatID: chatID) }))
  }

  var body: some View {
    Form {
      if let detail = model.value {
        Section {
          LabeledContent("占用", value: Bytes.text(Int64(clamping: detail.summary.logicalBytes)))
          LabeledContent("只在这个会话里", value: Bytes.text(Int64(clamping: detail.summary.exclusiveBytes)))
          LabeledContent("内容数", value: "\(detail.summary.blobCount)")
        }
        let kinds = detail.kinds.filter { $0.logicalBytes > 0 }
        if !kinds.isEmpty {
          Section("按类型") {
            Chart(kinds, id: \.kind) { kind in
              BarMark(x: .value("大小", Double(kind.logicalBytes)), y: .value("类型", ChatStorageView.kindName(kind.kind)))
                .foregroundStyle(ChatStorageView.kindColor(kind.kind)).cornerRadius(4)
            }
            .chartXAxis(.hidden)
            // Catalyst 默认内嵌轴标签在深色下过暗；明确放到左侧并使用语义前景色。
            .chartYAxis {
              AxisMarks(position: .leading) {
                AxisValueLabel().foregroundStyle(Color.primary)
              }
            }
            .frame(height: CGFloat(kinds.count) * 36 + 10)
            // Catalyst 切换外观时 Charts 会保留旧轴颜色；仅重建无交互状态的统计图。
            .id(colorScheme)
            ForEach(kinds, id: \.kind) { kind in
              NavigationLink {
                StorageItemsView(session: session, source: .server, group: ChatStorageView.group(kind.kind),
                                 chatId: chatID, title: "\(title) · \(ChatStorageView.kindName(kind.kind))")
              } label: {
                LabeledContent {
                  VStack(alignment: .trailing, spacing: 0) {
                    Text(Bytes.text(Int64(clamping: kind.logicalBytes))).monospacedDigit()
                    Text(kind.purgedCount > 0 ? "\(kind.count) 份 · \(kind.purgedCount) 份原件已清理" : "\(kind.count) 份")
                      .font(.caption).foregroundStyle(.secondary)
                  }
                } label: {
                  Label { Text(ChatStorageView.kindName(kind.kind)) } icon: {
                    Circle().fill(ChatStorageView.kindColor(kind.kind)).frame(width: 10, height: 10)
                  }
                }
              }
            }
          }
        }
      }
    }
    .navigationTitle(title)
    .navigationBarTitleDisplayMode(.inline)
    .modifier(MacStorageSummaryStatus(model: model))
  }
}
