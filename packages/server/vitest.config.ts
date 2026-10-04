import { defineConfig } from 'vitest/config';

export default defineConfig({
  test: {
    // 集成测试要启动 PGroonga 容器（Testcontainers），首次拉起较慢。
    testTimeout: 120_000,
    hookTimeout: 180_000,
    // 每个测试文件各起一个数据库容器，文件之间并行即可。
    fileParallelism: true,
  },
});
