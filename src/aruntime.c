/*
 * aruntime - a static, FUSE-less AppImage runtime for armv7.
 *
 * Why this exists: AppImageKit's runtime-armhf is dynamically linked against
 * glibc, so the AppImage itself needs a glibc host - which defeats the point on
 * musl distros and makes it useless on Termux/Android. uruntime has no armv7
 * build and needs FUSE plus user namespaces, which an Android app cannot have.
 *
 * So this runtime does the minimum that works everywhere: it reads the appended
 * squashfs itself, extracts it into a cache directory, and execs AppRun. No
 * FUSE, no mount, no namespaces, no libc beyond the static one it is built with.
 *
 * Scope (deliberate, documented):
 *   - squashfs 4.0, gzip/zlib compressor only
 *   - images built with -no-fragments (tail-block fragments not supported)
 *   - regular files, directories, symlinks
 *
 * Build:
 *   zig cc -target arm-linux-musleabihf -mcpu=cortex_a8-neon -Os -static \
 *       -o aruntime aruntime.c /path/to/libz.a
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <zlib.h>

#define SQ_MAGIC 0x73717368u
#define META_SIZE 8192
#define COMPRESSED_BIT 0x8000
#define COMPRESSED_BIT_BLOCK 0x1000000u
#define NO_FRAGMENT 0xffffffffu

#define T_DIR 1
#define T_FILE 2
#define T_SYMLINK 3
#define T_LDIR 8
#define T_LREG 9
#define T_LSYMLINK 10

static int g_img = -1;
static long long g_base; /* file offset of the squashfs superblock */

static void die(const char *msg) {
	fprintf(stderr, "aruntime: %s: %s\n", msg, strerror(errno));
	exit(1);
}

/* ---- little-endian readers ------------------------------------------- */
static uint16_t rd16(const unsigned char *p) { return (uint16_t)(p[0] | (p[1] << 8)); }
static uint32_t rd32(const unsigned char *p) {
	return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}
static uint64_t rd64(const unsigned char *p) { return (uint64_t)rd32(p) | ((uint64_t)rd32(p + 4) << 32); }

/* ---- metadata block reader ------------------------------------------- */
struct mreader {
	long long table;    /* inode_table_start or directory_table_start */
	long long block;    /* current block offset relative to table */
	unsigned char buf[META_SIZE];
	int len, off;
};

static void mseek(struct mreader *r, long long table, long long block) {
	r->table = table;
	r->block = block;
	r->len = r->off = 0;
}

/* decompress the block at r->block into r->buf */
static void mload(struct mreader *r) {
	unsigned char hdr[2];
	if (lseek(g_img, g_base + r->table + r->block, SEEK_SET) < 0) die("seek meta");
	if (read(g_img, hdr, 2) != 2) die("read meta header");
	uint16_t s = rd16(hdr);
	uint32_t size = s & ~COMPRESSED_BIT;
	if (size == 0) size = META_SIZE;
	unsigned char raw[META_SIZE];
	if (read(g_img, raw, size) != (ssize_t)size) die("read meta block");
	if (s & COMPRESSED_BIT) {
		memcpy(r->buf, raw, size); /* stored uncompressed */
		r->len = (int)size;
	} else {
		uLongf out = META_SIZE;
		if (uncompress(r->buf, &out, raw, size) != Z_OK) die("inflate meta");
		r->len = (int)out;
	}
	r->off = 0;
	r->block += 2 + size;
}

/* read n bytes from the metadata stream, crossing block boundaries */
static void mread(struct mreader *r, void *dst, int n) {
	unsigned char *d = dst;
	while (n > 0) {
		if (r->off >= r->len) mload(r);
		int take = r->len - r->off;
		if (take > n) take = n;
		memcpy(d, r->buf + r->off, take);
		r->off += take;
		d += take;
		n -= take;
	}
}

/* ---- superblock ------------------------------------------------------ */
struct sb {
	uint32_t block_size;
	uint64_t inode_table, dir_table, frag_table, id_table;
	uint64_t bytes_used;
	uint16_t comp;
	int64_t root_inode;
};

