/*
 * trash-ref.c —— fnOS 回收站（trashbin）私有 ABI 的用户态参考实现
 *
 * 目标：被 #include / 合并进 boards/rtd1296-cm360/board-scripts/trim-compat/trimcompat.c，
 *       由 unlinkat(-7126, path, ...) 拦截路径调用，替代厂商内核的“入回收站”语义。
 *
 * 逆向依据（详见 docs/reports/fnos-trashbin-re.md）：
 *   /usr/trim/bin/trashbind   : parse_trash_path 0x21b0 / trashbin_make_parent_dir 0x2460
 *                               / process_packet 0x26b0 / set_trash_record 0x23f0
 *   /usr/trim/bin/filemanager : rm_dir 0xabdc、files_rm 0x13a88（dirfd = -7125 - g_move_to_trashbin）
 *   fnOS 面板 RPC             : file.trash.list / file.trash.restore（参数见报告 §5）
 *
 * 已验证的格式（2026-10-26，板端实测）：
 *   - 回收站根目录（相对 /，fnOS 进程 cwd="/"）：
 *         vol<storid>/<uid>/.@#local/trash                    用户空间
 *         vol<storid>/@team/<teamname>/.@#local/trash         团队空间
 *     根目录 mkdir 模式 0700（root 所有）。
 *   - 条目名 = 原路径去掉 "volN/<uid|@team/name>/" 之后的部分（保留子目录层级！），
 *     因此 /vol1/1000/1111/x.txt -> vol1/1000/.@#local/trash/1111/x.txt。
 *   - 条目所在父目录（trash/1111 等）必须以 0771 创建，并把“原父目录”的
 *     owner/gid/mtime 与 ACL 复制过去（否则面板 file.trash.list 会因为权限拒绝而
 *     errno 4352 —— 实测过，见报告 §5.4）。
 *   - 记录 xattr：名字 "user.trim-trashbin-record"，值是**纯文本**：
 *         "u:<uid>,t:<unix秒>"
 *     （trashbind set_trash_record: sprintf(buf, "u:%u,t:%lu", uid, time(NULL));
 *       filemanager get_trashbin_fileinfo 0x94e0 用 strchr(':')/strchr(',') 解析
 *       单字符 key "u"/"t"，strtol/strtoll 取值。）
 *   - 命名冲突：厂商 rename_self/build_unused_filename 生成 "<主名>_<u64>.<扩展名>"
 *     （字符串 .rodata 0x58f0 "%s_%llu" / 0x58f8 "%s/%s_%llu.%s"）。
 *
 * 编译（板端）：
 *   gcc -D_GNU_SOURCE -DTRASH_REF_TEST -O2 -Wall -o /tmp/trashref trash-ref.c
 *
 * 依赖：仅 libc（xattr 走 syscall(SYS_*)，避免与本 shim 自己的 getxattr 拦截互相递归）。
 * 权限：假定 euid==0（trim 服务本来就是 root）。
 */

#ifndef TRASHCOMPAT_TRASH_REF_C
#define TRASHCOMPAT_TRASH_REF_C

#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <fcntl.h>
#include <stdint.h>
#include <time.h>
#include <dirent.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/xattr.h>
#include <sys/time.h>

#define TRASHCOMPAT_RECORD_ATTR "user.trim-trashbin-record"
#define TRASH_COMPONENT         ".@#local/trash"
#define TRASH_MAX_PATH          4096
#define TRASH_MAX_COMP          256

/* ---------------- 小工具 ---------------- */

static ssize_t tc_raw_getxattr(const char *p, const char *n, void *v, size_t s)
{
#ifdef SYS_getxattr
    return (ssize_t)syscall(SYS_getxattr, p, n, v, s);
#else
    return getxattr(p, n, v, s);
#endif
}

static int tc_raw_setxattr(const char *p, const char *n, const void *v, size_t s)
{
#ifdef SYS_setxattr
    return (int)syscall(SYS_setxattr, p, n, v, s, 0);
#else
    return setxattr(p, n, v, s, 0);
#endif
}

/* 把 src 的 ACL / fnOS 私有 ACL 复制到 dst（尽力而为，全部失败也不致命） */
static void tc_copy_acls(const char *src, const char *dst)
{
    static const char *names[] = {
        "system.posix_acl_access",
        "system.posix_acl_default",
        "user.trim_acl",            /* fnOS TrimACL（本 shim 里 system.trim_acl 的重定向目标） */
        NULL
    };
    char buf[4096];
    for (int i = 0; names[i]; i++) {
        ssize_t n = tc_raw_getxattr(src, names[i], buf, sizeof(buf));
        if (n > 0)
            (void)tc_raw_setxattr(dst, names[i], buf, (size_t)n);
    }
}

