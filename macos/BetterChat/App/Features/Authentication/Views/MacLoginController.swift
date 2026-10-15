import UIKit
import Observation

/// 控制器只处理原生控件和焦点，校验、请求生命周期与错误状态交给 ViewModel。
@MainActor
final class MacLoginController: UIViewController, UITextFieldDelegate {
  private let viewModel: MacLoginViewModel
  private let server = UITextField()
  private let presets = UIButton(type: .system)
  private let resolvedLabel = UILabel()
  private let healthLabel = UILabel()
  private let retryHealth = UIButton(type: .system)
  private let username = UITextField()
  private let password = UITextField()
  private let errorLabel = UILabel()
  private let submit = UIButton(type: .system)

  init(viewModel: MacLoginViewModel) {
    self.viewModel = viewModel
    super.init(nibName: nil, bundle: nil)
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }


  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemBackground
    let icon = UIImageView(image: UIImage(systemName: "bubble.left.and.bubble.right.fill"))
    icon.tintColor = .systemBlue
    icon.contentMode = .scaleAspectFit
    icon.heightAnchor.constraint(equalToConstant: 64).isActive = true
    let title = UILabel()
    title.text = "欢迎使用 BetterChat"
    title.font = .preferredFont(forTextStyle: .largeTitle)
    title.textAlignment = .center
    title.numberOfLines = 0
    let subtitle = UILabel()
    subtitle.text = "连接你的 QQ Bridge 服务器"
    subtitle.textColor = .secondaryLabel
    subtitle.textAlignment = .center
    subtitle.numberOfLines = 0
    for (field, placeholder) in [(server, "服务器地址"), (username, "用户名"), (password, "密码")] {
      field.placeholder = placeholder
      field.accessibilityLabel = placeholder
      field.borderStyle = .roundedRect
      field.autocapitalizationType = .none
      field.autocorrectionType = .no
      field.delegate = self
      field.heightAnchor.constraint(equalToConstant: 36).isActive = true
    }
    server.keyboardType = .URL
    server.textContentType = .URL
    server.text = viewModel.server
    server.addAction(UIAction { [weak self] _ in
      guard let self else { return }
      viewModel.updateServer(server.text ?? "")
    }, for: .editingChanged)
    configurePresets()
    let serverRow = UIStackView(arrangedSubviews: [server, presets])
    serverRow.spacing = 8
    serverRow.alignment = .center
    // 实际连接地址可能是一整串没有空格的长域名，按字符换行才不会被截断。
    resolvedLabel.font = .preferredFont(forTextStyle: .footnote)
    resolvedLabel.textColor = .secondaryLabel
    resolvedLabel.numberOfLines = 0
    resolvedLabel.lineBreakMode = .byCharWrapping
    resolvedLabel.accessibilityLabel = "实际连接"
    healthLabel.font = .preferredFont(forTextStyle: .footnote)
    healthLabel.numberOfLines = 0
    healthLabel.accessibilityLabel = "服务器连通性"
    var retry = UIButton.Configuration.plain()
    retry.title = "重新检查"
    retry.contentInsets = .zero
    retryHealth.configuration = retry
    retryHealth.contentHorizontalAlignment = .leading
    retryHealth.accessibilityLabel = "重新检查服务器连通性"
    retryHealth.addAction(UIAction { [weak self] _ in self?.viewModel.retryHealthCheck() }, for: .touchUpInside)
    let serverStatus = UIStackView(arrangedSubviews: [resolvedLabel, healthLabel, retryHealth])
    serverStatus.axis = .vertical
    serverStatus.alignment = .fill
    serverStatus.spacing = 4
    username.textContentType = .username
    username.text = viewModel.username
    password.textContentType = .password
    password.isSecureTextEntry = true
    // 连通性变化也会刷新页面；同步编辑值，避免刷新把尚未提交的密码当作空值清掉。
    password.addAction(UIAction { [weak self] _ in
      guard let self else { return }
      viewModel.password = password.text ?? ""
    }, for: .editingChanged)
    password.returnKeyType = .go
    submit.configuration = .filled()
    submit.setTitle("登录", for: .normal)
    submit.addTarget(self, action: #selector(signIn), for: .touchUpInside)
    errorLabel.textColor = .systemRed
    errorLabel.font = .preferredFont(forTextStyle: .callout)
    errorLabel.numberOfLines = 0
    errorLabel.textAlignment = .center
    let form = UIStackView(arrangedSubviews: [icon, title, subtitle, serverRow, serverStatus, username, password, submit, errorLabel])
    form.axis = .vertical
    form.spacing = 14
    form.setCustomSpacing(28, after: subtitle)
    form.setCustomSpacing(8, after: serverRow)
    form.translatesAutoresizingMaskIntoConstraints = false
    // 最小窗口 440×428 放不下整张表单，交给滚动视图；内容不足一屏时仍在可见区域居中。
    let scroll = UIScrollView()
    scroll.translatesAutoresizingMaskIntoConstraints = false
    scroll.keyboardDismissMode = .interactive
    scroll.addSubview(form)
    view.addSubview(scroll)
    let content = scroll.contentLayoutGuide
    let frame = scroll.frameLayoutGuide
    let fillWidth = form.widthAnchor.constraint(equalTo: frame.widthAnchor, constant: -48)
    fillWidth.priority = .defaultHigh
    let fitHeight = content.heightAnchor.constraint(equalTo: frame.heightAnchor)
    fitHeight.priority = .defaultLow
    NSLayoutConstraint.activate([
      scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
      scroll.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
      scroll.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
      scroll.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
      content.widthAnchor.constraint(equalTo: frame.widthAnchor),
      content.heightAnchor.constraint(greaterThanOrEqualTo: frame.heightAnchor),
      fitHeight,
      form.centerXAnchor.constraint(equalTo: content.centerXAnchor),
      form.centerYAnchor.constraint(equalTo: content.centerYAnchor),
      form.topAnchor.constraint(greaterThanOrEqualTo: content.topAnchor, constant: 24),
      form.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -24),
      form.widthAnchor.constraint(lessThanOrEqualToConstant: 360),
      form.leadingAnchor.constraint(greaterThanOrEqualTo: frame.leadingAnchor, constant: 24),
      fillWidth,
    ])
    observeState()
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    viewModel.startHealthChecks()
  }

  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    viewModel.stopHealthChecks()
  }

  func textFieldShouldReturn(_ textField: UITextField) -> Bool {
    if textField === server { username.becomeFirstResponder() }
    else if textField === username { password.becomeFirstResponder() }
    else { signIn() }
    return true
  }

  /// 标准下拉菜单；每次展开时按当前地址重建，勾选与输入框一致的预设。
  private func configurePresets() {
    var configuration = UIButton.Configuration.bordered()
    configuration.image = UIImage(systemName: "list.bullet")
    presets.configuration = configuration
    presets.accessibilityLabel = "服务器预设"
    presets.toolTip = "服务器预设"
    presets.showsMenuAsPrimaryAction = true
    presets.isHidden = viewModel.presets.isEmpty
    presets.setContentHuggingPriority(.required, for: .horizontal)
    presets.setContentCompressionResistancePriority(.required, for: .horizontal)
    presets.menu = UIMenu(title: "服务器预设", children: [
      UIDeferredMenuElement.uncached { [weak self] completion in
        guard let self else { return completion([]) }
        completion(viewModel.presets.map { preset in
          let action = UIAction(title: preset.title, subtitle: preset.address) { [weak self] _ in
            guard let self else { return }
            viewModel.choosePreset(preset)
            server.text = viewModel.server
          }
          action.state = preset.address == viewModel.server ? .on : .off
          return action
        })
      },
    ])
  }

  @objc private func signIn() {
    viewModel.updateServer(server.text ?? "")
    viewModel.username = username.text ?? ""
    viewModel.password = password.text ?? ""
    viewModel.submit()
  }

  private func observeState() {
    let state = withObservationTracking {
      (viewModel.isSubmitting, viewModel.error, viewModel.password,
       viewModel.resolvedServerText, viewModel.health, viewModel.healthText, viewModel.canRetryHealthCheck,
       viewModel.resolvedServer)
    } onChange: { [weak self] in
      Task { @MainActor [weak self] in self?.observeState() }
    }
    submit.isEnabled = !state.0
    submit.configuration?.showsActivityIndicator = state.0
    errorLabel.text = state.1
    if state.2.isEmpty, !state.0 { password.text = nil }
    resolvedLabel.text = state.3
    resolvedLabel.accessibilityValue = state.7?.absoluteString ?? "地址不对"
    healthLabel.text = state.5
    healthLabel.accessibilityValue = state.5
    healthLabel.isHidden = state.5 == nil
    let healthColor: UIColor = switch state.4 {
    case .reachable: .systemGreen
    case .notServer, .failed: .systemRed
    case .idle, .checking: .secondaryLabel
    }
    healthLabel.textColor = healthColor
    retryHealth.isHidden = !state.6
  }
}