static struct sb g_sb;

static void read_sb(void) {
	unsigned char b[96];
	if (lseek(g_img, g_base, SEEK_SET) < 0) die("seek superblock");
	if (read(g_img, b, 96) != 96) die("read superblock");
	if (rd32(b) != SQ_MAGIC) {
		errno = EINVAL;
		die("not a squashfs image");
	}
	g_sb.block_size = rd32(b + 12);
	g_sb.comp = rd16(b + 20);
	g_sb.bytes_used = rd64(b + 40);
	g_sb.id_table = rd64(b + 48);
	g_sb.inode_table = rd64(b + 64);
	g_sb.dir_table = rd64(b + 72);
	g_sb.frag_table = rd64(b + 80);
	g_sb.root_inode = (int64_t)rd64(b + 32);
	if (g_sb.comp != 1) {
		fprintf(stderr, "aruntime: squashfs compressor id %u unsupported (this runtime: gzip/zlib only, build with -comp gzip)\n",
			g_sb.comp);
		exit(1);
	}
}

/* ---- inodes ---------------------------------------------------------- */
struct inode {
	int type;
	uint32_t mode;
	uint64_t size;
	uint64_t start_block;   /* reg/lreg: data start; dir/ldir: dir table block */
	uint32_t fragment, frag_offset;
	uint32_t dir_size, dir_offset;
	int64_t next;           /* ref of next inode in the metadata stream */
};

/* read the inode whose ref is (block<<16 | offset) */
static void read_inode(int64_t ref, struct inode *in) {
	long long block = (ref >> 16) & 0xffffffffLL;
	int offset = (int)(ref & 0xffff);
	struct mreader s;
	mseek(&s, g_sb.inode_table, block);
	s.len = s.off = 0;
	int skip = offset;
	while (skip > 0) {
		if (s.off >= s.len) mload(&s);
		int take = s.len - s.off;
		if (take > skip) take = skip;
		s.off += take;
		skip -= take;
	}
	unsigned char hdr[56];
	memset(hdr, 0, sizeof hdr);
	mread(&s, hdr, 16);
	in->type = rd16(hdr);
	in->mode = rd16(hdr + 2);
	switch (in->type) {
	case T_DIR: {
		unsigned char x[16];
		mread(&s, x, 16);
		in->start_block = rd32(x);
		in->dir_size = rd16(x + 8);
		in->dir_offset = rd16(x + 10);
		break;
	}
	case T_LDIR: {
		unsigned char x[24];
		mread(&s, x, 24);
		in->dir_size = rd32(x + 4);
		in->start_block = rd32(x + 8);
		/* x+12 parent, x+16 icount, x+18 offset, x+20 xattr */
		in->dir_offset = rd16(x + 18);
		break;
	}
	case T_FILE: {
		unsigned char x[16];
		mread(&s, x, 16);
		in->start_block = rd32(x);
		in->fragment = rd32(x + 4);
		in->frag_offset = rd32(x + 8);
		in->size = rd32(x + 12);
		break;
	}
	case T_LREG: {
		unsigned char x[40];
		mread(&s, x, 40);
		in->start_block = rd64(x);
		in->size = rd64(x + 8);
		/* x+16 sparse, x+24 nlink, x+28 fragment, x+32 offset, x+36 xattr */
		in->fragment = rd32(x + 28);
		in->frag_offset = rd32(x + 32);
		break;
	}
	case T_SYMLINK:
	case T_LSYMLINK: {
		unsigned char x[8];
		mread(&s, x, 8);
		in->size = rd32(x + 4); /* nlink then size */
		break;
	}
	default: break;
	}
}

static uint64_t inode_header_len(const struct inode *in) {
	switch (in->type) {
	case T_FILE: return 32;
	case T_LREG: return 56;
	case T_DIR: return 32;
	case T_LDIR: return 40;
	case T_SYMLINK:
	case T_LSYMLINK: return 24;
	default: return 16;
	}
}

/* ---- extraction ------------------------------------------------------ */
static char g_root[4096];

static void mkdirs(const char *path, uint32_t mode);

