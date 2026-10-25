/*
 * trimcompat.c —— fnOS 私有 VFS/ACL ABI 的用户态兼容层（LD_PRELOAD）
 *
 * 背景（见 docs/reports/fnos-6.18-kernel-re/USERSPACE-trimafs.md）：
 *   fnOS 1.2.x 的用户态把「ACL 感知的权限判定」放进内核改写的 faccessat：
 *       faccessat(dirfd = -21586 .. -21576, arg1 = 结构体指针, arg2, arg3)
 *   另外 TrimACL 的数据放在 xattr "system.trim_acl"（system.* 命名空间需要
 *   厂商内核注册的 xattr handler，主线/自编译内核返回 EOPNOTSUPP）。
 *
 *   自编译 6.6.54 内核没有这些私有接口，于是：
 *     - libnperm 的 trim_access() 永远失败  -> “User X has no permission of ...”
 *     - libtrimacl 读写 ACL 永远失败        -> 文件管理器/上传服务判权限失败
 *     - trashbind 读 /dev/trim-trashbin 失败 -> trim_trashbind 无限重启
 *
 * 本 shim 在用户态补齐这两类接口：
 *   1) 拦截魔数 faccessat，按 POSIX mode（+POSIX ACL，若存在）判定权限；
 *   2) 把 "system.trim_acl" 重定向到可写的 "user.trim_acl"（值原样搬运）。
 *
 * 编译（板端，aarch64 原生）：
 *     gcc -shared -fPIC -O2 -Wall -o libtrimcompat.so trimcompat.c -ldl -lacl
 * 使用：
 *     LD_PRELOAD=/usr/local/lib/libtrimcompat.so /usr/trim/bin/share_service
 *   或给 systemd 单元加 Environment=LD_PRELOAD=...
 *
 * 调试：设置 TRIMCOMPAT_LOG=/tmp/trimcompat.log 可记录每次魔数调用。
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdarg.h>
#include <dlfcn.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/xattr.h>
#include <dirent.h>
#ifdef HAVE_ACL
#include <sys/acl.h>
#endif
#include <libgen.h>
#include <limits.h>

/* ------------------------------------------------------------------ */
/* 魔数命令（负 dirfd）                                                */
/* ------------------------------------------------------------------ */
#define CMD_CHECK_PERM      0xFFFFABAE   /* -21586 internal_check_perm   */
#define CMD_REALPATH        0xFFFFABAF   /* -21585 trim_realpath         */
#define CMD_SET_EXT_ACCESS  0xFFFFABB0   /* -21584                       */
#define CMD_GET_EXT_ACCESS  0xFFFFABB1   /* -21583                       */
#define CMD_IS_SUPPORT      0xFFFFABB2   /* -21582 is_support_trimacl    */
#define CMD_IS_MOUNTPOINT   0xFFFFABB3   /* -21581 is_mountpoint         */
#define CMD_GET_PERM        0xFFFFABB5   /* -21579 trim_get_perm         */
#define CMD_TO_MODE         0xFFFFABB6   /* -21578 trimacl_to_mode       */
#define CMD_MAY_DELETE      0xFFFFABB7   /* -21577 trim_may_delete       */
#define CMD_GET_FILE_ALL    0xFFFFABB8   /* -21576 __trimacl_get_file_all*/

#define TRIM_ACL_ATTR_SYS   "system.trim_acl"
#define TRIM_ACL_ATTR_USER  "user.trim_acl"

/* 0xFFFFABAE / 0xFFFFABB5 / 0xFFFFABB7 的请求结构（32 字节，见报告 §4.5） */
struct trim_perm_ctx {
    const char *path;       /* +0x00 */
    unsigned    flags;      /* +0x08 */
    unsigned    uid;        /* +0x0C */
    unsigned    ngids;      /* +0x10 */
    const unsigned *gids;   /* +0x18 */
};

/* 0xFFFFABB8 的请求结构（32 字节，见报告 §4.4） */
struct trimacl_getall_ctx {
    const char *path;       /* +0x00 */
    void       *buf;        /* +0x08 */
    size_t      size;       /* +0x10 */
    int         at_fd;      /* +0x18 */
    unsigned    flags;      /* +0x1C */
};

/* 0xFFFFABAF 的请求结构（推断自 trim_realpath 调用约定） */
struct trim_realpath_ctx {
    const char *path;
    char       *out;
    size_t      outlen;
};

