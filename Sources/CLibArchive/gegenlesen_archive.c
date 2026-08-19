#include "gegenlesen_archive.h"

#include <stdlib.h>

struct archive;
struct archive_entry;

#define ARCHIVE_EOF 1
#define ARCHIVE_OK 0

struct archive *archive_read_new(void);
int archive_read_support_filter_gzip(struct archive *);
int archive_read_support_filter_none(struct archive *);
int archive_read_support_format_tar(struct archive *);
int archive_read_support_format_gnutar(struct archive *);
int archive_read_open_filename(struct archive *, const char *, size_t);
int archive_read_set_options(struct archive *, const char *);
int archive_read_next_header(struct archive *, struct archive_entry **);
int archive_read_data_block(struct archive *, const void **, size_t *, int64_t *);
int archive_read_close(struct archive *);
int archive_read_free(struct archive *);
const char *archive_error_string(struct archive *);

const char *archive_entry_pathname_utf8(struct archive_entry *);
const char *archive_entry_pathname(struct archive_entry *);
const char *archive_entry_symlink_utf8(struct archive_entry *);
const char *archive_entry_symlink(struct archive_entry *);
const char *archive_entry_hardlink_utf8(struct archive_entry *);
const char *archive_entry_hardlink(struct archive_entry *);
int64_t archive_entry_size(struct archive_entry *);
int archive_entry_size_is_set(struct archive_entry *);
unsigned int archive_entry_filetype(struct archive_entry *);
unsigned int archive_entry_mode(struct archive_entry *);

struct gegenlesen_archive {
    struct archive *archive;
    struct archive_entry *entry;
};

gegenlesen_archive *gegenlesen_archive_open(const char *path, int gzip) {
    gegenlesen_archive *handle = calloc(1, sizeof(*handle));
    if (handle == NULL) {
        return NULL;
    }
    handle->archive = archive_read_new();
    if (handle->archive == NULL) {
        free(handle);
        return NULL;
    }
    if (gzip) {
        archive_read_support_filter_gzip(handle->archive);
    } else {
        archive_read_support_filter_none(handle->archive);
    }
    archive_read_support_format_tar(handle->archive);
    archive_read_support_format_gnutar(handle->archive);
    archive_read_set_options(handle->archive, "!mac-ext");
    if (archive_read_open_filename(handle->archive, path, 10240) != ARCHIVE_OK) {
        archive_read_free(handle->archive);
        free(handle);
        return NULL;
    }
    return handle;
}

void gegenlesen_archive_close(gegenlesen_archive *handle) {
    if (handle == NULL) {
        return;
    }
    if (handle->archive != NULL) {
        archive_read_close(handle->archive);
        archive_read_free(handle->archive);
    }
    free(handle);
}

int gegenlesen_archive_next_header(gegenlesen_archive *handle) {
    if (handle == NULL || handle->archive == NULL) {
        return -1;
    }
    int status = archive_read_next_header(handle->archive, &handle->entry);
    if (status == ARCHIVE_OK) {
        return 1;
    }
    if (status == ARCHIVE_EOF) {
        handle->entry = NULL;
        return 0;
    }
    return -1;
}

const char *gegenlesen_archive_pathname(gegenlesen_archive *handle) {
    if (handle == NULL || handle->entry == NULL) {
        return NULL;
    }
    const char *utf8 = archive_entry_pathname_utf8(handle->entry);
    if (utf8 != NULL) {
        return utf8;
    }
    return archive_entry_pathname(handle->entry);
}

const char *gegenlesen_archive_symlink(gegenlesen_archive *handle) {
    if (handle == NULL || handle->entry == NULL) {
        return NULL;
    }
    const char *utf8 = archive_entry_symlink_utf8(handle->entry);
    if (utf8 != NULL) {
        return utf8;
    }
    return archive_entry_symlink(handle->entry);
}

const char *gegenlesen_archive_hardlink(gegenlesen_archive *handle) {
    if (handle == NULL || handle->entry == NULL) {
        return NULL;
    }
    const char *utf8 = archive_entry_hardlink_utf8(handle->entry);
    if (utf8 != NULL) {
        return utf8;
    }
    return archive_entry_hardlink(handle->entry);
}

int64_t gegenlesen_archive_size(gegenlesen_archive *handle) {
    if (handle == NULL || handle->entry == NULL) {
        return 0;
    }
    return archive_entry_size(handle->entry);
}

int gegenlesen_archive_size_is_set(gegenlesen_archive *handle) {
    if (handle == NULL || handle->entry == NULL) {
        return 0;
    }
    return archive_entry_size_is_set(handle->entry);
}

int gegenlesen_archive_filetype(gegenlesen_archive *handle) {
    if (handle == NULL || handle->entry == NULL) {
        return 0;
    }
    unsigned int type = archive_entry_filetype(handle->entry);
    if (type == 0) {
        type = archive_entry_mode(handle->entry) & GEGENLESEN_AE_IFMT;
    }
    return (int)type;
}

mode_t gegenlesen_archive_mode(gegenlesen_archive *handle) {
    if (handle == NULL || handle->entry == NULL) {
        return 0;
    }
    return (mode_t)archive_entry_mode(handle->entry);
}

int gegenlesen_archive_read_data_block(
    gegenlesen_archive *handle,
    const void **buf,
    size_t *size,
    int64_t *offset
) {
    if (handle == NULL || handle->archive == NULL) {
        return -1;
    }
    int status = archive_read_data_block(handle->archive, buf, size, offset);
    if (status == ARCHIVE_OK) {
        return 1;
    }
    if (status == ARCHIVE_EOF) {
        return 0;
    }
    return -1;
}

const char *gegenlesen_archive_error_string(gegenlesen_archive *handle) {
    if (handle == NULL || handle->archive == NULL) {
        return "invalid archive handle";
    }
    const char *message = archive_error_string(handle->archive);
    return message != NULL ? message : "unknown archive error";
}
