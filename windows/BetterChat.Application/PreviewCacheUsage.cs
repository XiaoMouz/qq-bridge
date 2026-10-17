namespace BetterChat.Application;

public sealed record PreviewCacheUsage(long Bytes, int Files, long TemporaryBytes, long Capacity);
public sealed record PreviewCacheCleanup(long RemovedBytes, int RemovedFiles, int SkippedFiles);
