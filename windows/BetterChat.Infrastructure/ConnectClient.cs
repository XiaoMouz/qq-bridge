using System.Buffers.Binary;
using System.Net.Http.Headers;
using System.Runtime.CompilerServices;
using System.Text.Json;
using Google.Protobuf;

namespace BetterChat.Core;

public sealed class ConnectClient : IDisposable
{
    private readonly HttpClient http;
    public Uri BaseUri { get; }
    public string Token { private get; set; } = "";

    public ConnectClient(Uri server, HttpMessageHandler? handler = null)
    {
        if (server.Scheme != "https" && !(server.Scheme == "http" && server.IsLoopback))
            throw new ArgumentException("服务器须使用 HTTPS；本机调试可用 HTTP。");
        BaseUri = new Uri(server.AbsoluteUri.TrimEnd('/') + "/");
        http = handler is null ? new HttpClient() : new HttpClient(handler);
        http.Timeout = Timeout.InfiniteTimeSpan;
    }

    private HttpRequestMessage Request(string path, byte[] data, bool stream = false)
    {
        var request = new HttpRequestMessage(HttpMethod.Post, new Uri(BaseUri, path));
        request.Headers.Add("Connect-Protocol-Version", "1");
        if (Token.Length > 0) request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", Token);
        request.Content = new ByteArrayContent(data);
        request.Content.Headers.ContentType = new MediaTypeHeaderValue(stream ? "application/connect+proto" : "application/proto");
        return request;
    }

    public async Task<T> UnaryAsync<T>(string path, IMessage input, MessageParser<T> parser, CancellationToken ct = default) where T : IMessage<T>
    {
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(ct);
        timeout.CancelAfter(TimeSpan.FromSeconds(90));
        using var request = Request(path, input.ToByteArray());
        using var response = await http.SendAsync(request, timeout.Token).ConfigureAwait(false);
        var body = await response.Content.ReadAsByteArrayAsync(timeout.Token).ConfigureAwait(false);
        if (!response.IsSuccessStatusCode) throw ParseError(body, response.StatusCode.ToString());
        return parser.ParseFrom(body);
    }

