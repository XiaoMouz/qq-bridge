namespace BetterChat.Core;

// 与服务端 StorageBrowser 的白名单一致；头像、派生预览和其他项只有全局统计，不能按会话浏览。
public static class StorageCategories
{
    public static bool HasMediaItems(string category) => category is "image" or "qq_thumb" or "sticker" or "video" or "record" or "file" or "group_file";
    public static bool HasChats(string category) => category == "message" || HasMediaItems(category);
}