/* mkdir -p，mode 逐级应用；已存在且是目录则跳过。返回 0 或 -errno */
static int tc_mkdirs(const char *dir, mode_t mode)
{
    char tmp[TRASH_MAX_PATH];
    size_t len = strlen(dir);
    if (len == 0 || len >= sizeof(tmp))
        return -ENAMETOOLONG;
    memcpy(tmp, dir, len + 1);

    for (size_t i = 1; i <= len; i++) {
        if (tmp[i] != '/' && tmp[i] != '\0')
            continue;
        char save = tmp[i];
        tmp[i] = '\0';
        if (mkdir(tmp, mode) != 0 && errno != EEXIST)
            return -errno;
        tmp[i] = save;
    }
    struct stat st;
    if (stat(dir, &st) != 0)
        return -errno;
    if (!S_ISDIR(st.st_mode))
        return -ENOTDIR;
    return 0;
}

/* 拆出 "<dir>" + "<主名>" + "<扩展名>"；无扩展名时 ext 为空串 */
static void tc_split_name(const char *path, char *dir, size_t dsz,
                          char *main, size_t msz, char *ext, size_t esz)
{
    const char *slash = strrchr(path, '/');
    const char *base = slash ? slash + 1 : path;
    size_t dlen = (size_t)(base - path);
    if (dlen >= dsz) dlen = dsz - 1;
    memcpy(dir, path, dlen);
    dir[dlen] = '\0';
    if (dlen == 0)
        snprintf(dir, dsz, ".");

    const char *dot = strrchr(base, '.');
    if (!dot || dot == base) {                       /* ".bashrc" / "x" -> 无扩展名 */
        snprintf(main, msz, "%s", base);
        ext[0] = '\0';
    } else {
        size_t n = (size_t)(dot - base);
        if (n >= msz) n = msz - 1;
        memcpy(main, base, n);
        main[n] = '\0';
        snprintf(ext, esz, "%s", dot + 1);
    }
}

/* 目标已存在时生成 "<dir>/<main>_<u64>.<ext>"（厂商 build_unused_filename 同款格式） */
static void tc_build_unused(const char *path, char *out, size_t osz, unsigned long long seed)
{
    char dir[TRASH_MAX_PATH], main[TRASH_MAX_COMP], ext[TRASH_MAX_COMP];
    tc_split_name(path, dir, sizeof(dir), main, sizeof(main), ext, sizeof(ext));
    if (ext[0])
        snprintf(out, osz, "%s/%s_%llu.%s", dir, main, seed, ext);
    else
        snprintf(out, osz, "%s/%s_%llu", dir, main, seed);
}

/* 写记录 xattr："u:<uid>,t:<epoch>"（纯文本，厂商同款 sprintf 格式） */
static int tc_set_record(const char *path, uid_t uid)
{
    char val[64];
    int n = snprintf(val, sizeof(val), "u:%u,t:%lu", (unsigned)uid, (unsigned long)time(NULL));
    if (n <= 0)
        return -EINVAL;
    if (tc_raw_setxattr(path, TRASHCOMPAT_RECORD_ATTR, val, (size_t)n) != 0)
        return -errno;
    return 0;
}

/*
 * 目录删除的合并：filemanager 删目录时会「先逐个 trash 里面的文件，再 trash 目录本身」，
 * 于是目录的回收站路径已经被创建成“父目录”，rename 会 ENOTEMPTY/EEXIST。
 * 这时把剩余内容并进已有目录、删掉空壳，面板里就还是一条目录（内容在里面）。
 */