/* create every parent of path, not path itself */
static void mkparents(const char *path) {
	char tmp[4096];
	snprintf(tmp, sizeof tmp, "%s", path);
	char *slash = strrchr(tmp, '/');
	if (!slash) return;
	*slash = 0;
	mkdirs(tmp, 0755);
}

static void mkdirs(const char *path, uint32_t mode) {
	char tmp[4096];
	snprintf(tmp, sizeof tmp, "%s", path);
	for (char *p = tmp + 1; *p; p++) {
		if (*p == '/') {
			*p = 0;
			mkdir(tmp, 0755);
			*p = '/';
		}
	}
	mkdir(tmp, mode & 07777);
	chmod(tmp, mode & 07777);
}

/* forward decls used by walk() */
static void walk(int64_t ref, const char *rel);

static void extract_regular(int64_t ref, const struct inode *in, const char *path) {
	struct mreader s;
	long long block = (ref >> 16) & 0xffffffffLL;
	int offset = (int)(ref & 0xffff);
	mseek(&s, g_sb.inode_table, block);
	int skip = offset;
	while (skip > 0) {
		if (s.off >= s.len) mload(&s);
		int take = s.len - s.off;
		if (take > skip) take = skip;
		s.off += take;
		skip -= take;
	}

	uint32_t bs = g_sb.block_size;
	uint64_t nblocks = (in->size + bs - 1) / bs;

	/* skip the fixed part of the inode to reach block_list */
	unsigned char pad[56];
	mread(&s, pad, (int)inode_header_len(in));

	uint32_t *sizes = malloc(sizeof(uint32_t) * (nblocks ? nblocks : 1));
	if (!sizes) die("malloc");
	for (uint64_t i = 0; i < nblocks; i++) {
		unsigned char x[4];
		mread(&s, x, 4);
		sizes[i] = rd32(x);
	}

	int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, in->mode & 07777);
	if (fd < 0) die(path);

	unsigned char *cbuf = malloc(bs + 1);
	unsigned char *ubuf = malloc(bs + 1);
	if (!cbuf || !ubuf) die("malloc");

	long long pos = (long long)in->start_block;
	uint64_t remaining = in->size;
	for (uint64_t i = 0; i < nblocks; i++) {
		uint32_t v = sizes[i];
		uint32_t csize = v & ~COMPRESSED_BIT_BLOCK;
		int stored = (v & COMPRESSED_BIT_BLOCK) != 0;
		uint64_t want = remaining < bs ? remaining : bs;
		if (lseek(g_img, g_base + pos, SEEK_SET) < 0) die("seek data");
		if (read(g_img, cbuf, csize) != (ssize_t)csize) die("read data");
		pos += csize;
		if (stored) {
			if (write(fd, cbuf, want) != (ssize_t)want) die("write");
		} else {
			uLongf out = bs;
			if (uncompress(ubuf, &out, cbuf, csize) != Z_OK) die("inflate data");
			if (out < want) want = out;
			if (write(fd, ubuf, want) != (ssize_t)want) die("write");
		}
		remaining -= want;
	}
	close(fd);
	chmod(path, in->mode & 07777);
	free(sizes);
	free(cbuf);
	free(ubuf);
}

static void extract_symlink(int64_t ref, const struct inode *in, const char *path) {
	struct mreader s;
	long long block = (ref >> 16) & 0xffffffffLL;
	int offset = (int)(ref & 0xffff);
	mseek(&s, g_sb.inode_table, block);
	int skip = offset;
	while (skip > 0) {
		if (s.off >= s.len) mload(&s);
		int take = s.len - s.off;
		if (take > skip) take = skip;
		s.off += take;
		skip -= take;
	}
	unsigned char pad[24];
	mread(&s, pad, 24);
	char target[4096];
	size_t tlen = in->size;
	if (tlen >= sizeof target) tlen = sizeof target - 1;
	mread(&s, target, (int)tlen);
	target[tlen] = 0;
	unlink(path);
	if (symlink(target, path) < 0) die(path);
}

