/* 仅修正备份解析进程自己的 SQLite 保留锁字节位置，不修改源文件。 */
#include <sqlite3ext.h>
static const sqlite3_api_routines *qq_api;

static void pending_byte(sqlite3_context *ctx, int argc, sqlite3_value **argv) {
    unsigned int requested = 0;
    if (argc == 1) requested = (unsigned int)qq_api->value_int64(argv[0]);
    if (requested && requested != 0x40000000u && requested != 0x3ffffc00u) {
        qq_api->result_error(ctx, "Only default or QQ 1024-byte-prefix lock offsets are accepted", -1);
        return;
    }
    int old = qq_api->test_control(SQLITE_TESTCTRL_PENDING_BYTE, requested);
    qq_api->result_int64(ctx, (unsigned int)old);
}

int sqlite3_msgpendingbyte_init(sqlite3 *db, char **err, const sqlite3_api_routines *api) {
    (void)err;
    qq_api = api;
    return qq_api->create_function(db, "qq_pending_byte", 1, SQLITE_UTF8, 0, pending_byte, 0, 0);
}
