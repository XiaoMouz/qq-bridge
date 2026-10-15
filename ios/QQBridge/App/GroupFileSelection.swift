/// QQ 群文件的操作 ID 会在重新列出时变化；只在前后列表都能唯一匹配时恢复选择。
enum GroupFileSelection {
  struct Key: Hashable {
    let name: String
    let size: UInt64
    let modified: Int64
    let uploader: Int64
    let busid: UInt32
  }

  struct Item {
    let id: String
    let key: Key
  }

  static func refreshed(_ selection: Set<String>, from old: [Item], to new: [Item]) -> Set<String> {
    let currentIDs = Set(new.map(\.id))
    var result = selection.intersection(currentIDs)
    let oldGroups = Dictionary(grouping: old, by: \.key)
    let newGroups = Dictionary(grouping: new, by: \.key)
    for item in old where selection.contains(item.id) && !currentIDs.contains(item.id) {
      guard oldGroups[item.key]?.count == 1, let matches = newGroups[item.key], matches.count == 1,
            let replacement = matches.first else { continue }
      result.insert(replacement.id)
    }
    return result
  }
}
