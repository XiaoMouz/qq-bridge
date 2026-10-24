import SwiftUI

/// 文件状态占用原图标的位置，避免失败/排队图标叠在两行文件名上；缩略图仍用遮罩提示状态。
struct MacAttachmentTile: View {
  let attachment: Attachment
  let index: Int
  let remove: () -> Void

  var body: some View {
    ZStack {
      if let preview = attachment.preview {
        Image(uiImage: preview).resizable().aspectRatio(contentMode: .fill)
        if case .video = attachment.payload, attachment.state == .ready {
          Image(systemName: "play.circle.fill").font(.title2).foregroundStyle(.white).shadow(radius: 3)
        }
        if attachment.state != .ready {
          Color.black.opacity(0.6)
          statusIcon
        }
      } else {
        VStack(spacing: 4) {
          statusIcon.frame(height: 24)
          Text(name).font(.caption2).lineLimit(2).truncationMode(.middle).multilineTextAlignment(.center)
        }
        .padding(6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.quaternary)
      }
    }
    .frame(width: 72, height: 72)
    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    .help("\(name)\n\(status)")
    .overlay(alignment: .topTrailing) {
      if !isUploading {
        Button(action: remove) {
          Image(systemName: "xmark.circle.fill")
            .symbolRenderingMode(.palette)
            .foregroundStyle(.white, .black.opacity(0.65))
            .font(.system(size: 18))
            .frame(width: 24, height: 24)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("移除第 \(index + 1) 个附件：\(name)")
        .help(attachment.state == .queued ? "从附件栏移除，不取消已提交的发送" : "移除附件：\(name)")
        .offset(x: 5, y: -5)
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("第 \(index + 1) 个附件：\(name)")
    .accessibilityValue(status)
  }

  @ViewBuilder private var statusIcon: some View {
    switch attachment.state {
    case .ready: Image(systemName: attachment.isFile ? "doc.fill" : "photo").font(.title2).foregroundStyle(.tint)
    case .uploading(let progress):
      // 和 iOS、文件气泡一样只用进度环，不另写百分比（百分比在悬停提示和旁白里）。
      TransferRing(progress: min(1, max(0, progress)))
        .tint(attachment.preview == nil ? Color.accentColor : .white)
        .frame(width: 26, height: 26)
    case .failed: Image(systemName: "exclamationmark.triangle.fill").font(.title2)
        .foregroundStyle(attachment.preview == nil ? Color.red : .white)
    case .queued: Image(systemName: "clock.fill").font(.title2)
        .foregroundStyle(attachment.preview == nil ? Color.secondary : .white)
    }
  }
  private var isUploading: Bool {
    if case .uploading = attachment.state { true } else { false }
  }
  private var name: String {
    switch attachment.payload {
    case .image: "图片"
    case .video: "视频"
    case .file(_, let name): name
    case .stored(_, let sticker): sticker ? "表情" : "图片"
    }
  }
  private var status: String {
    switch attachment.state {
    case .ready: "准备发送"
    case .uploading(let progress): "正在上传 \(Int(min(1, max(0, progress)) * 100))%"
    case .failed(let reason): "发送失败：\(reason)；点击发送按钮重试"
    case .queued: "已提交，等待发送确认"
    }
  }
}