/* ------------------------------------------------------------------ */
/* 真实 libc 符号（绕过本 shim，避免递归）                              */
/* ------------------------------------------------------------------ */
typedef int (*f_accessat_t)(int, const char *, int, int);
static f_accessat_t real_faccessat;

static void *next_sym(const char *name)
{
    void *p = dlsym(RTLD_NEXT, name);
    return p;
}

static void logmsg(const char *fmt, ...)
{
    static int fd = -2;
    const char *path = getenv("TRIMCOMPAT_LOG");
    if (!path || !*path)
        return;
    if (fd == -2)
        fd = open(path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0644);
    if (fd < 0)
        return;
    char buf[1024];
    va_list ap;
    va_start(ap, fmt);
    int n = vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    if (n > 0)
        (void)!write(fd, buf, (size_t)n);
}

/* ------------------------------------------------------------------ */
/* 权限计算                                                            */
/* ------------------------------------------------------------------ */
static int uid_in_gids(unsigned uid, unsigned ngids, const unsigned *gids)
{
    for (unsigned i = 0; i < ngids; i++)
        if (gids[i] == uid)
            return 1;
    return 0;
}

/* 返回 rwx 掩码；路径不存在返回 -errno（负值） */
/*
 * TrimACL（fnOS 私有 ACL，存在 user.trim_acl）参与权限判定。
 * 为什么必须解析：应用中心给应用「推荐存储空间权限」写的就是 TrimACL，
 * 如果这里的 trim_access 只按 POSIX mode 判断，就会出现：
 *   - 已允许某个 app 用户（如 uid 995）访问目录，但 trimAccessStat 仍返回无权限
 *     → trim_app_center 日志刷 “trim access stat error: bad file number”；
 *   - 删除/上传等内部权限检查与实际 ACL 不一致。
 *
 * 格式（实测 1.2.0302，小端）：
 *   header: u32 version=1
 *   ACE × n（20 字节）:
 *     +0  u16 tag_and_type : bit0 = allow(1)/deny(0)；bit2..5 = tag
 *                            tag: 1=user 2=group 4=everyone 8=owner
 *     +2  u16 level
 *     +4  u32 permset      : bit0=x bit1=w bit2=r（其余是 p/d/D/a/A/e/E/c/C/o 等厂商位）
 *     +8  u32 inherit      : self|file|dir 等继承位（判定当前对象时不需要）
 *     +12 u32 qualifier    : uid / gid
 *     +16 u32 reserved
 */
#define TRIM_ACL_USER_ATTR "user.trim_acl"

static int trim_acl_perms(const char *path, unsigned uid, unsigned ngids,
                          const unsigned *gids, const struct stat *st,
                          int *out)
{
    unsigned char buf[4096];
    ssize_t n = syscall(SYS_getxattr, path, TRIM_ACL_USER_ATTR, buf, sizeof(buf));
    if (n < 4)
        return 0;
    size_t cnt = ((size_t)n - 4) / 20;
    if (cnt == 0)
        return 0;

    int matched = 0, perms = 0;
    const unsigned char *p = buf + 4;
    for (size_t i = 0; i < cnt; i++, p += 20) {
        uint16_t tt;
        uint32_t ps, q;
        memcpy(&tt, p + 0, sizeof(tt));
        memcpy(&ps, p + 4, sizeof(ps));
        memcpy(&q, p + 12, sizeof(q));
        unsigned tag = (tt >> 2) & 0xf;
        int allow = (tt & 1) != 0;
        int m = 0;
        switch (tag) {
        case 1: m = ((unsigned)q == uid); break;            /* user */
        case 2: m = uid_in_gids((unsigned)q, ngids, gids); break; /* group */
        case 4: m = 1; break;                               /* everyone */
        case 8: m = ((unsigned)st->st_uid == uid); break;   /* owner */
        default: m = 0; break;
        }
        if (!m)
            continue;
        matched = 1;
        unsigned bits = ps & 7u;
        if (allow)
            perms |= (int)bits;
        else
            perms &= ~(int)bits;
    }
    if (!matched)
        return 0;
    *out = perms & 7;
    return 1;
}

