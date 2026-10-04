// 把插件打包成 NapCat 可直接加载的单文件 ESM：dist/index.mjs + dist/package.json。
// 插件运行在 QQNT 内置的 Node 里，所以不打入任何原生模块；用到的纯 JS 依赖（ws）直接打包进来。
import { build } from 'esbuild';
import { readFile, writeFile, mkdir } from 'node:fs/promises';

const pkg = JSON.parse(await readFile(new URL('./package.json', import.meta.url), 'utf8'));

await mkdir(new URL('./dist/', import.meta.url), { recursive: true });

await build({
  entryPoints: ['src/index.ts'],
  outfile: 'dist/index.mjs',
  bundle: true,
  platform: 'node',
  format: 'esm',
  target: 'node20',
  sourcemap: 'inline',
  define: { __QQBRIDGE_PLUGIN_VERSION__: JSON.stringify(pkg.version) },
  // ws 的可选原生加速依赖：没装时 ws 自动退回纯 JS 实现。
  external: ['bufferutil', 'utf-8-validate'],
  // 打进来的 CommonJS 依赖（ws）会 require Node 内置模块；ESM 里没有 require，这里补一个。
  banner: {
    js: "import { createRequire as __qqbridgeCreateRequire } from 'node:module'; const require = __qqbridgeCreateRequire(import.meta.url);",
  },
  legalComments: 'inline',
  logLevel: 'info',
});

await writeFile(
  new URL('./dist/package.json', import.meta.url),
  JSON.stringify(
    {
      name: pkg.name,
      plugin: 'QQ Bridge',
      version: pkg.version,
      type: 'module',
      main: 'index.mjs',
      description: pkg.description,
      author: 'qq-bridge',
    },
    null,
    2,
  ) + '\n',
);
