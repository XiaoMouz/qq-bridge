/* QQ MSG0 使用的小端 corrected Block TEA；仅操作内存，不访问文件。 */
#include <stdint.h>
#include <stddef.h>
#include <stdlib.h>
#define DELTA UINT32_C(0x9e3779b9)
static uint32_t load_le(const uint8_t *p) {
    return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24;
}
static void store_le(uint8_t *p, uint32_t v) {
    p[0] = (uint8_t)v; p[1] = (uint8_t)(v >> 8); p[2] = (uint8_t)(v >> 16); p[3] = (uint8_t)(v >> 24);
}
#define MX (((z >> 5 ^ y << 2) + (y >> 3 ^ z << 4)) ^ ((sum ^ y) + (k[(p & 3) ^ e] ^ z)))
int msg0_xxtea_decrypt(uint8_t *buffer, size_t bytes, const uint8_t *key) {
    if (!buffer || !key || bytes < 8 || bytes % 4 || bytes > 524288) return -1;
    const uint32_t n = (uint32_t)(bytes / 4);
    uint32_t *v = malloc(bytes), k[4], p, y, z, e, sum;
    if (!v) return -2;
    for (p = 0; p < 4; ++p) k[p] = load_le(key + p * 4);
    for (p = 0; p < n; ++p) v[p] = load_le(buffer + p * 4);
    sum = (6 + 52 / n) * DELTA;
    y = v[0];
    while (sum) {
        e = (sum >> 2) & 3;
        for (p = n - 1; p > 0; --p) { z = v[p - 1]; y = v[p] -= MX; }
        z = v[n - 1]; y = v[0] -= MX;
        sum -= DELTA;
    }
    for (p = 0; p < n; ++p) store_le(buffer + p * 4, v[p]);
    /* 使用后清除栈上的额外密钥副本。 */
    volatile uint32_t *wipe = k;
    for (p = 0; p < 4; ++p) wipe[p] = 0;
    free(v);
    return 0;
}