static int mode_perms(const char *path, unsigned uid, unsigned ngids,
                      const unsigned *gids)
{
    struct stat st;
    if (lstat(path, &st) < 0)
        return -errno;
    if (uid == 0)
        return 7;
    unsigned m;
    if ((unsigned)st.st_uid == uid)
        m = (unsigned)(st.st_mode >> 6) & 7;
    else if ((unsigned)st.st_gid == uid || uid_in_gids((unsigned)st.st_gid, ngids, gids))
        m = (unsigned)(st.st_mode >> 3) & 7;
    else
        m = (unsigned)st.st_mode & 7;

    /* POSIX ACL（若存在，需 -DHAVE_ACL 且板上有 libacl 头） */
#ifdef HAVE_ACL
    acl_t acl = acl_get_file(path, ACL_TYPE_ACCESS);
    if (acl) {
        acl_entry_t ent;
        acl_tag_t tag;
        acl_permset_t ps;
        int idx = 0;
        for (int r = acl_get_entry(acl, ACL_FIRST_ENTRY, &ent); r == 1;
             r = acl_get_entry(acl, ACL_NEXT_ENTRY, &ent)) {
            (void)idx;
            if (acl_get_tag_type(ent, &tag) != 0)
                break;
            if (acl_get_permset(ent, &ps) != 0)
                break;
            if (tag == ACL_USER) {
                uid_t *q = acl_get_qualifier(ent);
                if (q) {
                    if (*q == uid) {
                        m = 0;
                        if (acl_get_perm(ps, ACL_READ))   m |= 4;
                        if (acl_get_perm(ps, ACL_WRITE))  m |= 2;
                        if (acl_get_perm(ps, ACL_EXECUTE)) m |= 1;
                        acl_free(q);
                        break;
                    }
                    acl_free(q);
                }
            } else if (tag == ACL_GROUP) {
                gid_t *q = acl_get_qualifier(ent);
                if (q) {
                    if (uid_in_gids((unsigned)*q, ngids, gids)) {
                        if (acl_get_perm(ps, ACL_READ) && !(m & 4))   m |= 4;
                        if (acl_get_perm(ps, ACL_WRITE))  m |= 2;
                        if (acl_get_perm(ps, ACL_EXECUTE)) m |= 4 & 0;
                        if (acl_get_perm(ps, ACL_EXECUTE)) m |= 1;
                    }
                    acl_free(q);
                }
            }
        }
        acl_free(acl);
    }
#endif
    /* fnOS TrimACL 优先（应用中心/面板写的权限就是它） */
    {
        int tap;
        if (trim_acl_perms(path, uid, ngids, gids, &st, &tap))
            return tap;
    }
    return (int)m;
}

/* ------------------------------------------------------------------ */
/* 魔数命令实现                                                        */
/* ------------------------------------------------------------------ */
static int do_realpath(struct trim_realpath_ctx *ctx)
{
    if (!ctx || !ctx->path)
        return -EINVAL;
    char resolved[PATH_MAX];
    if (!realpath(ctx->path, resolved))
        return -errno;
    if (!ctx->out || ctx->outlen == 0)
        return -EINVAL;
    size_t n = strlen(resolved);
    if (n + 1 > ctx->outlen)
        return -ENAMETOOLONG;
    memcpy(ctx->out, resolved, n + 1);
    return 0;
}

/* 读出 ACL（用户态 user.trim_acl）；不存在时合成 4 字节空头 */
static ssize_t read_trim_acl(const char *path, int fd, void *buf, size_t size)
{
    char tmp[4] = { 1, 0, 0, 0 };
    ssize_t n;
    if (fd >= 0)
        n = fgetxattr(fd, TRIM_ACL_ATTR_USER, NULL, 0);
    else
        n = getxattr(path, TRIM_ACL_ATTR_USER, NULL, 0);
    if (n < 0) {
        if (buf && size >= sizeof(tmp))
            memcpy(buf, tmp, sizeof(tmp));
        return (ssize_t)sizeof(tmp);
    }
    if (!buf)
        return n;
    if ((size_t)n > size)
        n = (ssize_t)size;
    if (fd >= 0)
        return fgetxattr(fd, TRIM_ACL_ATTR_USER, buf, (size_t)n);
    return getxattr(path, TRIM_ACL_ATTR_USER, buf, (size_t)n);
}

