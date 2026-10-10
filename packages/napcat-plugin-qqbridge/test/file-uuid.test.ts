import { describe, expect, it } from 'vitest';
import { unwrapFileUuid } from '../src/upstream/file-uuid.js';

describe('unwrapFileUuid', () => {
  it('takes the original out of an NTV2COMPAT uuid and leaves ordinary ones alone', () => {
    // 取自一条群视频消息：第一项是原件，第二项（field 2 = 100）是缩略图。
    const wrapped =
      'NTV2COMPAT.CmwIARpmRWhSeHpweGd3XzdyaTN2eUQ2SUNXMWJ4ZXFvSU5CaTg2N0lkSUljTEtPMzdxLUtTcjVjRE1nUndjbTlrVUlEMUpGb1FNenhVdW9CVkVCNXhDbG9OVzNRWnlIb0NsXzJDQVFKbmVnIAIKbAgBEGQaZEVoUlcwd0lSTUJHaHhMZGIwQ3RnS0ViRXl5LV81eGpmdENvZ2lBc28xSld2NHBLdmx3TXlCSEJ5YjJSUWdQVWtXaEM3Q2tfMmhLVm84UTVlY21vTnFMbzJlZ0tBVW9JQkFtZDYgAg';
    expect(unwrapFileUuid(wrapped)).toBe(
      'EhRxzpxgw_7ri3vyD6ICW1bxeqoINBi867IdIIcLKO37q-KSr5cDMgRwcm9kUID1JFoQMzxUuoBVEB5xCloNW3QZyHoCl_2CAQJneg',
    );
    expect(unwrapFileUuid('EhSabc')).toBe('EhSabc');
    expect(unwrapFileUuid('NTV2COMPAT.!!!')).toBe('NTV2COMPAT.!!!');
  });
});