static int tc_merge_dir(const char *src, const char *dst)
{
    DIR *d = opendir(src);
    if (!d)
        return -errno;
    struct dirent *de;
    int rc = 0;
    unsigned long long seed = (unsigned long long)time(NULL) ^ ((unsigned long long)getpid() << 32);
    while ((de = readdir(d)) != NULL) {
        if (strcmp(de->d_name, ".") == 0 || strcmp(de->d_name, "..") == 0)
            continue;
        char sp[TRASH_MAX_PATH], dp[TRASH_MAX_PATH], alt[TRASH_MAX_PATH];
        snprintf(sp, sizeof(sp), "%s/%s", src, de->d_name);
        snprintf(dp, sizeof(dp), "%s/%s", dst, de->d_name);
        if (rename(sp, dp) != 0) {
            if (errno != EEXIST && errno != ENOTEMPTY && errno != ENOTDIR) {
                rc = -errno;
                break;
            }
            tc_build_unused(dp, alt, sizeof(alt), seed++);
            if (rename(sp, alt) != 0) {
                rc = -errno;
                break;
            }
        }
    }
    closedir(d);
    if (rc == 0 && rmdir(src) != 0)
        return -errno;
    return rc;
}

/* ---------------- 路径解析 ---------------- */

/*
 * 把绝对/相对路径拆成回收站相关各部分：
 *   path   : "vol1/1000/1111/x.txt"（可带前导 '/'）
 *   root   : "vol1/1000/.@#local/trash"  或  "vol1/@team/<name>/.@#local/trash"
 *   base   : "vol1/1000"                 或  "vol1/@team/<name>"
 *   rest   : "1111/x.txt"（回收站内的相对路径，即条目名）
 * 返回 0 或 -errno。
 */
static int tc_parse(const char *path, char *root, size_t rsz,
                    char *base, size_t bsz, char *rest, size_t ssz)
{
    const char *p = path;
    while (*p == '/')
        p++;
    if (!*p)
        return -EINVAL;
    if (strstr(p, ".@#local/trash"))                 /* 已经在回收站里 */
        return -EINVAL;

    /* 第 1 段：卷名 volN */
    const char *s1 = strchr(p, '/');
    if (!s1)
        return -EINVAL;                              /* 卷根不能进回收站 */
    size_t vlen = (size_t)(s1 - p);
    if (vlen == 0 || vlen >= 64)
        return -EINVAL;

    /* 第 2 段：uid 目录 或 @team */
    const char *s2 = s1 + 1;
    int team = (strncmp(s2, "@team/", 6) == 0);
    const char *restp;
    size_t b2len;
    if (team) {
        const char *s3 = strchr(s2, '/');            /* @team */
        if (!s3)
            return -EINVAL;
        const char *s4 = strchr(s3 + 1, '/');        /* <teamname> */
        if (!s4)
            return -EINVAL;
        restp = s4 + 1;
        b2len = (size_t)(s4 - s2);                   /* "@team/<teamname>" */
    } else {
        const char *s3 = strchr(s2, '/');
        if (!s3)
            return -EINVAL;
        restp = s3 + 1;
        b2len = (size_t)(s3 - s2);                   /* "1000" */
    }
    if (!*restp)
        return -EINVAL;                              /* 用户根目录本身不能删 */

    int n = snprintf(base, bsz, "%.*s/%.*s", (int)vlen, p, (int)b2len, s2);
    if (n <= 0 || (size_t)n >= bsz)
        return -ENAMETOOLONG;
    n = snprintf(root, rsz, "%s/%s", base, TRASH_COMPONENT);
    if (n <= 0 || (size_t)n >= rsz)
        return -ENAMETOOLONG;
    n = snprintf(rest, ssz, "%s", restp);
    if (n <= 0 || (size_t)n >= ssz)
        return -ENAMETOOLONG;
    return 0;
}

/* ---------------- 主入口 ---------------- */

/*
 * trimcompat_trash_move() —— 把 path 移进 fnOS 回收站（用户态模拟 vendor 内核的
 * unlinkat(dirfd=-7126) 语义）。
 *
 *   path  : 待删除路径，可带或不带前导 '/'（trim 的 cwd 是 "/"，strace 里是相对的）
 *   uid   : 记录进 xattr 的 "u:" 值（删除者 uid；无则传 (uid_t)-1，会退化为 st_uid）
 *   flags : unlinkat 的第三参数（0 = 文件，AT_REMOVEDIR = 目录）；仅用于日志/校验
 *
 * 返回 0 成功；负 errno 失败（调用方应把 -ret 写入 errno）。
 */
