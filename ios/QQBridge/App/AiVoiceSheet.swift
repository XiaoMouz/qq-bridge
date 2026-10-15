import QQBridgeKit
import SwiftUI

struct AiVoiceSheet: View {
  @State private var model: AiVoiceViewModel
  @State private var preview = AiVoicePreview()
  let onSent: (String) -> Void
  private let calls: CallManager?
  @Environment(\.dismiss) private var dismiss

  init(session: Session, chatId: Int64, initialText: String, calls: CallManager? = nil, onSent: @escaping (String) -> Void) {
    _model = State(initialValue: AiVoiceViewModel(service: SessionAiVoiceService(session: session, chatId: chatId), text: initialText))
    self.onSent = onSent; self.calls = calls
  }

  init(model: AiVoiceViewModel, onSent: @escaping (String) -> Void) {
    _model = State(initialValue: model); self.onSent = onSent; calls = nil
  }

  private var audioBusy: Bool {
    calls?.joining == true || calls?.joined == true || calls?.isDialing == true || calls?.isRinging == true || calls?.answeredHere == true
  }

  var body: some View {
    NavigationStack {
      Form {
        Section("要读的话") {
          #if targetEnvironment(macCatalyst)
          TextEditor(text: $model.text)
            .frame(minHeight: 70, maxHeight: 130).scrollContentBackground(.hidden)
            .accessibilityLabel("要读的话").disabled(model.isSending)
            .overlay(alignment: .topLeading) {
              if model.text.isEmpty { Text("输入文字").foregroundStyle(.tertiary).padding(.top, 8).padding(.leading, 5).allowsHitTesting(false) }
            }
          #else
          TextField("输入文字", text: $model.text, axis: .vertical).lineLimit(2...6)
            .disabled(model.isSending)
          #endif
        }
        if let error = model.loadError {
          Section {
            Text("加载角色失败：\(error)").foregroundStyle(.secondary)
            Button("重试加载角色") { model.load() }.disabled(model.isLoading)
          }
        }
        if model.categories.count > 1 {
          Picker("分类", selection: Binding(get: { model.category }, set: { index in preview.stop(); model.selectCategory(index) })) {
            ForEach(model.categories.indices, id: \.self) { i in Text(model.categories[i].name).tag(i) }
          }
          #if targetEnvironment(macCatalyst)
          .pickerStyle(.menu)
          #else
          .pickerStyle(.segmented).listRowBackground(Color.clear).listRowInsets(EdgeInsets())
          #endif
          .disabled(model.isSending)
        }
        Section("角色") {
          ForEach(model.voices, id: \.id) { voice in
            HStack {
              Button { model.selectVoice(voice.id) } label: {
                HStack {
                  Text(voice.name).foregroundStyle(.primary)
                  Spacer()
                  if model.voiceId == voice.id { Image(systemName: "checkmark").foregroundStyle(.tint) }
                }.contentShape(Rectangle())
              }
              .buttonStyle(.plain).disabled(model.isSending)
              .accessibilityAddTraits(model.voiceId == voice.id ? .isSelected : [])
              if !voice.previewURL.isEmpty {
                Button { if !audioBusy { preview.toggle(voice) } } label: {
                  Image(systemName: preview.previewing == voice.id ? "stop.circle" : "play.circle").font(.title3)
                }
                .buttonStyle(.borderless).disabled(model.isSending || audioBusy)
                .accessibilityLabel(preview.previewing == voice.id ? "停止试听\(voice.name)" : "试听\(voice.name)")
                .help(preview.previewing == voice.id ? "停止试听" : "试听\(voice.name)")
              }
            }
          }
          if model.hasLoaded, model.voices.isEmpty {
            Text(model.categories.isEmpty ? "这个群用不了 AI 语音" : "这个分类暂无可用角色").foregroundStyle(.secondary)
            Button("重新加载角色") { model.load() }.disabled(model.isLoading || model.isSending)
          }
        }
        if audioBusy { Section { Text("通话期间暂停试听").foregroundStyle(.secondary) } }
        if let error = preview.error { Section { Text(error).foregroundStyle(.secondary) } }
      }
      .overlay { if model.isLoading, !model.hasLoaded { ProgressView("正在加载角色…").padding().glassEffect() } }
      .navigationTitle("AI 语音")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("取消") { preview.stop(); model.cancel(); dismiss() }.disabled(model.isSending) }
        ToolbarItem(placement: .confirmationAction) {
          if model.isSending {
            // Catalyst 会把文字按钮桥接为原生工具栏项，按钮内部叠加 spinner 不会更新其标题。
            // 忙碌时直接替换成系统进度组件，既显示状态，也移除重复提交的快捷键。
            ProgressView().controlSize(.regular).tint(.primary).frame(width: 40)
              .accessibilityLabel("正在发送")
          } else {
            Button("发送") {
              preview.stop()
              model.send { text in onSent(text); dismiss() }
            }
            .disabled(!model.canSend || model.isLoading)
            .keyboardShortcut(.return, modifiers: [.command])
          }
        }
      }
      .interactiveDismissDisabled(model.isSending)
      .alert("发送失败", isPresented: Binding(get: { model.sendError != nil }, set: { if !$0 { model.sendError = nil } })) {
        Button("好") { model.sendError = nil }
      } message: { Text(model.sendError ?? "") }
      .onAppear { model.resume { text in onSent(text); dismiss() }; model.start() }
      .onChange(of: audioBusy) { _, busy in if busy { preview.stop() } }
      .onChange(of: model.voiceId) { _, selected in if preview.previewing != selected { preview.stop() } }
      .onChange(of: model.voices.map(\.id)) { _, ids in
        if let playing = preview.previewing, !ids.contains(playing) { preview.stop() }
      }
      .onDisappear { preview.stop(); model.cancel() }
    }
  }
}