static int do_get_file_all(struct trimacl_getall_ctx *ctx)
{
    if (!ctx)
        return -EINVAL;
    int fd = -1;
    const char *path = ctx->path;
    if (ctx->flags & 0x40000000u) {   /* 第一个参数是 fd */
        fd = ctx->at_fd;
        path = NULL;
    } else if (!path) {
        return -EINVAL;
    }
    ssize_t n = read_trim_acl(path, fd, ctx->buf, ctx->size);
    return (int)n;
}

static int do_may_delete(struct trim_perm_ctx *ctx)
{
    if (!ctx || !ctx->path)
        return -EINVAL;
    char *copy = strdup(ctx->path);
    if (!copy)
        return -ENOMEM;
    char *dir = dirname(copy);
    int mask = mode_perms(dir, ctx->uid, ctx->ngids, ctx->gids);
    int ret = 0;
    if (mask < 0) {
        ret = mask;
    } else if ((mask & 3) != 3) {     /* 需要父目录 w+x */
        ret = -EACCES;
    } else {
        /* sticky bit 规则 */
        struct stat dp, fp;
        if (lstat(dir, &dp) == 0 && lstat(ctx->path, &fp) == 0 &&
            (dp.st_mode & S_ISVTX) && ctx->uid != 0 &&
            (unsigned)dp.st_uid != ctx->uid &&
            (unsigned)fp.st_uid != ctx->uid)
            ret = -EACCES;
    }
    free(copy);
    return ret;
}

/* ------------------------------------------------------------------ */
/* faccessat 拦截                                                      */
/* ------------------------------------------------------------------ */
int faccessat(int dirfd, const char *pathname, int mode, int flags)
{
    if (dirfd > -21576 || dirfd < -21586)
        goto passthrough;                    /* 非魔数（含正常 fd / AT_FDCWD） */

    /* 落在 -21586..-21576 内即私有命令 */
    switch ((unsigned)dirfd) {
    case (unsigned)CMD_CHECK_PERM: {
        struct trim_perm_ctx *ctx = (struct trim_perm_ctx *)(uintptr_t)pathname;
        if (!ctx || !ctx->path)
            return -EINVAL;
        int perm = mode_perms(ctx->path, ctx->uid, ctx->ngids, ctx->gids);
        if (perm < 0) {
            logmsg("check_perm(%s,uid=%u): path err %d\n", ctx->path, ctx->uid, perm);
            return perm;
        }
        int ret = ((perm & mode) == mode) ? 0 : -EACCES;
        logmsg("check_perm(%s,uid=%u,mode=%d): perm=%d ret=%d\n",
               ctx->path, ctx->uid, mode, perm, ret);
        return ret;
    }
    case (unsigned)CMD_GET_PERM: {
        struct trim_perm_ctx *ctx = (struct trim_perm_ctx *)(uintptr_t)pathname;
        if (!ctx || !ctx->path)
            return -EINVAL;
        int perm = mode_perms(ctx->path, ctx->uid, ctx->ngids, ctx->gids);
        logmsg("get_perm(%s,uid=%u): perm=%d\n", ctx->path, ctx->uid, perm);
        return perm;
    }
    case (unsigned)CMD_MAY_DELETE: {
        int ret = do_may_delete((struct trim_perm_ctx *)(uintptr_t)pathname);
        logmsg("may_delete: ret=%d\n", ret);
        return ret;
    }
    case (unsigned)CMD_GET_FILE_ALL:
        return do_get_file_all((struct trimacl_getall_ctx *)(uintptr_t)pathname);
    case (unsigned)CMD_REALPATH:
        return do_realpath((struct trim_realpath_ctx *)(uintptr_t)pathname);
    case (unsigned)CMD_IS_SUPPORT:
        /* 声称支持 TrimACL，让 libtrimacl 走 xattr 路径（已重定向到 user.*） */
        return 1;
    case (unsigned)CMD_IS_MOUNTPOINT: {
        const char *path = pathname;
        struct stat a, b;
        char up[PATH_MAX];
        if (!path || lstat(path, &a) < 0)
            return -EINVAL;
        snprintf(up, sizeof(up), "%s/..", path);
        if (lstat(up, &b) < 0)
            return 0;
        return (a.st_dev != b.st_dev) ? 1 : 0;
    }
    case (unsigned)CMD_TO_MODE: {
        const char *path = pathname;
        struct stat st;
        if (!path || stat(path, &st) < 0)
            return -errno;
        return (int)(st.st_mode & 07777);
    }
    case (unsigned)CMD_GET_EXT_ACCESS:
        return 1;                        /* 允许访问外部磁盘 */
    case (unsigned)CMD_SET_EXT_ACCESS:
        return 0;
    default:
        break;
    }

passthrough:
    if (!real_faccessat)
        real_faccessat = (f_accessat_t)next_sym("faccessat");
    if (real_faccessat)
        return real_faccessat(dirfd, pathname, mode, flags);
    return (int)syscall(SYS_faccessat2, dirfd, pathname, mode, flags);
}