int trimcompat_trash_move(const char *path, uid_t uid, int flags)
{
    char root[TRASH_MAX_PATH], base[TRASH_MAX_PATH], rest[TRASH_MAX_PATH];
    char parent[TRASH_MAX_PATH], target[TRASH_MAX_PATH], unused[TRASH_MAX_PATH];
    char srcparent[TRASH_MAX_PATH];
    (void)flags;

    if (!path || !*path)
        return -EINVAL;

    int rc = tc_parse(path, root, sizeof(root), base, sizeof(base), rest, sizeof(rest));
    if (rc != 0)
        return rc;

    const char *src = path;
    while (*src == '/')
        src++;

    struct stat sst;
    if (lstat(src, &sst) != 0)
        return -errno;

    /* 1) 回收站根目录：0700（厂商 mkdirs_prevent_userdir_created(…, 0700, -1, -1)） */
    rc = tc_mkdirs(root, 0700);
    if (rc != 0)
        return rc;

    /* 2) 条目父目录：0771 + 复制原父目录 owner/mtime/ACL */
    snprintf(parent, sizeof(parent), "%s/%s", root, rest);
    char *slash = strrchr(parent, '/');
    if (!slash)
        return -EINVAL;
    *slash = '\0';

    /* 原父目录 = base + "/" + dirname(rest) */
    snprintf(srcparent, sizeof(srcparent), "%s", base);
    {
        char rd[TRASH_MAX_PATH];
        snprintf(rd, sizeof(rd), "%s", rest);
        char *p = strrchr(rd, '/');
        if (p) {                                     /* rest 里有子目录 */
            *p = '\0';
            size_t cur = strlen(srcparent);
            snprintf(srcparent + cur, sizeof(srcparent) - cur, "/%s", rd);
        }
    }

    struct stat pst;
    int have_srcparent = (lstat(srcparent, &pst) == 0);
    rc = tc_mkdirs(parent, 0771);
    if (rc != 0)
        return rc;
    if (have_srcparent) {
        /* 与厂商一致：trash 父目录的属主/时间/ACL 跟随原父目录 */
        if (chown(parent, pst.st_uid, pst.st_gid) != 0 && errno != EPERM)
            return -errno;
        (void)chmod(parent, 0771);
        tc_copy_acls(srcparent, parent);
        struct timespec ts[2] = { pst.st_atim, pst.st_mtim };
        (void)utimensat(AT_FDCWD, parent, ts, 0);
    } else {
        tc_copy_acls(base, parent);
    }

    /* 3) 移动（目标已存在时用厂商同款 "_<u64>" 后缀；目录则合并） */
    snprintf(target, sizeof(target), "%s/%s", root, rest);
    if (rename(src, target) != 0) {
        if (errno != EEXIST && errno != ENOTEMPTY && errno != ENOTDIR)
            return -errno;
        struct stat tst;
        if (S_ISDIR(sst.st_mode) && lstat(target, &tst) == 0 && S_ISDIR(tst.st_mode)) {
            rc = tc_merge_dir(src, target);
            if (rc != 0)
                return rc;
        } else {
            unsigned long long seed = (unsigned long long)time(NULL) ^ ((unsigned long long)getpid() << 32);
            int done = 0;
            for (int i = 0; i < 64; i++) {
                tc_build_unused(target, unused, sizeof(unused), seed + (unsigned long long)i);
                if (rename(src, unused) == 0) {
                    snprintf(target, sizeof(target), "%s", unused);
                    done = 1;
                    break;
                }
                if (errno != EEXIST && errno != ENOTEMPTY && errno != ENOTDIR)
                    return -errno;
            }
            if (!done)
                return -EEXIST;
        }
    }

    /* 4) 写记录 xattr（失败不回滚：文件已经在回收站里了，宁可无记录也别丢文件） */
    if (uid == (uid_t)-1)
        uid = (uid_t)sst.st_uid;
    rc = tc_set_record(target, uid);
    if (rc != 0) {
        fprintf(stderr, "trimcompat_trash_move: setxattr(%s) failed: %s\n",
                target, strerror(-rc));
    }
    return 0;
}

#endif /* TRASHCOMPAT_TRASH_REF_C */

/* ---------------- 板端自测 ---------------- */
#ifdef TRASH_REF_TEST
int main(int argc, char **argv)
{
    if (argc < 2) {
        fprintf(stderr, "usage: %s <path-inside-vol> [uid]\n", argv[0]);
        return 2;
    }
    uid_t uid = (argc > 2) ? (uid_t)strtoul(argv[2], NULL, 10) : (uid_t)-1;
    int rc = trimcompat_trash_move(argv[1], uid, 0);
    if (rc != 0) {
        fprintf(stderr, "FAIL rc=%d (%s)\n", rc, strerror(-rc));
        return 1;
    }
    printf("OK moved %s\n", argv[1]);
    return 0;
}
#endif
