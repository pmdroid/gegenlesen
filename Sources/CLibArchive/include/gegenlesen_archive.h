#ifndef GEGENLESEN_ARCHIVE_H
#define GEGENLESEN_ARCHIVE_H

#include <stddef.h>
#include <stdint.h>
#include <sys/types.h>

#ifdef __cplusplus
extern "C" {
#endif

#define GEGENLESEN_AE_IFMT 0170000
#define GEGENLESEN_AE_IFREG 0100000
#define GEGENLESEN_AE_IFLNK 0120000
#define GEGENLESEN_AE_IFSOCK 0140000
#define GEGENLESEN_AE_IFCHR 0020000
#define GEGENLESEN_AE_IFBLK 0060000
#define GEGENLESEN_AE_IFDIR 0040000
#define GEGENLESEN_AE_IFIFO 0010000

typedef struct gegenlesen_archive gegenlesen_archive;

gegenlesen_archive *gegenlesen_archive_open(const char *path, int gzip);
void gegenlesen_archive_close(gegenlesen_archive *archive);

/* 1 = header, 0 = EOF, -1 = error */
int gegenlesen_archive_next_header(gegenlesen_archive *archive);

const char *gegenlesen_archive_pathname(gegenlesen_archive *archive);
const char *gegenlesen_archive_symlink(gegenlesen_archive *archive);
const char *gegenlesen_archive_hardlink(gegenlesen_archive *archive);
int64_t gegenlesen_archive_size(gegenlesen_archive *archive);
int gegenlesen_archive_size_is_set(gegenlesen_archive *archive);
int gegenlesen_archive_filetype(gegenlesen_archive *archive);
mode_t gegenlesen_archive_mode(gegenlesen_archive *archive);

/* 1 = block, 0 = end of entry, -1 = error */
int gegenlesen_archive_read_data_block(
    gegenlesen_archive *archive,
    const void **buf,
    size_t *size,
    int64_t *offset
);

const char *gegenlesen_archive_error_string(gegenlesen_archive *archive);

#ifdef __cplusplus
}
#endif

#endif
