@main
struct GroupFileSelectionCheck {
  static func main() {
    typealias Item = GroupFileSelection.Item
    let key = GroupFileSelection.Key(name: "验收.txt", size: 68, modified: 100, uploader: 1, busid: 3)
    let otherKey = GroupFileSelection.Key(name: "另一份.txt", size: 68, modified: 100, uploader: 1, busid: 3)
    let old = [Item(id: "old", key: key), Item(id: "untouched", key: otherKey)]
    let new = [Item(id: "untouched", key: otherKey), Item(id: "new", key: key)]
    // 列表顺序与操作 ID 都变化，仍只选原来那一份，并交付新 ID 给后续操作。
    precondition(GroupFileSelection.refreshed(["old"], from: old, to: new) == ["new"])
    precondition(GroupFileSelection.refreshed(["old", "untouched"], from: old, to: new) == ["new", "untouched"])
    precondition(GroupFileSelection.refreshed([], from: old, to: new).isEmpty)
    precondition(GroupFileSelection.refreshed(["old"], from: old, to: []).isEmpty)
    // 前后任一侧有相同元数据的多个文件时，不扩大或猜测用户选择。
    let duplicate = Item(id: "duplicate", key: key)
    precondition(GroupFileSelection.refreshed(["old"], from: old + [duplicate], to: new).isEmpty)
    precondition(GroupFileSelection.refreshed(["old"], from: old, to: new + [duplicate]).isEmpty)
    // 元数据改变而 ID 也改变，不把替换后的文件自动选中。
    let changed = GroupFileSelection.Key(name: key.name, size: key.size, modified: 101, uploader: key.uploader, busid: key.busid)
    precondition(GroupFileSelection.refreshed(["old"], from: old, to: [Item(id: "new", key: changed)]).isEmpty)
    // 仍有精确 ID 时可保留，即使同目录有其他同名同大小文件。
    precondition(GroupFileSelection.refreshed(["old"], from: old, to: old + [duplicate]) == ["old"])
    print("群文件选择检查通过：ID 更新、重排、多选、删除、歧义和元数据变化")
  }
}