    public async IAsyncEnumerable<T> StreamAsync<T>(string path, IMessage input, MessageParser<T> parser,
        [EnumeratorCancellation] CancellationToken ct = default) where T : IMessage<T>
    {
        byte[] payload = input.ToByteArray();
        byte[] envelope = new byte[payload.Length + 5];
        BinaryPrimitives.WriteUInt32BigEndian(envelope.AsSpan(1), (uint)payload.Length);
        payload.CopyTo(envelope, 5);
        using var request = Request(path, envelope, true);
        using var response = await http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, ct).ConfigureAwait(false);
        if (!response.IsSuccessStatusCode)
            throw ParseError(await response.Content.ReadAsByteArrayAsync(ct), response.StatusCode.ToString());
        using var body = await response.Content.ReadAsStreamAsync(ct).ConfigureAwait(false);
        var header = new byte[5];
        while (true)
        {
            // 服务端每 25 秒心跳，读超时用于发现无 FIN 的半开连接。
            using var idle = CancellationTokenSource.CreateLinkedTokenSource(ct);
            idle.CancelAfter(TimeSpan.FromSeconds(70));
            await body.ReadExactlyAsync(header, idle.Token).ConfigureAwait(false);
            uint length = BinaryPrimitives.ReadUInt32BigEndian(header.AsSpan(1));
            if (length > 32 * 1024 * 1024) throw new IOException("同步帧超过大小限制。");
            var data = new byte[length];
            await body.ReadExactlyAsync(data, idle.Token).ConfigureAwait(false);
            if ((header[0] & 2) != 0)
            {
                using var json = JsonDocument.Parse(data);
                if (json.RootElement.TryGetProperty("error", out var error))
                    throw new RpcException(error.GetProperty("code").GetString() ?? "unknown", error.TryGetProperty("message", out var m) ? m.GetString() ?? "同步失败" : "同步失败");
                yield break;
            }
            if (header[0] != 0) throw new IOException("服务端返回了未协商的帧压缩格式。");
            yield return parser.ParseFrom(data);
        }
    }

    private static RpcException ParseError(byte[] body, string fallback)
    {
        try
        {
            using var json = JsonDocument.Parse(body);
            var root = json.RootElement;
            return new RpcException(root.GetProperty("code").GetString() ?? fallback,
                root.TryGetProperty("message", out var m) ? m.GetString() ?? fallback : fallback);
        }
        catch (JsonException) { return new RpcException(fallback, "服务器返回无效响应。"); }
        catch (KeyNotFoundException) { return new RpcException(fallback, "服务器返回无效响应。"); }
    }

    public Uri ResolveMedia(string path)
    {
        var uri = new Uri(BaseUri, path);
        if (uri.Scheme != "https" && !(uri.Scheme == "http" && uri.IsLoopback)) throw new IOException("媒体地址不安全。");
        return uri;
    }
    public async Task DownloadPreviewAsync(string url, Stream target, CancellationToken ct)
    {
        const long limit = 32 * 1024 * 1024;
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(ct);
        timeout.CancelAfter(TimeSpan.FromMinutes(2));
        // 签名 URL 自带访问授权，不向 CDN 或重定向目标附加设备令牌。
        using var request = new HttpRequestMessage(HttpMethod.Get, ResolveMedia(url));
        using var response = await http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, timeout.Token).ConfigureAwait(false);
        response.EnsureSuccessStatusCode();
        if (response.Content.Headers.ContentLength > limit) throw new IOException("预览超过下载大小限制。");
        await using var source = await response.Content.ReadAsStreamAsync(timeout.Token).ConfigureAwait(false);
        byte[] buffer = new byte[81920]; long received = 0;
        int count;
        while ((count = await source.ReadAsync(buffer, timeout.Token).ConfigureAwait(false)) != 0)
        {
            received += count;
            if (received > limit) throw new IOException("预览超过下载大小限制。");
            await target.WriteAsync(buffer.AsMemory(0, count), timeout.Token).ConfigureAwait(false);
        }
    }

    public async Task UploadAsync(string url, Stream source, long offset, CancellationToken ct)
    {
        if (!source.CanRead || !source.CanSeek || offset < 0 || offset > source.Length)
            throw new IOException("上传流或续传偏移无效。");
        var uri = new Uri(BaseUri, url);
        if (uri.GetLeftPart(UriPartial.Authority) != BaseUri.GetLeftPart(UriPartial.Authority))
            throw new IOException("上传地址必须属于当前服务器。");
        source.Position = offset;
        long length = source.Length;
        var buffer = new byte[4 * 1024 * 1024];
        while (offset < length)
        {
            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(ct);
            timeout.CancelAfter(TimeSpan.FromSeconds(90));
            int count = await source.ReadAsync(buffer.AsMemory(0, (int)Math.Min(buffer.Length, length - offset)), timeout.Token).ConfigureAwait(false);
            if (count == 0 || source.Length != length)
                throw new IOException("文件在上传期间发生变化或提前结束，请重新选择文件上传。");
            using var request = new HttpRequestMessage(HttpMethod.Patch, uri);
            request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", Token);
            request.Headers.Add("Tus-Resumable", "1.0.0");
            request.Headers.Add("Upload-Offset", offset.ToString(System.Globalization.CultureInfo.InvariantCulture));
            request.Content = new ByteArrayContent(buffer, 0, count);
            request.Content.Headers.ContentType = new MediaTypeHeaderValue("application/offset+octet-stream");
            using var response = await http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, timeout.Token).ConfigureAwait(false);
            response.EnsureSuccessStatusCode();
            if (!response.Headers.TryGetValues("Upload-Offset", out var values)
                || !long.TryParse(values.SingleOrDefault(), System.Globalization.NumberStyles.None,
                    System.Globalization.CultureInfo.InvariantCulture, out long confirmed) || confirmed != offset + count)
                throw new IOException("服务器未确认本次上传的完整偏移，请重新准备续传。");
            offset += count;
        }
        ct.ThrowIfCancellationRequested();
        if (source.Length != length) throw new IOException("文件在上传期间发生变化，请重新选择文件上传。");
    }
    public void Dispose() => http.Dispose();
}
