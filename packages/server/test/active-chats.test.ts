import { describe, expect, it } from 'vitest';
import { ActiveChats } from '../src/sync/active-chats.ts';

describe('ActiveChats', () => {
  it('tracks one chat per device and forgets devices that stop refreshing', () => {
    let now = 1_000;
    const active = new ActiveChats(120_000, () => now);
    active.set(1, 10);
    active.set(2, 10);
    active.set(3, 30);
    expect(active.chatIds().sort()).toEqual([10, 30]);

    active.set(1, 20); // 设备 1 切到另一个会话
    expect(active.chatIds().sort()).toEqual([10, 20, 30]);
    active.set(2, null); // 设备 2 退出会话
    expect(active.chatIds().sort()).toEqual([20, 30]);

    now += 60_000;
    active.set(3, 30); // 设备 3 按时刷新
    now += 61_000; // 设备 1 已经 121 秒没刷新（例如 App 被挂起）
    expect(active.chatIds()).toEqual([30]);
  });
});
