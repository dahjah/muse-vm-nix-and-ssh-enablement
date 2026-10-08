/* xattr-retry: LD_PRELOAD shim that makes llistxattr/listxattr
 * robust against the host's asynchronous taint-marking.
 *
 * The host stamps new files with user.hatch_tainted* markers one
 * by one. Nix lists a file's attributes by probing the list size
 * and then reading into a buffer of exactly that size; a marker
 * landing between the two calls overflows the buffer (ERANGE)
 * and Nix aborts. The full marker family totals 61 bytes, so
 * this shim pads every size probe by 256 bytes: the caller
 * allocates a buffer with room for markers that have not landed
 * yet, and its read then succeeds no matter when they land.
 * Reads that still fail with ERANGE (a caller using its own
 * fixed buffer) are retried after the list size stabilizes.
 *
 * The fast path costs one addition; there is no sleeping unless
 * a read has already failed.
 */
#define _GNU_SOURCE
#include <sys/xattr.h>
#include <dlfcn.h>
#include <errno.h>
#include <stdlib.h>
#include <time.h>
#include <fcntl.h>
#include <unistd.h>
#include <string.h>

#define SLACK 256

typedef ssize_t (*list_fn)(const char *, char *, size_t);

static void msleep(long ms) {
    struct timespec ts = { ms / 1000, (ms % 1000) * 1000000L };
    nanosleep(&ts, NULL);
}

static list_fn real_llist(void) {
    static list_fn fn = NULL;
    if (!fn) fn = (list_fn) dlsym(RTLD_NEXT, "llistxattr");
    return fn;
}

static list_fn real_list(void) {
    static list_fn fn = NULL;
    if (!fn) fn = (list_fn) dlsym(RTLD_NEXT, "listxattr");
    return fn;
}

static void debug_log(const char *what, const char *path) {
    if (!getenv("XATTR_RETRY_DEBUG")) return;
    int fd = open("/tmp/xattr-retry.log", O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd < 0) return;
    char buf[1024];
    int n = 0;
    const char *parts[4] = { what, " ", path, "\n" };
    for (int i = 0; i < 4; i++) {
        size_t len = strlen(parts[i]);
        if (n + (int)len >= (int)sizeof(buf)) break;
        memcpy(buf + n, parts[i], len);
        n += (int)len;
    }
    ssize_t w = write(fd, buf, n);
    (void)w;
    close(fd);
}

static ssize_t do_list(list_fn real, const char *name,
                       const char *path, char *list, size_t size) {
    debug_log(name, path);
    if (!real) { errno = ENOSYS; return -1; }
    if (list == NULL || size == 0) {
        ssize_t r = real(path, NULL, 0);
        return r < 0 ? r : r + SLACK;
    }
    ssize_t r = real(path, list, size);
    for (int i = 0; i < 150 && r < 0 && errno == ERANGE; i++) {
        msleep(100);
        ssize_t a = real(path, NULL, 0);
        msleep(100);
        ssize_t b = real(path, NULL, 0);
        if (a >= 0 && a == b && a <= (ssize_t) size)
            r = real(path, list, size);
    }
    return r;
}

ssize_t llistxattr(const char *path, char *list, size_t size) {
    return do_list(real_llist(), "llistxattr", path, list, size);
}

ssize_t listxattr(const char *path, char *list, size_t size) {
    return do_list(real_list(), "listxattr", path, list, size);
}