/* ------------------------------------------------------------------ */
/* 魔数 unlinkat：fnOS 回收站/删除 ABI                                  */
/*   unlinkat(dirfd=-7126, path, flags) -> 移入回收站                   */
/*   unlinkat(dirfd=-7125, path, flags) -> 彻底删除                     */
/* 实现见 trash-ref.c（布局/xattr 格式来自板上实测 + 反汇编）              */
/* ------------------------------------------------------------------ */
#define CMD_UNLINK_TRASH    (-7126)     /* 0xFFFFE42A */
#define CMD_UNLINK_PERM     (-7125)     /* 0xFFFFE42B */

int trimcompat_trash_move(const char *path, uid_t uid, int flags);
int trimcompat_rm_force(const char *path, int flags);

/*
 * 「彻底删除」：魔数 unlinkat(-7125) 的语义。
 * 文件直接 unlink；目录递归删除（面板的“彻底删除”不经过回收站）。
 * 返回 0 / 负 errno。
 */
int trimcompat_rm_force(const char *path, int flags)
{
	char full[PATH_MAX];

	(void)flags;
	if (!path || !*path)
		return -EINVAL;
	if (*path == '/')
		snprintf(full, sizeof(full), "%s", path);
	else
		snprintf(full, sizeof(full), "/%s", path);

	struct stat st;
	if (lstat(full, &st) != 0)
		return -errno;

	if (S_ISDIR(st.st_mode)) {
		DIR *d = opendir(full);
		if (!d)
			return -errno;
		struct dirent *de;
		int rc = 0;
		while ((de = readdir(d)) != NULL) {
			if (strcmp(de->d_name, ".") == 0 ||
			    strcmp(de->d_name, "..") == 0)
				continue;
			char child[PATH_MAX];
			snprintf(child, sizeof(child), "%s/%s", full, de->d_name);
			rc = trimcompat_rm_force(child, 0);
			if (rc != 0)
				break;
		}
		closedir(d);
		if (rc != 0)
			return rc;
		if (rmdir(full) != 0)
			return -errno;
		return 0;
	}
	if (unlink(full) != 0)
		return -errno;
	return 0;
}

int unlinkat(int dirfd, const char *pathname, int flags)
{
	static int (*real_unlinkat)(int, const char *, int);

	if (dirfd == CMD_UNLINK_TRASH) {
		int r = trimcompat_trash_move(pathname, (uid_t)-1, flags);
		logmsg("trash_move(%s, flags=%d) -> %d\n", pathname, flags, r);
		if (r == 0)
			return 0;
		errno = -r;
		return -1;
	}
	if (dirfd == CMD_UNLINK_PERM) {
		int r = trimcompat_rm_force(pathname, flags);
		logmsg("rm_force(%s, flags=%d) -> %d\n", pathname, flags, r);
		if (r == 0)
			return 0;
		errno = -r;
		return -1;
	}
	if (!real_unlinkat)
		real_unlinkat = (int (*)(int, const char *, int))next_sym("unlinkat");
	if (real_unlinkat)
		return real_unlinkat(dirfd, pathname, flags);
	return (int)syscall(SYS_unlinkat, dirfd, pathname, flags);
}

/* ------------------------------------------------------------------ */
/* xattr 名字重定向：system.trim_acl -> user.trim_acl                  */
/* ------------------------------------------------------------------ */
static const char *map_name(const char *name)
{
    if (name && strcmp(name, TRIM_ACL_ATTR_SYS) == 0)
        return TRIM_ACL_ATTR_USER;
    return name;
}

