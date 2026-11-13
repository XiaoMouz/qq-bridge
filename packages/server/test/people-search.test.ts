import { describe, expect, it } from 'vitest';
import { matchScore, pinyinKeys } from '../src/contacts/search.ts';

const key = (text: string) => ({ text: text.toLowerCase(), ...pinyinKeys(text) });

describe('找人的拼音匹配', () => {
  it('全拼、首字母、原文都能找到中文名字', () => {
    expect(pinyinKeys('张三')).toEqual({ full: 'zhangsan', initials: 'zs' });
    expect(matchScore(key('张三'), 'zhangsan')).toBe(3);
    expect(matchScore(key('张三'), 'zs')).toBe(4);
    expect(matchScore(key('张三'), '张')).toBe(1);
    expect(matchScore(key('小谋Z的群'), 'xmz')).toBe(4);
    expect(matchScore(key('小谋Z的群'), 'mouz')).toBe(5);
  });

  it('不相干的不算，单个字母不按首字母中间匹配', () => {
    expect(matchScore(key('张三'), 'lisi')).toBeNull();
    expect(matchScore(key('王小明'), 'x')).toBe(5);
    expect(matchScore(key('王小明'), 'xm')).toBe(6);
    expect(matchScore(key('Something'), 'some')).toBe(1);
  });
});
