using System.Security.Cryptography;
using BetterChat.Application;

namespace BetterChat.Infrastructure;

// 只缓存小型预览；单队列避免快速滚动时重复下载同一哈希及并发清理竞态。
public sealed class PreviewCache(string root, long capacity = 256 * 1024 * 1024, long itemLimit = 32 * 1024 * 1024)
{
    private readonly SemaphoreSlim serial = new(1);
    private readonly string directory = Path.TrimEndingDirectorySeparator(Path.GetFullPath(root));
    private bool recovered;
    private IEnumerable<FileInfo> ManagedFiles(string extension)
    {
        if (!Directory.Exists(directory)) return [];
        if ((File.GetAttributes(directory) & FileAttributes.ReparsePoint) != 0) throw new IOException("缓存目录不能是重解析点。");
        return new DirectoryInfo(directory).EnumerateFiles("*" + extension).Where(file =>
            (file.Attributes & FileAttributes.ReparsePoint) == 0 && Path.GetDirectoryName(file.FullName) == directory
            && (extension == ".blob" ? Path.GetFileNameWithoutExtension(file.Name) is { Length: 64 } hash && hash.All(Uri.IsHexDigit)
                : Guid.TryParseExact(Path.GetFileNameWithoutExtension(file.Name), "N", out _))).ToArray();
    }
    private void RecoverTemporaryFiles()
    {
        if (recovered) return;
        foreach (var file in ManagedFiles(".tmp").Where(f => f.LastWriteTimeUtc < DateTime.UtcNow.AddDays(-1)))
        {
            try { file.Delete(); } catch (IOException) { } catch (UnauthorizedAccessException) { }
        }
        recovered = true;
    }
    public async Task<PreviewCacheUsage> GetUsageAsync(CancellationToken ct = default)
    {
        await serial.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            ct.ThrowIfCancellationRequested();
            var blobs = ManagedFiles(".blob").ToArray();
            return new(blobs.Sum(f => f.Length), blobs.Length, ManagedFiles(".tmp").Sum(f => f.Length), capacity);
        }
        finally { serial.Release(); }
    }
    public async Task<PreviewCacheCleanup> ClearAsync(CancellationToken ct = default)
    {
        await serial.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            long bytes = 0; int count = 0, skipped = 0;
            foreach (var file in ManagedFiles(".blob").Concat(ManagedFiles(".tmp").Where(f => f.LastWriteTimeUtc < DateTime.UtcNow.AddDays(-1))))
            {
                ct.ThrowIfCancellationRequested();
                try { long length = file.Length; file.Delete(); bytes += length; count++; }
                catch (IOException) { skipped++; }
                catch (UnauthorizedAccessException) { skipped++; }
            }
            return new(bytes, count, skipped);
        }
        finally { serial.Release(); }
    }
    public async Task<string> GetAsync(string sha, Func<Stream, CancellationToken, Task> download, CancellationToken ct = default)
    {
        if (sha.Length != 64 || !sha.All(Uri.IsHexDigit)) throw new ArgumentException("预览哈希无效。");
        if (capacity <= 0 || itemLimit <= 0 || itemLimit > capacity) throw new ArgumentException("缓存容量无效。");
        sha = sha.ToLowerInvariant();
        await serial.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            Directory.CreateDirectory(directory);
            if ((File.GetAttributes(directory) & FileAttributes.ReparsePoint) != 0) throw new IOException("缓存目录不能是重解析点。");
            RecoverTemporaryFiles();
            string target = Path.Combine(directory, sha + ".blob");
            if (File.Exists(target))
            {
                if ((File.GetAttributes(target) & FileAttributes.ReparsePoint) != 0) throw new IOException("缓存文件不能是重解析点。");
                await using var cached = File.OpenRead(target);
                if (cached.Length <= itemLimit && Convert.ToHexString(await SHA256.HashDataAsync(cached, ct).ConfigureAwait(false)).Equals(sha, StringComparison.OrdinalIgnoreCase))
                { cached.Close(); File.SetLastWriteTimeUtc(target, DateTime.UtcNow); return Path.GetFullPath(target); }
                cached.Close(); File.Delete(target);
            }
            string temporary = Path.Combine(directory, Guid.NewGuid().ToString("N") + ".tmp");
            try
            {
                await using (var output = new FileStream(temporary, FileMode.CreateNew, FileAccess.ReadWrite, FileShare.None, 81920, true))
                {
                    await download(output, ct).ConfigureAwait(false);
                    ct.ThrowIfCancellationRequested();
                    if (output.Length > itemLimit) throw new IOException("预览超过缓存单项大小限制。");
                    output.Position = 0;
                    string actual = Convert.ToHexString(await SHA256.HashDataAsync(output, ct).ConfigureAwait(false));
                    if (!actual.Equals(sha, StringComparison.OrdinalIgnoreCase)) throw new IOException("预览内容哈希校验失败。");
                }
                ct.ThrowIfCancellationRequested();
                long incoming = new FileInfo(temporary).Length;
                var files = ManagedFiles(".blob").OrderBy(f => f.LastWriteTimeUtc).ToArray();
                long total = files.Sum(f => f.Length);
                foreach (var file in files)
                {
                    if (total + incoming <= capacity) break;
                    long length = file.Length; file.Delete(); total -= length;
                }
                File.Move(temporary, target, true);
                return Path.GetFullPath(target);
            }
            finally { if (File.Exists(temporary)) File.Delete(temporary); }
        }
        finally { serial.Release(); }
    }
}
