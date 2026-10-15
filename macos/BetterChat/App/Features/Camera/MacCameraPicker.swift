import AVFoundation
import SwiftUI
import UIKit

/// Mac 无法使用 iOS 相机选择器，但保持共用附件处理接口。
struct CameraPicker: UIViewControllerRepresentable {
  let onCapture: (CameraResult) -> Void
  @Environment(\.dismiss) private var dismiss
  enum CameraResult {
    case photo(UIImage)
    case video(URL)
  }
  static var isAvailable: Bool { AVCaptureDevice.default(for: .video) != nil }
  func makeUIViewController(context: Context) -> MacCameraController {
    let controller = MacCameraController()
    controller.onCapture = { result in onCapture(result); dismiss() }
    controller.onCancel = { dismiss() }
    return controller
  }
  func updateUIViewController(_ controller: MacCameraController, context: Context) {}
}

@MainActor
final class MacCameraController: UIViewController {
  var onCapture: ((CameraPicker.CameraResult) -> Void)?
  var onCancel: (() -> Void)?
  private let engine = MacCameraEngine()
  private var preview: AVCaptureVideoPreviewLayer?
  private let record = UIButton(type: .system)
  private let photo = UIButton(type: .system)
  private let status = UILabel()
  private enum CaptureState { case unavailable, ready, photo, preparingVideo, recording, finishingVideo }
  private var captureState = CaptureState.unavailable
  private var closing = false
  private var permissionTask: Task<Void, Never>?
  private var recordingTask: Task<Void, Never>?

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .black
    preferredContentSize = CGSize(width: 800, height: 600)
    let layer = AVCaptureVideoPreviewLayer(session: engine.session)
    layer.videoGravity = .resizeAspect
    view.layer.addSublayer(layer); preview = layer
    let cancel = UIButton(type: .system)
    cancel.setTitle("取消", for: .normal)
    cancel.addAction(UIAction { [weak self] _ in self?.closeCamera(); self?.onCancel?() }, for: .touchUpInside)
    photo.configuration = .filled(); photo.setTitle("拍照", for: .normal)
    photo.isEnabled = false
    photo.addAction(UIAction { [weak self] _ in
      guard let self, self.captureState == .ready, !self.closing else { return }
      self.setCaptureState(.photo)
      self.engine.takePhoto()
    }, for: .touchUpInside)
    record.configuration = .filled(); record.setTitle("录制视频", for: .normal)
    record.isEnabled = false
    record.addAction(UIAction { [weak self] _ in self?.toggleRecording() }, for: .touchUpInside)
    status.textColor = .white; status.numberOfLines = 0; status.textAlignment = .center
    status.text = "正在打开摄像头…"
    let buttons = UIStackView(arrangedSubviews: [cancel, photo, record])
    buttons.spacing = 24; buttons.distribution = .fillEqually
    let controls = UIStackView(arrangedSubviews: [status, buttons])
    controls.axis = .vertical; controls.spacing = 12
    controls.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(controls)
    NSLayoutConstraint.activate([
      controls.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 24),
      controls.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -24),
      controls.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -20),
    ])
    engine.onPhoto = { [weak self] data in
      Task { @MainActor in
        guard let self, !self.closing else { return }
        guard let image = UIImage(data: data) else {
          self.recoverCapture("照片处理失败，请重试。")
          return
        }
        self.closeCamera()
        self.onCapture?(.photo(image))
      }
    }
    engine.onVideo = { [weak self] url in Task { @MainActor in
      guard let self, !self.closing else { try? FileManager.default.removeItem(at: url); return }
      self.closeCamera()
      self.onCapture?(.video(url))
    } }
    engine.onRecordingStarted = { [weak self] in Task { @MainActor in
      guard let self, !self.closing, self.captureState == .preparingVideo else { return }
      self.setCaptureState(.recording)
      self.status.text = "正在录制 · 最长 5 分钟"
    } }
    engine.onError = { [weak self] message in Task { @MainActor in self?.recoverCapture(message) } }
    permissionTask = Task { [weak self] in
      guard await AVCaptureDevice.requestAccess(for: .video) else {
        self?.status.text = "请在系统设置 → 隐私与安全性 → 摄像头中允许 BetterChat 使用摄像头。"
        return
      }
      guard !Task.isCancelled, let self else { return }
      self.engine.start { [weak self] error in Task { @MainActor in
        guard let self, !self.closing else { return }
        self.status.text = error
        self.setCaptureState(error == nil ? .ready : .unavailable)
      } }
    }
  }
  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    preview?.frame = view.bounds.inset(by: UIEdgeInsets(top: 0, left: 0, bottom: 100, right: 0))
  }
  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    closeCamera()
  }
  private func closeCamera() {
    guard !closing else { return }
    closing = true
    permissionTask?.cancel()
    recordingTask?.cancel()
    engine.stop()
  }
  private func setCaptureState(_ state: CaptureState) {
    captureState = state
    photo.isEnabled = state == .ready
    record.isEnabled = state == .ready || state == .recording
    record.setTitle(state == .recording ? "停止并使用" : "录制视频", for: .normal)
  }
  private func recoverCapture(_ message: String) {
    guard !closing else { return }
    status.text = message
    setCaptureState(.ready)
  }
  private func toggleRecording() {
    guard !closing else { return }
    if captureState == .recording {
      setCaptureState(.finishingVideo)
      status.text = "正在保存视频…"
      engine.finishVideo()
      return
    }
    guard captureState == .ready else { return }
    // 授权和实际开始录制之间禁用按钮，避免多次启动或过早停止。
    setCaptureState(.preparingVideo)
    status.text = "正在准备录制…"
    recordingTask = Task { [weak self] in
      guard await AVCaptureDevice.requestAccess(for: .audio) else {
        self?.recoverCapture("录制带声音的视频需要麦克风权限。")
        return
      }
      guard !Task.isCancelled, let self, !self.closing else { return }
      self.engine.recordVideo()
    }
  }
}