static void walk(int64_t ref, const char *rel) {
	struct inode in;
	memset(&in, 0, sizeof in);
	read_inode(ref, &in);

	char path[4096];
	if (rel[0]) snprintf(path, sizeof path, "%s/%s", g_root, rel);
	else snprintf(path, sizeof path, "%s", g_root);

	switch (in.type) {
	case T_DIR:
	case T_LDIR: {
		if (rel[0]) mkdirs(path, in.mode);
		else mkdirs(path, 0755);

		struct mreader s;
		mseek(&s, g_sb.dir_table, (long long)in.start_block);
		int skip = (int)in.dir_offset;
		while (skip > 0) {
			if (s.off >= s.len) mload(&s);
			int take = s.len - s.off;
			if (take > skip) take = skip;
			s.off += take;
			skip -= take;
		}
		/* dir_size is stored +3 (so an empty directory is never 0) */
		long left = (long)in.dir_size - 3;
		while (left > 0) {
			unsigned char dh[12];
			mread(&s, dh, 12);
			left -= 12;
			uint32_t count = rd32(dh);
			uint32_t start_block = rd32(dh + 4);
			for (uint32_t i = 0; i <= count; i++) {
				unsigned char de[8];
				mread(&s, de, 8);
				left -= 8;
				int doff = rd16(de);
				uint16_t namelen = rd16(de + 6);
				char name[257];
				mread(&s, name, namelen + 1);
				left -= namelen + 1;
				name[namelen + 1] = 0;
				int64_t child = ((int64_t)start_block << 16) | (int64_t)doff;
				char crel[4096];
				if (rel[0]) snprintf(crel, sizeof crel, "%s/%s", rel, name);
				else snprintf(crel, sizeof crel, "%s", name);
				walk(child, crel);
			}
		}
		break;
	}
	case T_FILE:
	case T_LREG:
		mkparents(path);
		extract_regular(ref, &in, path);
		break;
	case T_SYMLINK:
	case T_LSYMLINK:
		extract_symlink(ref, &in, path);
		break;
	default:
		break;
	}
}

/* ---- find the appended image ----------------------------------------- */
static int plausible(const unsigned char *b, long long cand, long long filesize) {
	uint32_t block_size = rd32(b + 12);
	uint16_t comp = rd16(b + 20);
	uint16_t major = rd16(b + 28);
	uint64_t used = rd64(b + 40);
	if (major != 4) return 0;
	if (comp < 1 || comp > 6) return 0;
	if (block_size < 4096 || block_size > (1u << 20)) return 0;
	if ((block_size & (block_size - 1)) != 0) return 0; /* power of two */
	if (used < 96) return 0;
	if (cand + (long long)used > filesize) return 0;
	return 1;
}

/* The image is appended, so the *last* plausible superblock wins: the runtime
 * binary itself can contain the magic bytes by accident (zlib did, once). */
static long long find_image(int fd, long long filesize) {
	unsigned char buf[1 << 16];
	long long pos = 0, best = -1;
	while (pos + 96 <= filesize) {
		ssize_t n = pread(fd, buf, sizeof buf, pos);
		if (n < 96) break;
		for (ssize_t i = 0; i + 96 <= n; i++) {
			/* squashfs may start at any byte offset (the runtime's own
			 * size is not necessarily 4-aligned), so no stride here */
			if (buf[i] != 'h' || rd32(buf + i) != SQ_MAGIC) continue;
			long long cand = pos + i;
			if (plausible(buf + i, cand, filesize)) best = cand;
		}
		pos += n - 95;
	}
	return best;
}

