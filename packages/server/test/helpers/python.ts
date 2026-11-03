import { execFileSync } from 'node:child_process';
import { importPython } from '../../src/imports/process.ts';

/** 备份解密依赖 APSW（pnpm --filter @qqbridge/server imports:setup）；没装时跳过并说明原因，不报看不懂的失败。 */
export const hasApsw = (() => {
  try {
    execFileSync(importPython(), ['-c', 'import apsw'], { stdio: 'ignore' });
    return true;
  } catch {
    console.warn(`跳过备份解密测试：${importPython()} 没有 apsw，先运行 imports:setup`);
    return false;
  }
})();