/// 采集配置只在串行队列修改；回调在启动前固定，预览层独立消费采集会话。
private final class MacCameraEngine: NSObject, @unchecked Sendable, AVCapturePhotoCaptureDelegate, AVCaptureFileOutputRecordingDelegate {
  let session = AVCaptureSession()
  private let queue = DispatchQueue(label: "com.xiaomouz.betterchat.mac.camera", qos: .userInitiated)
  private let photo = AVCapturePhotoOutput()
  private let movie = AVCaptureMovieFileOutput()
  private var configured = false
  private var cancelled = false
  var onPhoto: (@Sendable (Data) -> Void)?
  var onVideo: (@Sendable (URL) -> Void)?
  var onRecordingStarted: (@Sendable () -> Void)?
  var onError: (@Sendable (String) -> Void)?

  func start(completion: @escaping @Sendable (String?) -> Void) {
    queue.async { [self] in
      do {
        session.beginConfiguration()
        session.sessionPreset = .high
        defer { session.commitConfiguration() }
        guard let camera = AVCaptureDevice.default(for: .video) else { throw CameraError.noCamera }
        let input = try AVCaptureDeviceInput(device: camera)
        guard session.canAddInput(input), session.canAddOutput(photo), session.canAddOutput(movie) else { throw CameraError.noCamera }
        session.addInput(input); session.addOutput(photo); session.addOutput(movie)
        movie.maxRecordedDuration = CMTime(seconds: 300, preferredTimescale: 600)
        configured = true
      } catch { completion(error.localizedDescription); return }
      guard !cancelled else { return }
      session.startRunning()
      completion(nil)
    }
  }
  func stop() {
    queue.async { [self] in
      cancelled = true
      if movie.isRecording { movie.stopRecording() }
      if session.isRunning { session.stopRunning() }
    }
  }
  func takePhoto() {
    queue.async { [self] in
      guard configured, !cancelled else { return }
      photo.capturePhoto(with: AVCapturePhotoSettings(), delegate: self)
    }
  }
  func recordVideo() {
    queue.async { [self] in
      guard configured, !cancelled, !movie.isRecording else { return }
      do {
        if !session.inputs.contains(where: { ($0 as? AVCaptureDeviceInput)?.device.hasMediaType(.audio) == true }) {
          guard let device = AVCaptureDevice.default(for: .audio) else { throw CameraError.noMicrophone }
          let input = try AVCaptureDeviceInput(device: device)
          session.beginConfiguration()
          defer { session.commitConfiguration() }
          guard session.canAddInput(input) else { throw CameraError.noMicrophone }
          session.addInput(input)
        }
        movie.startRecording(to: FileManager.default.temporaryDirectory.appending(path: "camera-\(UUID().uuidString).mov"), recordingDelegate: self)
      } catch { onError?(error.localizedDescription) }
    }
  }
  func finishVideo() { queue.async { [self] in if movie.isRecording { movie.stopRecording() } } }
  func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: (any Error)?) {
    let message = error?.localizedDescription
    let data = error == nil ? photo.fileDataRepresentation() : nil
    queue.async { [self] in
      guard !cancelled else { return }
      if let data { onPhoto?(data) }
      else { onError?(message ?? "照片处理失败，请重试。") }
    }
  }
  func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo url: URL, from connections: [AVCaptureConnection]) {
    queue.async { [self] in if !cancelled { onRecordingStarted?() } }
  }
  func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo url: URL, from connections: [AVCaptureConnection], error: (any Error)?) {
    let succeeded = error == nil || ((error as NSError?)?.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool == true)
    let message = error?.localizedDescription
    queue.async { [self] in
      if !cancelled, succeeded { onVideo?(url) }
      else { try? FileManager.default.removeItem(at: url); if !cancelled { onError?(message ?? "录制失败") } }
    }
  }
  enum CameraError: LocalizedError {
    case noCamera, noMicrophone
    var errorDescription: String? {
      switch self {
      case .noCamera: "没有可用的摄像头，请连接摄像头后重试。"
      case .noMicrophone: "没有可用的麦克风，请连接麦克风后重试。"
      }
    }
  }
}

extension AttachmentLoader {
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