int main(int argc, char **argv) {
	char self[4096];
	ssize_t n = readlink("/proc/self/exe", self, sizeof self - 1);
	if (n <= 0) {
		errno = ENOENT;
		die("readlink /proc/self/exe (a /proc mount is required)");
	}
	self[n] = 0;

	g_img = open(self, O_RDONLY);
	if (g_img < 0) die(self);
	struct stat st;
	if (fstat(g_img, &st) < 0) die("fstat");
	g_base = find_image(g_img, st.st_size);
	if (g_base < 0) {
		errno = EINVAL;
		die("no squashfs image appended");
	}
	read_sb();

	/* cache dir: TMPDIR, XDG_RUNTIME_DIR, HOME/.cache, /tmp, cwd - in that
	 * order, because Android has no /tmp and Termux may unset TMPDIR */
	const char *cands[6];
	char c1[4096], c2[4096], c3[4096];
	const char *tmp = getenv("TMPDIR");
	const char *xdg = getenv("XDG_RUNTIME_DIR");
	const char *home = getenv("HOME");
	cands[0] = tmp && *tmp ? tmp : NULL;
	cands[1] = xdg && *xdg ? xdg : NULL;
	if (home && *home) {
		snprintf(c2, sizeof c2, "%s/.cache", home);
		cands[2] = c2;
	} else cands[2] = NULL;
	cands[3] = "/tmp";
	cands[4] = ".";
	cands[5] = NULL;
	(void)c1; (void)c3;

	const char *base = NULL;
	for (int i = 0; cands[i]; i++) {
		if (access(cands[i], W_OK) == 0) { base = cands[i]; break; }
	}
	if (!base) {
		errno = EACCES;
		die("no writable cache directory");
	}

	char stem[256];
	snprintf(stem, sizeof stem, "%s", strrchr(self, '/') ? strrchr(self, '/') + 1 : self);
	char *dot = strstr(stem, ".AppImage");
	if (dot) *dot = 0;
	snprintf(g_root, sizeof g_root, "%s/.aruntime-%s-%llx", base, stem,
		(unsigned long long)(st.st_size ^ (long long)st.st_mtime));

	char marker[4096];
	snprintf(marker, sizeof marker, "%s/.complete", g_root);
	if (access(marker, F_OK) != 0) {
		char cmd[4200];
		snprintf(cmd, sizeof cmd, "rm -rf '%s'", g_root);
		if (system(cmd) != 0) { /* best effort */ }
		mkdirs(g_root, 0755);
		struct inode root;
		memset(&root, 0, sizeof root);
		read_inode(g_sb.root_inode, &root);
		if (root.type != T_DIR && root.type != T_LDIR) {
			errno = EINVAL;
			die("squashfs root is not a directory");
		}
		walk(g_sb.root_inode, "");
		int m = open(marker, O_WRONLY | O_CREAT | O_TRUNC, 0644);
		if (m >= 0) close(m);
	}

	/* export APPDIR the way the AppImage runtime does, so AppRun scripts that
	 * were written for the real thing work unmodified */
	setenv("APPDIR", g_root, 1);
	setenv("ARGV0", self, 0);
	setenv("APPIMAGE", self, 0);
	setenv("OWD", getcwd(NULL, 0) ?: ".", 0);
	setenv("SHARUN_DIR", g_root, 0);

	/* exec AppRun with the caller's arguments */
	char apprun[4096];
	snprintf(apprun, sizeof apprun, "%s/AppRun", g_root);
	char **nargv = calloc(argc + 1, sizeof *nargv);
	if (!nargv) die("calloc");
	nargv[0] = apprun;
	for (int i = 1; i < argc; i++) nargv[i] = argv[i];
	/* exec directly when we can. qemu-user cannot nested-exec, so if exec
	 * fails with ENOEXEC (or ARUNTIME_CHILD=1 is set) fall back to fork+wait,
	 * which is what the runtime does on hosts where exec of the extracted
	 * tree is restricted anyway. */
	if (getenv("ARUNTIME_CHILD")) goto child;
	execv(apprun, nargv);
	if (errno != ENOEXEC) die("execv AppRun");
child:
	fprintf(stderr, "aruntime: running AppRun as a child process\n");
	pid_t pid = fork();
	if (pid < 0) die("fork");
	if (pid == 0) {
		execv(apprun, nargv);
		die("execv AppRun (child)");
	}
	int status = 0;
	if (waitpid(pid, &status, 0) < 0) die("waitpid");
	if (WIFEXITED(status)) return WEXITSTATUS(status);
	return 128 + WTERMSIG(status);
}
