using Qqbridge.V1;

namespace BetterChat.Core;

public static class Authentication
{
    public static Uri ServerUri(string address)
    {
        string value = address.Trim();
        if (value.Length == 0) throw new ArgumentException("请输入服务器地址。");
        // 没写协议：本机地址（127.0.0.1:8080、localhost）用 http，其他用 https（同 iOS AppModel.normalize；Windows 只允许本机走 http）。
        if (!value.Contains("://", StringComparison.Ordinal))
            value = (Uri.TryCreate("http://" + value, UriKind.Absolute, out var local) && local.IsLoopback ? "http://" : "https://") + value;
        if (!Uri.TryCreate(value, UriKind.Absolute, out var uri) || string.IsNullOrEmpty(uri.Host)
            || uri.UserInfo.Length > 0 || uri.Query.Length > 0 || uri.Fragment.Length > 0)
            throw new ArgumentException("服务器地址格式不正确。");
        if (uri.Scheme != "https" && !(uri.Scheme == "http" && uri.IsLoopback))
            throw new ArgumentException("服务器须使用 HTTPS；本机调试可用 HTTP。");
        return new Uri(uri.AbsoluteUri.TrimEnd('/') + "/");
    }

    public static async Task<LoginResponse> LoginAsync(IAuthService api, string username, string password,
        string deviceName, CancellationToken ct = default)
    {
        if (string.IsNullOrWhiteSpace(username)) throw new ArgumentException("请输入用户名。");
        if (string.IsNullOrEmpty(password)) throw new ArgumentException("请输入密码。");
        // 密码按原样发送，空格可能是密码的一部分；只在用户提交表单时换取设备凭据。
        var response = await api.LoginAsync(new LoginRequest
        {
            Username = username.Trim(), Password = password,
            DeviceName = deviceName, Platform = "windows"
        }, ct);
        if (string.IsNullOrWhiteSpace(response.Token)) throw new IOException("服务器未返回登录凭据。");
        return response;
    }
}
