// QQ 掉线时在 App 里扫码登录：服务端经 NapCat WebUI 拿到二维码内容，这里画成二维码。
// 手机自己扫不了自己的屏幕：可以截图后在手机 QQ 的"扫一扫 → 相册"里选这张图。
import CoreImage.CIFilterBuiltins
import QQBridgeKit
import QQBridgeProto
import SwiftUI

/// Mac 上换成打开独立的扫码窗口（由 Mac App 启动时设上，见 MacQqLoginWindow）；iOS 为 nil，照常弹表单。
@MainActor
enum PlatformQqLogin {
  static var open: (() -> Void)?
}

struct QqLoginSheet: View {
  let session: Session
  /// 在独立窗口里时：关窗口（登录成功、点完成）。为 nil 时关表单。
  var onDone: (() -> Void)? = nil
  @Environment(AppModel.self) private var model
  @Environment(\.dismiss) private var dismiss
  @State private var state: Qqbridge_V1_GetQqLoginResponse?
  @State private var refreshing = false

  var body: some View {
    #if targetEnvironment(macCatalyst)
    // Mac：独立窗口，标题在窗口标题栏，用窗口的关闭按钮。
    content.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
      .task { await poll() }
    #else
    NavigationStack {
      content
      .padding()
      .navigationTitle("QQ 扫码登录")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) { Button("完成") { finish() } }
      }
      .task { await poll() }
    }
    #endif
  }

  private func finish() {
    if let onDone { onDone() } else { dismiss() }
  }

  private var content: some View {
      VStack(spacing: 20) {
        if let state, state.loggedIn {
          ContentUnavailableView("QQ 已登录", systemImage: "checkmark.circle.fill")
        } else if let state, state.unavailable {
          ContentUnavailableView("拿不到二维码", systemImage: "exclamationmark.triangle", description: Text(state.error.isEmpty ? "服务器没配 NapCat WebUI" : state.error))
        } else if let url = state?.qrcodeURL, !url.isEmpty, let image = Self.qr(url) {
          Image(uiImage: image)
            .interpolation(.none)
            .resizable()
            .scaledToFit()
            .frame(maxWidth: 260)
            .padding()
            .background(.white, in: RoundedRectangle(cornerRadius: 16))
          Text("用主号的手机 QQ 扫码，二维码约 2 分钟过期。\n在本机上看的话，可以截图后在 QQ「扫一扫 → 相册」里选这张图。")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
          if !(state?.phase ?? "").isEmpty {
            Text("状态：\(state!.phase)").font(.caption).foregroundStyle(.tertiary)
          }
        } else {
          ProgressView()
        }
        Button {
          Task { await refreshQr() }
        } label: {
          Label("换一张二维码", systemImage: "arrow.clockwise")
        }
        #if targetEnvironment(macCatalyst)
        .buttonStyle(.bordered)
        #else
        .buttonStyle(.glass)
        #endif
        .disabled(refreshing || state?.loggedIn == true)
      }
  }

  /// 每 3 秒问一次，登录成功就关掉。
  private func poll() async {
    while !Task.isCancelled {
      state = try? await session.api.admin.getQqLogin(request: .init(), headers: session.api.headers).get()
      if state?.loggedIn == true {
        // 先关，再刷新状态：刷新要问 QQ，2026-10-18 实测要十几秒，等它关窗口太慢。
        try? await Task.sleep(for: .seconds(1))
        finish()
        let model = model
        Task { await model.refreshQqStatus() }
        return
      }
      try? await Task.sleep(for: .seconds(3))
    }
  }

  private func refreshQr() async {
    refreshing = true
    defer { refreshing = false }
    _ = try? await session.api.admin.refreshQqLoginQrcode(request: .init(), headers: session.api.headers).get()
    state = try? await session.api.admin.getQqLogin(request: .init(), headers: session.api.headers).get()
  }

  static func qr(_ text: String) -> UIImage? {
    let filter = CIFilter.qrCodeGenerator()
    filter.message = Data(text.utf8)
    filter.correctionLevel = "M"
    guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
      let cg = CIContext().createCGImage(output, from: output.extent)
    else { return nil }
    return UIImage(cgImage: cg)
  }
}
