/*
 * trim-access-test.c —— 兼容层自检：直接调用 fnOS 的 trim_access()
 *
 * 用法：./trim-access-test <uid> <path> [mode]
 *   mode: 4=读 2=写 1=执行（默认 4）
 * 未装兼容层时返回 -1/errno=9(EBADF)；装了之后应返回 0（有权限）。
 *
 * 编译：gcc -o trim-access-test trim-access-test.c -L/usr/trim/lib -lnperm
 * 运行：LD_LIBRARY_PATH=/usr/trim/lib LD_PRELOAD=/usr/local/lib/libtrimcompat.so ./trim-access-test 1000 /vol1
 */
#include <stdio.h>
#include <stdlib.h>
#include <errno.h>

extern int trim_access(unsigned int uid, const char *path, int mode, int unused, int flag);

int main(int argc, char **argv)
{
	if (argc < 3) {
		fprintf(stderr, "usage: %s <uid> <path> [mode:4/2/1]\n", argv[0]);
		return 2;
	}
	unsigned uid = (unsigned)strtoul(argv[1], NULL, 10);
	const char *path = argv[2];
	int mode = argc > 3 ? atoi(argv[3]) : 4;

	errno = 0;
	int r = trim_access(uid, path, mode, 0, 0);
	printf("trim_access(uid=%u, path=%s, mode=%d) = %d (errno=%d)\n",
	       uid, path, mode, r, errno);
	return r == 0 ? 0 : 1;
}
