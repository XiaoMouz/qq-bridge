import SwiftUI

// 资料卡和存储引用共用窗口级表单的呈现、关闭与 Esc 生命周期。
typealias MacProfileCardPresenter<Content: View> = MacFormPresenter<ProfileTarget, Content>
typealias MacProfileCardAnchor = MacFormAnchor<Int64>
