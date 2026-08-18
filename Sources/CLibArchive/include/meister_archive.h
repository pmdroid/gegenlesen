#ifndef MEISTER_ARCHIVE_H
#define MEISTER_ARCHIVE_H

#include <stddef.h>
#include <stdint.h>
#include <sys/types.h>

#ifdef __cplusplus
extern "C" {
#endif

#define MEISTER_AE_IFMT 0170000
#define MEISTER_AE_IFREG 0100000
#define MEISTER_AE_IFLNK 0120000
#define MEISTER_AE_IFSOCK 0140000
#define MEISTER_AE_IFCHR 0020000
#define MEISTER_AE_IFBLK 0060000
#define MEISTER_AE_IFDIR 0040000
#define MEISTER_AE_IFIFO 0010000

typedef struct meister_archive meister_archive;

meister_archive *meister_archive_open(const char *path, int gzip);
void meister_archive_close(meister_archive *archive);

/* 1 = header, 0 = EOF, -1 = error */
int meister_archive_next_header(meister_archive *archive);

const char *meister_archive_pathname(meister_archive *archive);
const char *meister_archive_symlink(meister_archive *archive);
const char *meister_archive_hardlink(meister_archive *archive);
int64_t meister_archive_size(meister_archive *archive);
int meister_archive_size_is_set(meister_archive *archive);
int meister_archive_filetype(meister_archive *archive);
mode_t meister_archive_mode(meister_archive *archive);

/* 1 = block, 0 = end of entry, -1 = error */
int meister_archive_read_data_block(
    meister_archive *archive,
    const void **buf,
    size_t *size,
    int64_t *offset
);

const char *meister_archive_error_string(meister_archive *archive);

#ifdef __cplusplus
}
#endif

#endif
