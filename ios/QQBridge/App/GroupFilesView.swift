// 群文件：浏览、打开（QuickLook）、下载到手机 / 删掉手机上的、存到「文件」、转发。
// 有权限时（群主、管理员能管所有文件，成员能管自己上传的）还能删除、移动、重命名；群主、管理员能新建、删除文件夹。
// 「选择」进入多选：下载、转发、移动、删除、删本机文件。QQ 的群文件只有一层文件夹。
// 列表当场向 QQ 拉（QQ 掉线时看不了）；文件先由服务端从 QQ 下载。Mac 保存到用户下载目录，iOS 保持本机缓存。
import QQBridgeKit
import QQBridgeProto
import QuickLook
import SwiftUI
import UIKit

struct GroupFilesView: View {
  let session: Session
  let groupId: Int64
  /// 群聊的会话 id：下到手机的文件记在这个会话名下（清理会话缓存时一起清）。
  var chatId: Int64? = nil
  /// 自己在群里的身份（owner / admin / member）。
  var selfRole = ""
  var folderId = ""
  var title = "群文件"
  @Environment(AppModel.self) private var model
  #if targetEnvironment(macCatalyst)
  @State private var fileList: MacGroupFilesViewModel
  private var folders: [Qqbridge_V1_GroupFolder] { fileList.folders }
  private var files: [Qqbridge_V1_GroupFile] {
    get { fileList.files }
    nonmutating set { fileList.files = newValue }
  }
  private var selection: Set<String> {
    get { fileList.selection }
    nonmutating set { fileList.selection = newValue }
  }
  private var selectionBinding: Binding<Set<String>> {
    Binding(get: { selection }, set: { selection = $0 })
  }
  private var filePresentation: Binding<MacGroupFilePresentation?> {
    Binding(get: { showForward ? .forward : (showMove ? .move : nil) }, set: {
      showForward = $0 == .forward
      showMove = $0 == .move
    })
  }

  init(session: Session, groupId: Int64, chatId: Int64? = nil, selfRole: String = "", folderId: String = "", title: String = "群文件", fileService: (any MacGroupFilesService)? = nil) {
    self.session = session
    self.groupId = groupId
    self.chatId = chatId
    self.selfRole = selfRole
    self.folderId = folderId
    self.title = title
    _fileList = State(initialValue: MacGroupFilesViewModel(service: fileService ?? MacSessionGroupFilesService(session: session, groupID: groupId, folderID: folderId)))
  }
  #else
  @State private var folders: [Qqbridge_V1_GroupFolder] = []
  @State private var files: [Qqbridge_V1_GroupFile] = []
  @State private var selection: Set<String> = []
  private var selectionBinding: Binding<Set<String>> { $selection }
  #endif
  /// 手机上已经有的（sha256）。
  @State private var local: Set<String> = []
  @State private var state = LoadState.loading
  /// 正在下载的文件 id。
  @State private var busy: Set<String> = []
  /// 批量操作的进度（显示在底部）。
  @State private var progress: String?
  @State private var preview: URL?
  @State private var error: String?
  @State private var editMode: EditMode = .inactive
  @State private var forwarding: [Qqbridge_V1_GroupFile] = []
  @State private var showForward = false
  @State private var moving: [Qqbridge_V1_GroupFile] = []
  @State private var showMove = false
  @State private var renaming: Qqbridge_V1_GroupFile?
  @State private var newName = ""
  @State private var deleting: [Qqbridge_V1_GroupFile] = []
  @State private var showDelete = false
  @State private var deletingFolder: Qqbridge_V1_GroupFolder?
  @State private var creatingFolder = false
  @State private var folderName = ""
  @State private var sharing: [URL] = []
  @State private var showShare = false

  private var editing: Bool { editMode == .active }
  private var isAdmin: Bool { selfRole == "owner" || selfRole == "admin" }
  private var selected: [Qqbridge_V1_GroupFile] { files.filter { selection.contains($0.id) } }

