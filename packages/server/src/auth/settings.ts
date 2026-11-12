// 账号级设置（目前只有「通知手机」）：存在 accounts 表，改动时分配全局 pts 并发一条 settings 更新，
// 已连着 Subscribe 的设备马上收到，离线的设备下次补差量时从 Difference.settings 拿到。
import { sql } from 'drizzle-orm';
import { one } from '../db/client.ts';
import type { AccountSettingsRow } from '../sync/rows.ts';
import type { WriterRegistry } from '../sync/writer.ts';

export async function setAccountSettings(
  writers: WriterRegistry,
  accountId: number,
  settings: AccountSettingsRow,
): Promise<{ pts: number; settings: AccountSettingsRow }> {
  return writers.forAccount(accountId).run(async (w) => {
    const pts = await w.allocPts();
    const row = await one<{ phone_notifications_off: boolean }>(
      w.tx,
      sql`update accounts set phone_notifications_off = ${settings.phoneNotificationsOff}, settings_pts = ${pts}
           where id = ${accountId} returning phone_notifications_off`,
    );
    const saved = { phoneNotificationsOff: row.phone_notifications_off };
    w.emit({ type: 'settings', pts, settings: saved });
    return { pts, settings: saved };
  });
}