#define DEFINE_XATTR_FUNCS(sfx, target_t)                                     \
    ssize_t getxattr##sfx(target_t t, const char *name, void *value,          \
                          size_t size)                                        \
    {                                                                         \
        static ssize_t (*real)(target_t, const char *, void *, size_t);       \
        if (!real) real = (void *)next_sym("getxattr" #sfx);                  \
        return real(t, map_name(name), value, size);                          \
    }                                                                         \
    ssize_t lgetxattr##sfx(target_t t, const char *name, void *value,         \
                           size_t size)                                       \
    {                                                                         \
        static ssize_t (*real)(target_t, const char *, void *, size_t);       \
        if (!real) real = (void *)next_sym("lgetxattr" #sfx);                 \
        return real(t, map_name(name), value, size);                          \
    }                                                                         \
    int setxattr##sfx(target_t t, const char *name, const void *value,        \
                      size_t size, int flags)                                 \
    {                                                                         \
        static int (*real)(target_t, const char *, const void *, size_t, int);\
        if (!real) real = (void *)next_sym("setxattr" #sfx);                  \
        return real(t, map_name(name), value, size, flags);                   \
    }                                                                         \
    int lsetxattr##sfx(target_t t, const char *name, const void *value,       \
                       size_t size, int flags)                                \
    {                                                                         \
        static int (*real)(target_t, const char *, const void *, size_t, int);\
        if (!real) real = (void *)next_sym("lsetxattr" #sfx);                 \
        return real(t, map_name(name), value, size, flags);                   \
    }                                                                         \
    int removexattr##sfx(target_t t, const char *name)                        \
    {                                                                         \
        static int (*real)(target_t, const char *);                           \
        if (!real) real = (void *)next_sym("removexattr" #sfx);               \
        return real(t, map_name(name));                                       \
    }                                                                         \
    int lremovexattr##sfx(target_t t, const char *name)                       \
    {                                                                         \
        static int (*real)(target_t, const char *);                           \
        if (!real) real = (void *)next_sym("lremovexattr" #sfx);              \
        return real(t, map_name(name));                                       \
    }

/* path 版本 */
DEFINE_XATTR_FUNCS(, const char *)

/* fd / path 版本：fgetxattr / fsetxattr / fremovexattr */
ssize_t fgetxattr(int fd, const char *name, void *value, size_t size)
{
    static ssize_t (*real)(int, const char *, void *, size_t);
    if (!real) real = (void *)next_sym("fgetxattr");
    return real(fd, map_name(name), value, size);
}

int fsetxattr(int fd, const char *name, const void *value, size_t size, int flags)
{
    static int (*real)(int, const char *, const void *, size_t, int);
    if (!real) real = (void *)next_sym("fsetxattr");
    return real(fd, map_name(name), value, size, flags);
}

int fremovexattr(int fd, const char *name)
{
    static int (*real)(int, const char *);
    if (!real) real = (void *)next_sym("fremovexattr");
    return real(fd, map_name(name));
}

/* listxattr：把 user.trim_acl 报成 system.trim_acl，避免用户态发现命名空间变化 */
static ssize_t map_list(char *list, ssize_t n)
{
    if (!list || n <= 0)
        return n;
    /* 简单逐条替换（名字变短，直接原地搬移） */
    char *p = list, *end = list + n;
    while (p < end && *p) {
        if (strcmp(p, TRIM_ACL_ATTR_USER) == 0) {
            size_t old = strlen(p) + 1;
            size_t nw = strlen(TRIM_ACL_ATTR_SYS) + 1;
            memmove(p + nw, p + old, (size_t)(end - (p + old)));
            memcpy(p, TRIM_ACL_ATTR_SYS, nw - 1);
            end -= (ssize_t)(old - nw);
            p += nw;
        } else {
            p += strlen(p) + 1;
        }
    }
    return end - list;
}

ssize_t listxattr(const char *path, char *list, size_t size)
{
    static ssize_t (*real)(const char *, char *, size_t);
    if (!real) real = (void *)next_sym("listxattr");
    ssize_t n = real(path, list, size);
    return map_list(list, n);
}

ssize_t llistxattr(const char *path, char *list, size_t size)
{
    static ssize_t (*real)(const char *, char *, size_t);
    if (!real) real = (void *)next_sym("llistxattr");
    ssize_t n = real(path, list, size);
    return map_list(list, n);
}

ssize_t flistxattr(int fd, char *list, size_t size)
{
    static ssize_t (*real)(int, char *, size_t);
    if (!real) real = (void *)next_sym("flistxattr");
    ssize_t n = real(fd, list, size);
    return map_list(list, n);
}