  private func canManage(_ f: Qqbridge_V1_GroupFile) -> Bool {
    isAdmin || (f.uploaderID != 0 && f.uploaderID == model.qqAccount?.uin)
  }

  private func isLocal(_ f: Qqbridge_V1_GroupFile) -> Bool { !f.sha256.isEmpty && local.contains(f.sha256) }

  private var removeLocalTitle: String {
    #if targetEnvironment(macCatalyst)
    "将下载文件移到废纸篓"
    #else
    "删除本机文件"
    #endif
  }
  var body: some View {
    List(selection: selectionBinding) {
      if !editing {
        ForEach(folders, id: \.id) { f in folderRow(f) }
      }
      ForEach(files, id: \.id) { f in
        Group {
          if editing {
            fileRow(f)
          } else {
            Button { Task { await open(f) } } label: { fileRow(f) }
              .tint(.primary)
              .disabled(busy.contains(f.id))
              .contextMenu { menu(f) }
              .swipeActions(edge: .trailing) {
                if canManage(f) {
                  Button("删除", role: .destructive) { confirmDelete([f]) }
                }
                if isLocal(f) {
                  Button(removeLocalTitle) { Task { await removeLocal([f]) } }.tint(.orange)
                }
              }
          }
        }
      }
    }
    .environment(\.editMode, $editMode)
    #if targetEnvironment(macCatalyst)
    .modifier(MacGroupListStatus(empty: folders.isEmpty && files.isEmpty, isLoading: fileList.isLoading,
                                 hasLoaded: fileList.hasLoaded, error: fileList.error,
                                 emptyText: "没有群文件", icon: "doc", reload: { Task { await load() } }))
    #else
    .overlay { state.overlay(empty: folders.isEmpty && files.isEmpty, emptyText: "没有群文件", icon: "doc") }
    #endif
    // 进度浮在底部，不改变文件列表的高度。
    .overlay(alignment: .bottom) {
      if let progress {
        HStack(spacing: 8) {
          ProgressView()
          Text(progress).font(.footnote)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .padding(.bottom, 8)
      }
    }
    .navigationTitle(editing ? (selection.isEmpty ? "选择文件" : "已选 \(selection.count) 个") : title)
    .navigationBarTitleDisplayMode(.inline)
    .toolbar { toolbar }
    .quickLookPreview($preview)
    .alert("出错了", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } }), presenting: error) { _ in
      Button("好") { error = nil }
    } message: { Text($0) }
    .alert("重命名", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
      TextField("文件名", text: $newName)
      Button("取消", role: .cancel) { renaming = nil }
      Button("好") {
        if let f = renaming { Task { await rename(f, to: newName) } }
        renaming = nil
      }
    }
    .alert("新建文件夹", isPresented: $creatingFolder) {
      TextField("文件夹名", text: $folderName)
      Button("取消", role: .cancel) {}
      Button("新建") { Task { await createFolder(folderName) } }
    }
    // 用 alert 确认：从长按菜单里弹 confirmationDialog 时常常弹不出来。
    .alert(deleting.count == 1 ? "从群文件里删除「\(deleting.first?.name ?? "")」？" : "从群文件里删除这 \(deleting.count) 个文件？", isPresented: $showDelete) {
      Button("取消", role: .cancel) {}
      Button("删除", role: .destructive) { Task { await delete(deleting) } }
    } message: {
      Text("群里所有人都将看不到这些文件。")
    }
    .alert("删除文件夹「\(deletingFolder?.name ?? "")」？", isPresented: Binding(get: { deletingFolder != nil }, set: { if !$0 { deletingFolder = nil } })) {
      Button("取消", role: .cancel) { deletingFolder = nil }
      Button("删除", role: .destructive) {
        if let f = deletingFolder { Task { await deleteFolder(f) } }
        deletingFolder = nil
      }
    } message: {
      Text("文件夹里的文件会一起删除。")
    }
    #if targetEnvironment(macCatalyst)
    .background { desktopPresentation }
    #else
    .sheet(isPresented: $showForward) {
      ChatPicker(session: session) { chat in
        showForward = false
        let list = forwarding
        Task { await forward(list, to: chat) }
      }
    }
    .sheet(isPresented: $showMove) {
      GroupFolderPicker(session: session, groupId: groupId, current: folderId, onCancel: { showMove = false }) { target in
        showMove = false
        let list = moving
        Task { await move(list, to: target) }
      }
    }
    #endif
    .sheet(isPresented: $showShare) { ShareSheet(items: sharing) }
    #if targetEnvironment(macCatalyst)
    .refreshable { await load() }
    .onDisappear { fileList.cancel() }
    #else
    .platformRefreshable { await load() }
    #endif
    .task { await load() }
  }

  #if targetEnvironment(macCatalyst)
  private var desktopPresentation: some View {
    MacFormPresenter(item: filePresentation) { presentation in
      Group {
        switch presentation {
        case .forward:
          ChatPicker(session: session, onCancel: { showForward = false }) { chat in
            showForward = false
            let list = forwarding
            Task { await forward(list, to: chat) }
          }
        case .move:
          GroupFolderPicker(session: session, groupId: groupId, current: folderId, onCancel: { showMove = false }) { target in
            showMove = false
            let list = moving
            Task { await move(list, to: target) }
          }
        }
      }
    }
  }
  #endif

  // MARK: - 行

  private func folderRow(_ f: Qqbridge_V1_GroupFolder) -> some View {
    NavigationLink {
      GroupFilesView(session: session, groupId: groupId, chatId: chatId, selfRole: selfRole, folderId: f.id, title: f.name)
    } label: {
      Label {
        VStack(alignment: .leading, spacing: 2) {
          Text(f.name)
          Text("\(f.fileCount) 个文件").font(.caption).foregroundStyle(.secondary)
        }
      } icon: { Image(systemName: "folder.fill").foregroundStyle(.tint) }
    }
    .contextMenu {
      if isAdmin {
        Button("删除文件夹", systemImage: "trash", role: .destructive) { deletingFolder = f }
      }
    }
    .swipeActions(edge: .trailing) {
      if isAdmin {
        Button("删除", role: .destructive) { deletingFolder = f }
      }
    }
  }

  private func fileRow(_ f: Qqbridge_V1_GroupFile) -> some View {
    HStack(spacing: 12) {
      Image(systemName: Self.icon(f.name)).font(.title2).foregroundStyle(.tint).frame(width: 32)
      VStack(alignment: .leading, spacing: 2) {
        Text(f.name).lineLimit(2).foregroundStyle(.primary)
        Text(detail(f)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
      }
      Spacer()
      if busy.contains(f.id) {
        ProgressView()
      } else if isLocal(f) {
        #if targetEnvironment(macCatalyst)
        Image(systemName: "folder").foregroundStyle(.secondary).accessibilityLabel("已保存到下载目录")
        #else
        Image(systemName: "iphone").foregroundStyle(.secondary).accessibilityLabel("已下载到本机")
        #endif
      } else if !f.sha256.isEmpty {
        Image(systemName: "checkmark.icloud").foregroundStyle(.secondary).accessibilityLabel("服务器上已存")
      }
    }
    .contentShape(Rectangle())
  }

  @ViewBuilder private func menu(_ f: Qqbridge_V1_GroupFile) -> some View {
    Button("打开", systemImage: "doc.text.magnifyingglass") { Task { await open(f) } }
    if !isLocal(f) {
      Button("下载到本机", systemImage: "arrow.down.circle") { Task { await download([f]) } }
    }
    Button("分享 / 存储到「文件」", systemImage: "square.and.arrow.up") { Task { await share([f]) } }
    Button("转发", systemImage: "arrowshape.turn.up.right") { forwarding = [f]; showForward = true }
    if isLocal(f) {
      Button(removeLocalTitle, systemImage: "trash") { Task { await removeLocal([f]) } }
    }
    if canManage(f) {
      Divider()
      Button("重命名", systemImage: "pencil") { newName = f.name; renaming = f }
      Button("移动到…", systemImage: "folder") { moving = [f]; showMove = true }
      Button("删除", systemImage: "trash", role: .destructive) { confirmDelete([f]) }
    }
  }

  @ToolbarContentBuilder private var toolbar: some ToolbarContent {
    if editing {
      ToolbarItem(placement: .topBarLeading) {
        Button(selection.count == files.count ? "全不选" : "全选") {
          selection = selection.count == files.count ? [] : Set(files.map(\.id))
        }
      }
      ToolbarItem(placement: .topBarTrailing) {
        Button("完成") { withAnimation { editMode = .inactive; selection = [] } }
      }
      ToolbarItemGroup(placement: .bottomBar) {
        let list = selected
        let manageable = !list.isEmpty && list.allSatisfy(canManage)
        Button("下载", systemImage: "arrow.down.circle") { Task { await download(list) } }
          .disabled(list.isEmpty || progress != nil)
        Spacer()
        Button("转发", systemImage: "arrowshape.turn.up.right") { forwarding = list; showForward = true }
          .disabled(list.isEmpty || progress != nil)
        Spacer()
        Button("分享", systemImage: "square.and.arrow.up") { Task { await share(list) } }
          .disabled(list.isEmpty || progress != nil)
        Spacer()
        Menu {
          Button(removeLocalTitle, systemImage: "trash") { Task { await removeLocal(list) } }
            .disabled(!list.contains(where: isLocal))
          if manageable {
            Button("移动到…", systemImage: "folder") { moving = list; showMove = true }
            Button("从群文件删除", systemImage: "trash", role: .destructive) { confirmDelete(list) }
          }
        } label: {
          Label("更多", systemImage: "ellipsis.circle")
        }
        .disabled(list.isEmpty || progress != nil)
      }
    } else {
      ToolbarItem(placement: .topBarTrailing) {
        Menu {
          Button("选择", systemImage: "checkmark.circle") { withAnimation { editMode = .active } }
            .disabled(files.isEmpty)
          if isAdmin && folderId.isEmpty {
            Button("新建文件夹", systemImage: "folder.badge.plus") { folderName = ""; creatingFolder = true }
          }
        } label: {
          Image(systemName: "ellipsis.circle")
        }
      }
    }
  }

  private func detail(_ f: Qqbridge_V1_GroupFile) -> String {
    var parts = [ByteCountFormatter.string(fromByteCount: Int64(f.size), countStyle: .file)]
    if !f.uploaderName.isEmpty { parts.append(f.uploaderName) }
    if f.modifyTime > 0 { parts.append(Format.date(f.modifyTime)) }
    if f.deadTime > 0 { parts.append("\(Format.date(f.deadTime)) 过期") }
    return parts.joined(separator: " · ")
  }

  // MARK: - 加载

  private func load() async {
    #if targetEnvironment(macCatalyst)
    await fileList.load().value
    if !Task.isCancelled { await refreshLocal() }
    #else
    var req = Qqbridge_V1_ListGroupFilesRequest()
    req.groupID = groupId
    req.folderID = folderId
    do {
      let res = try await session.api.contacts.listGroupFiles(request: req, headers: session.api.headers).get()
      // 2026-10-14 Mac 实测：刷新仍存在的群文件会清空多选。QQ 的 file_id 会变化（见 lessons L2）。
      // 使用本次响应的操作 ID，按同目录内唯一的文件元数据恢复；重名或已改变的项目不猜测。
      let refreshedSelection = GroupFileSelection.refreshed(selection, from: files.map(selectionItem), to: res.files.map(selectionItem))
      folders = res.folders
      files = res.files
      selection = refreshedSelection
      await refreshLocal()
      state = .loaded
    } catch {
      state = .failed(LoadState.describe(error))
    }
    #endif
  }

  private func selectionItem(_ file: Qqbridge_V1_GroupFile) -> GroupFileSelection.Item {
    .init(id: file.id, key: .init(name: file.name, size: file.size, modified: file.modifyTime, uploader: file.uploaderID, busid: file.busid))
  }

  private func refreshLocal() async {
    let shas = files.map(\.sha256).filter { !$0.isEmpty }
    #if targetEnvironment(macCatalyst)
    local = MacDownloads.shared.savedSet(shas)
    #else
    local = (try? await session.media.cachedSet(shas)) ?? []
    #endif
  }

  // MARK: - 下载、打开、分享、转发

  /// 服务端没有就先让它从 QQ 下载（大文件要等一会儿），返回 sha256。
  private func ensureServer(_ f: Qqbridge_V1_GroupFile) async throws -> String {
    if !f.sha256.isEmpty { return f.sha256 }
    var req = Qqbridge_V1_FetchGroupFileRequest()
    req.groupID = groupId
    req.fileID = f.id
    req.busid = f.busid
    req.name = f.name
    req.size = f.size
    let sha = try await session.api.contacts.fetchGroupFile(request: req, headers: session.api.headers).get().sha256
    if let i = files.firstIndex(where: { $0.id == f.id }) { files[i].sha256 = sha }
    return sha
  }

  /// 下到手机上，返回一份带原文件名的副本（QuickLook、分享靠扩展名认类型）。
  private func fetchLocal(_ f: Qqbridge_V1_GroupFile) async throws -> URL {
    busy.insert(f.id)
    defer { busy.remove(f.id) }
    let sha = try await ensureServer(f)
    #if targetEnvironment(macCatalyst)
    let saved = try await MacDownloads.shared.file(sha: sha, name: f.name, session: session)
    local.insert(sha)
    return saved
    #else
    let cached = try await session.media.file(for: sha, chatId: chatId)
    local.insert(sha)
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("groupfiles/\(sha)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let named = dir.appendingPathComponent(f.name.isEmpty ? sha : f.name)
    if !FileManager.default.fileExists(atPath: named.path) { try FileManager.default.copyItem(at: cached, to: named) }
    return named
    #endif
  }

  private func open(_ f: Qqbridge_V1_GroupFile) async {
    do {
      preview = try await fetchLocal(f)
    } catch {
      self.error = LoadState.describe(error)
    }
  }

  /// 逐个下到手机；返回下好的副本，失败的汇总提示。
  @discardableResult
  private func download(_ list: [Qqbridge_V1_GroupFile], verb: String = "下载") async -> [URL] {
    var urls: [URL] = []
    var failed: [String] = []
    for (i, f) in list.enumerated() {
      if list.count > 1 { progress = "正在\(verb) \(i + 1)/\(list.count)" }
      do {
        urls.append(try await fetchLocal(f))
      } catch {
        failed.append("\(f.name)：\(LoadState.describe(error))")
      }
    }
    progress = nil
    if !failed.isEmpty {
      error = "\(failed.count) 个文件下载失败\n" + failed.prefix(5).joined(separator: "\n")
    } else if verb == "下载" {
      #if targetEnvironment(macCatalyst)
      model.showToast(AppToast(text: list.count == 1 ? "已保存到下载目录" : "已保存 \(list.count) 个文件到下载目录"))
      #else
      model.showToast(AppToast(text: list.count == 1 ? "已下载到本机" : "已下载 \(list.count) 个文件到本机"))
      #endif
    }
    return urls
  }

  private func share(_ list: [Qqbridge_V1_GroupFile]) async {
    let urls = await download(list, verb: "准备")
    guard !urls.isEmpty else { return }
    sharing = urls
    showShare = true
  }

  /// 转发：服务端没有的先下到服务端，再作为文件发到选的会话（不经手机）。
  private func forward(_ list: [Qqbridge_V1_GroupFile], to chat: Int64) async {
    var sent = 0
    var failed: [String] = []
    for (i, f) in list.enumerated() {
      progress = list.count > 1 ? "正在转发 \(i + 1)/\(list.count)" : "正在转发…"
      do {
        busy.insert(f.id)
        defer { busy.remove(f.id) }
        let sha = try await ensureServer(f)
        var seg = Qqbridge_V1_OutgoingSegment()
        seg.file.sha256 = sha
        seg.file.name = f.name
        try await session.sender.send(chatId: chat, segments: [seg])
        sent += 1
      } catch {
        failed.append("\(f.name)：\(LoadState.describe(error))")
      }
    }
    progress = nil
    if editing { withAnimation { editMode = .inactive; selection = [] } }
    if sent > 0 {
      let name = (try? session.store.dialogItems(limit: 5000))?.first { $0.id == chat }?.title ?? "会话"
      model.showToast(AppToast(text: sent == 1 ? "已转发到「\(name)」" : "已转发 \(sent) 个文件到「\(name)」", chatId: chat))
    }
    if !failed.isEmpty { error = "\(failed.count) 个文件转发失败\n" + failed.prefix(5).joined(separator: "\n") }
  }

  /// 删掉手机上的副本（服务端和群里的不动）。
  private func removeLocal(_ list: [Qqbridge_V1_GroupFile]) async {
    let shas = list.filter(isLocal).map(\.sha256)
    guard !shas.isEmpty else { return }
    do {
      #if targetEnvironment(macCatalyst)
      try MacDownloads.shared.trash(shas)
      await refreshLocal()
      model.showToast(AppToast(text: "已将下载文件移到废纸篓"))
      #else
      let freed = try await session.media.remove(shas)
      for sha in shas {
        try? FileManager.default.removeItem(at: FileManager.default.temporaryDirectory.appendingPathComponent("groupfiles/\(sha)", isDirectory: true))
      }
      local.subtract(shas)
      model.showToast(AppToast(text: "已删除本机文件，释放 \(ByteCountFormatter.string(fromByteCount: freed, countStyle: .file))"))
      #endif
    } catch {
      self.error = LoadState.describe(error)
    }
  }

  // MARK: - 管理（QQ 那边按权限判断）

  private func confirmDelete(_ list: [Qqbridge_V1_GroupFile]) {
    guard !list.isEmpty else { return }
    deleting = list
    showDelete = true
  }

  private func delete(_ list: [Qqbridge_V1_GroupFile]) async {
    var req = Qqbridge_V1_DeleteGroupFilesRequest()
    req.groupID = groupId
    req.fileIds = list.map(\.id)
    progress = "正在删除…"
    defer { progress = nil }
    do {
      let res = try await session.api.contacts.deleteGroupFiles(request: req, headers: session.api.headers).get()
      report(res.succeeded, res.failures, verb: "删除", names: list)
    } catch {
      self.error = LoadState.describe(error)
    }
    if editing { withAnimation { editMode = .inactive; selection = [] } }
    await load()
  }

  private func move(_ list: [Qqbridge_V1_GroupFile], to target: String) async {
    guard target != folderId else { return }
    var req = Qqbridge_V1_MoveGroupFilesRequest()
    req.groupID = groupId
    req.fileIds = list.map(\.id)
    req.fromFolderID = folderId
    req.toFolderID = target
    progress = "正在移动…"
    defer { progress = nil }
    do {
      let res = try await session.api.contacts.moveGroupFiles(request: req, headers: session.api.headers).get()
      report(res.succeeded, res.failures, verb: "移动", names: list)
    } catch {
      self.error = LoadState.describe(error)
    }
    if editing { withAnimation { editMode = .inactive; selection = [] } }
    await load()
  }

  private func rename(_ f: Qqbridge_V1_GroupFile, to name: String) async {
    let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty, name != f.name else { return }
    var req = Qqbridge_V1_RenameGroupFileRequest()
    req.groupID = groupId
    req.fileID = f.id
    req.folderID = folderId
    req.newName = name
    req.name = f.name
    req.size = f.size
    do {
      _ = try await session.api.contacts.renameGroupFile(request: req, headers: session.api.headers).get()
    } catch {
      self.error = LoadState.describe(error)
    }
    await load()
  }

  private func createFolder(_ name: String) async {
    let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else { return }
    var req = Qqbridge_V1_CreateGroupFolderRequest()
    req.groupID = groupId
    req.name = name
    do {
      _ = try await session.api.contacts.createGroupFolder(request: req, headers: session.api.headers).get()
    } catch {
      self.error = LoadState.describe(error)
    }
    await load()
  }

  private func deleteFolder(_ f: Qqbridge_V1_GroupFolder) async {
    var req = Qqbridge_V1_DeleteGroupFolderRequest()
    req.groupID = groupId
    req.folderID = f.id
    do {
      _ = try await session.api.contacts.deleteGroupFolder(request: req, headers: session.api.headers).get()
      model.showToast(AppToast(text: "已删除文件夹「\(f.name)」"))
    } catch {
      self.error = LoadState.describe(error)
    }
    await load()
  }

  private func report(_ succeeded: UInt32, _ failures: [Qqbridge_V1_GroupFileOpFailure], verb: String, names: [Qqbridge_V1_GroupFile]) {
    if succeeded > 0 { model.showToast(AppToast(text: "已\(verb) \(succeeded) 个文件")) }
    guard !failures.isEmpty else { return }
    let byId = Dictionary(names.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
    error = "\(failures.count) 个文件没能\(verb)\n" + failures.prefix(5).map { "\(byId[$0.fileID] ?? $0.fileID)：\($0.reason)" }.joined(separator: "\n")
  }

  static func icon(_ name: String) -> String {
    switch (name as NSString).pathExtension.lowercased() {
    case "jpg", "jpeg", "png", "gif", "heic", "webp": "photo"
    case "mp4", "mov", "mkv", "avi": "film"
    case "mp3", "m4a", "wav", "flac", "aac": "music.note"
    case "zip", "rar", "7z", "tar", "gz": "doc.zipper"
    case "pdf": "doc.richtext"
    case "doc", "docx", "txt", "md", "pages": "doc.text"
    case "xls", "xlsx", "csv", "numbers": "tablecells"
    case "ppt", "pptx", "key": "rectangle.on.rectangle"
    case "apk", "ipa", "exe", "dmg": "shippingbox"
    default: "doc"
    }
  }
}

/// 移动到哪个文件夹：根目录和根目录下的文件夹（QQ 群文件只有一层）。
struct GroupFolderPicker: View {
  let session: Session
  let groupId: Int64
  /// 现在所在的文件夹（不能选）。
  let current: String
  let onCancel: () -> Void
  let onPick: (String) -> Void
  #if targetEnvironment(macCatalyst)
  var body: some View {
    MacGroupFolderPicker(service: MacGroupFoldersService(session: session, groupID: groupId), current: current, onCancel: onCancel, onPick: onPick)
  }
  #else
  @Environment(\.dismiss) private var dismiss
  @State private var folders: [Qqbridge_V1_GroupFolder] = []
  @State private var state = LoadState.loading

  var body: some View {
    NavigationStack {
      List {
        row(id: "", name: "群文件（根目录）", icon: "tray.full")
        ForEach(folders, id: \.id) { f in row(id: f.id, name: f.name, icon: "folder.fill") }
      }
      .overlay { state.overlay(empty: false, emptyText: "", icon: "folder") }
      .navigationTitle("移动到")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
      .task { await load() }
    }
  }

  private func row(id: String, name: String, icon: String) -> some View {
    Button { onPick(id) } label: {
      HStack {
        Label(name, systemImage: icon).foregroundStyle(id == current ? .secondary : .primary)
        Spacer()
        if id == current { Text("当前位置").font(.caption).foregroundStyle(.secondary) }
      }
    }
    .disabled(id == current)
  }

  private func load() async {
    var req = Qqbridge_V1_ListGroupFilesRequest()
    req.groupID = groupId
    do {
      folders = try await session.api.contacts.listGroupFiles(request: req, headers: session.api.headers).get().folders
      state = .loaded
    } catch {
      state = .failed(LoadState.describe(error))
    }
  }
  #endif
}

/// 系统分享面板（存储到「文件」、AirDrop、别的 App）。
struct ShareSheet: UIViewControllerRepresentable {
  let items: [Any]

  func makeUIViewController(context: Context) -> UIActivityViewController {
    UIActivityViewController(activityItems: items, applicationActivities: nil)
  }

  func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
