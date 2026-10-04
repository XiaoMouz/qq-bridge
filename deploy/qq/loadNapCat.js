// QQBRIDGE_LOADER_HOOK_V1
// QQ 的 Electron 入口（resources/app/package.json 的 main）。
// 默认行为与官方 napcat-docker 镜像完全一致：加载 NapCat。
// 只有设置 QQBRIDGE_AV_HOST=1 的第二个进程才改为启动 AV Host（packages/av-host），用来承载 libAVSDKPlugin.so。
// 官方原文件保存在同目录的 loadNapCat.official.js。
if (process.env.QQBRIDGE_AV_HOST === '1') {
  require(process.env.QQBRIDGE_AV_HOST_ENTRY || '/app/av-host/host.cjs');
} else {
  (async () => {
    await import('file:///app/napcat/napcat.mjs');
  })();
}
