// 拍照 / 录像：系统相机（UIImagePickerController），拍完交回一张图片或一段视频的临时文件，放进输入框上方的附件条。
import AVFoundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct CameraPicker: UIViewControllerRepresentable {
  /// 拍完：图片或视频文件。取消时不调用。
  let onCapture: (CameraResult) -> Void
  @Environment(\.dismiss) private var dismiss

  enum CameraResult {
    case photo(UIImage)
    case video(URL)
  }

  static var isAvailable: Bool { UIImagePickerController.isSourceTypeAvailable(.camera) }

  func makeCoordinator() -> Coordinator { Coordinator(self) }

  func makeUIViewController(context: Context) -> UIImagePickerController {
    let picker = UIImagePickerController()
    picker.sourceType = .camera
    picker.mediaTypes = [UTType.image.identifier, UTType.movie.identifier]
    picker.videoQuality = .typeHigh
    // QQ 视频大小有限制：录像最长 5 分钟。
    picker.videoMaximumDuration = 300
    picker.delegate = context.coordinator
    return picker
  }

  func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

  final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
    let parent: CameraPicker

    init(_ parent: CameraPicker) { self.parent = parent }

    func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
      if let url = info[.mediaURL] as? URL {
        // 系统给的文件在回调后会被删掉：先拷到自己的临时目录。
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("camera-\(UUID().uuidString).\(url.pathExtension.isEmpty ? "mov" : url.pathExtension)")
        if (try? FileManager.default.copyItem(at: url, to: dest)) != nil { parent.onCapture(.video(dest)) }
      } else if let image = info[.originalImage] as? UIImage {
        parent.onCapture(.photo(image))
      }
      parent.dismiss()
    }

    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
      parent.dismiss()
    }
  }
}

extension AttachmentLoader {
  /// 相机拍的：照片转成 JPEG（和相册里选的一样处理），视频截一帧做预览。
  static func load(camera result: CameraPicker.CameraResult) async -> Attachment? {
    switch result {
    case .photo(let image):
      guard let data = ChatScreen.jpeg(image) ?? image.jpegData(compressionQuality: 0.85) else { return nil }
      return Attachment(payload: .image(data), preview: thumbnail(image))
    case .video(let url):
      return Attachment(payload: .video(url), preview: await videoFrame(url))
    }
  }
}
