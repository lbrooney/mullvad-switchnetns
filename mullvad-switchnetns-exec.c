// SPDX-License-Identifier: GPL-2.0+
/*
 * mullvad-switchnetns-exec - run a command in a namespace brought up by mullvad-switchnetns
 *
 * This lets unprivileged users enter the namespaces in the same way as
 * switch-netns (https://github.com/USSURATONCACHI/switch-netns): it is
 * installed with the cap_sys_admin file capability, joins the network
 * namespace with setns(2) and executes the command with all privileges
 * dropped.
 *
 * It also does what `ip netns exec` does: it creates a private mount namespace
 * with the namespace's resolv.conf and nsswitch.conf bind mounted over the ones
 * in /etc. Without that, name lookups go to the resolver configured outside of
 * the namespace, which escapes the tunnel when it is reached through a unix
 * socket (systemd-resolved, nscd, avahi). If those files can't be applied, the
 * command is not run.
 *
 * Only namespaces brought up by mullvad-switchnetns can be entered.
 */

#define _GNU_SOURCE
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <linux/capability.h>
#include <sched.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/prctl.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <unistd.h>

/* these must match the paths used by mullvad-switchnetns */
#ifndef NETNS_RUN_DIR
#define NETNS_RUN_DIR "/run/netns"
#endif
#ifndef STATE_DIR
#define STATE_DIR "/run/mullvad-switchnetns"
#endif

#define NAME_MAX_LENGTH 64

/* exit statuses as used by env(1), chroot(1) and the like */
#define EXIT_CANCELED 125
#define EXIT_CANNOT_INVOKE 126
#define EXIT_ENOENT 127

static const char *progname = "mullvad-switchnetns-exec";

static void usage(FILE *out)
{
	fprintf(out, "Usage: %s <name> [--] <command> [args...]\n\n"
		"Run <command> as the current user in the mullvad-switchnetns namespace <name>.\n",
		progname);
}

static void __attribute__((noreturn, format(printf, 1, 2))) die(const char *format, ...)
{
	va_list ap;

	fprintf(stderr, "%s: ", progname);
	va_start(ap, format);
	vfprintf(stderr, format, ap);
	va_end(ap);
	fputc('\n', stderr);
	exit(EXIT_CANCELED);
}

static void __attribute__((format(printf, 3, 4))) format_path(char *buf, size_t size, const char *format, ...)
{
	va_list ap;
	int len;

	va_start(ap, format);
	len = vsnprintf(buf, size, format, ap);
	va_end(ap);

	if (len < 0 || (size_t)len >= size)
		die("path too long");
}

/*
 * Same rules as valid_name() in mullvad-switchnetns. The name is used to build paths
 * while holding cap_sys_admin, so this is what keeps them inside their
 * directories.
 */
static bool valid_name(const char *name)
{
	size_t len = strlen(name);

	if (len == 0 || len > NAME_MAX_LENGTH || name[0] == '.' || name[0] == '-')
		return false;

	for (const char *c = name; *c; c++) {
		if (!((*c >= 'a' && *c <= 'z') || (*c >= 'A' && *c <= 'Z') ||
		      (*c >= '0' && *c <= '9') || *c == '_' || *c == '.' || *c == '-'))
			return false;
	}

	return true;
}

static void check_managed(const char *name)
{
	char path[PATH_MAX];
	struct stat st;

	format_path(path, sizeof(path), STATE_DIR "/%s", name);
	if (lstat(path, &st) != 0 || !S_ISDIR(st.st_mode) || st.st_uid != 0)
		die("\"%s\" is not a namespace brought up by mullvad-switchnetns", name);
}

static void join_netns(const char *name)
{
	char path[PATH_MAX];
	int fd;

	format_path(path, sizeof(path), NETNS_RUN_DIR "/%s", name);
	fd = open(path, O_RDONLY | O_CLOEXEC);
	if (fd < 0)
		die("cannot open network namespace \"%s\": %s", path, strerror(errno));

	if (setns(fd, CLONE_NEWNET) != 0) {
		int err = errno;
		char exe[PATH_MAX];
		ssize_t len;

		if (err != EPERM)
			die("cannot enter network namespace \"%s\": %s", name, strerror(err));

		len = readlink("/proc/self/exe", exe, sizeof(exe) - 1);
		exe[len < 0 ? 0 : len] = '\0';
		die("cannot enter network namespace \"%s\": %s\n"
		    "%s needs the cap_sys_admin file capability (which has no effect on\n"
		    "filesystems mounted nosuid), as root run:\n"
		    "  setcap cap_sys_admin=ep %s",
		    name, strerror(err), progname, len < 0 ? progname : exe);
	}

	close(fd);
}

/* bind mount the files in STATE_DIR/<name>/etc over the ones in /etc */
static void bind_etc(const char *name)
{
	char dir[PATH_MAX];
	struct stat st;
	struct dirent *entry;
	DIR *d;
	int fd;

	format_path(dir, sizeof(dir), STATE_DIR "/%s/etc", name);
	fd = open(dir, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
	if (fd < 0)
		die("cannot open \"%s\": %s", dir, strerror(errno));
	if (fstat(fd, &st) != 0)
		die("cannot stat \"%s\": %s", dir, strerror(errno));
	if (st.st_uid != 0 || (st.st_mode & (S_IWGRP | S_IWOTH)))
		die("\"%s\" must be owned by root and not writable by group or other", dir);
	d = fdopendir(fd);
	if (!d)
		die("cannot open \"%s\": %s", dir, strerror(errno));

	if (unshare(CLONE_NEWNS) != 0)
		die("cannot create mount namespace: %s", strerror(errno));

	/* keep the bind mounts from propagating back out of the new namespace */
	if (mount("", "/", NULL, MS_SLAVE | MS_REC, NULL) != 0)
		die("cannot make mounts private: %s", strerror(errno));

	errno = 0;
	while ((entry = readdir(d))) {
		char src[PATH_MAX], dst[PATH_MAX];

		if (!strcmp(entry->d_name, ".") || !strcmp(entry->d_name, ".."))
			continue;

		format_path(src, sizeof(src), "%s/%s", dir, entry->d_name);
		format_path(dst, sizeof(dst), "/etc/%s", entry->d_name);

		/* nothing to override, e.g. resolv.conf linked to a resolver that isn't running */
		if (stat(dst, &st) != 0 && errno == ENOENT) {
			errno = 0;
			continue;
		}

		if (mount(src, dst, NULL, MS_BIND, NULL) != 0)
			die("cannot bind mount \"%s\" over \"%s\": %s", src, dst, strerror(errno));
		errno = 0;
	}
	if (errno)
		die("cannot read \"%s\": %s", dir, strerror(errno));

	closedir(d);
}

static void drop_privileges(void)
{
	uid_t uid = getuid();
	gid_t gid = getgid();

	/* in case this was installed set-user-ID root instead */
	if (setresgid(gid, gid, gid) != 0 || setresuid(uid, uid, uid) != 0)
		die("cannot drop privileges: %s", strerror(errno));

	/* like with `ip netns exec`, root keeps its capabilities */
	if (uid == 0)
		return;

	/*
	 * Executing the command would clear the capabilities anyway, clearing them
	 * explicitly makes sure none can be inherited.
	 */
	struct __user_cap_header_struct header = { .version = _LINUX_CAPABILITY_VERSION_3 };
	struct __user_cap_data_struct data[_LINUX_CAPABILITY_U32S_3] = { 0 };

	if (syscall(SYS_capset, &header, data) != 0)
		die("cannot drop capabilities: %s", strerror(errno));

	/*
	 * Gaining privileges made this undumpable, which makes /proc/self owned by
	 * root. With nothing left to protect, undo that as executing the command
	 * would, so original_environ() can read /proc/self/environ.
	 */
	if (prctl(PR_SET_DUMPABLE, 1) != 0)
		die("cannot make process dumpable: %s", strerror(errno));
}

/*
 * As this gains privileges when it is executed, the C library removed variables
 * like LD_LIBRARY_PATH and TMPDIR from its environment. Only once privileges are
 * dropped, get back the environment it was executed with (which /proc still
 * has), so that the command runs with the environment it was given.
 */
static char **original_environ(void)
{
	size_t len = 0, size = 0, count = 0;
	char *buf = NULL, **env;
	ssize_t n;
	int fd;

	fd = open("/proc/self/environ", O_RDONLY | O_CLOEXEC);
	if (fd < 0)
		return environ;

	do {
		if (len == size) {
			size = size ? size * 2 : 4096;
			buf = realloc(buf, size + 1);
			if (!buf)
				die("out of memory");
		}
		n = read(fd, buf + len, size - len);
		if (n < 0 && errno != EINTR)
			die("cannot read the environment: %s", strerror(errno));
		if (n > 0)
			len += n;
	} while (n != 0);
	close(fd);
	buf[len] = '\0';

	for (size_t i = 0; i <= len; i++) {
		if (buf[i] == '\0')
			count++;
	}

	env = calloc(count + 1, sizeof(*env));
	if (!env)
		die("out of memory");
	count = 0;
	for (char *var = buf; var < buf + len; var += strlen(var) + 1)
		env[count++] = var;

	return env;
}

int main(int argc, char *argv[])
{
	const char *name;
	int cmd = 2;

	if (argc > 1 && (!strcmp(argv[1], "-h") || !strcmp(argv[1], "--help"))) {
		usage(stdout);
		return EXIT_SUCCESS;
	}

	if (argc > cmd && !strcmp(argv[cmd], "--"))
		cmd++;
	if (argc <= cmd) {
		usage(stderr);
		return EXIT_CANCELED;
	}

	name = argv[1];
	if (!valid_name(name))
		die("invalid namespace name \"%s\"", name);

	check_managed(name);
	join_netns(name);
	bind_etc(name);
	drop_privileges();

	execvpe(argv[cmd], &argv[cmd], original_environ());

	int err = errno;
	fprintf(stderr, "%s: cannot execute \"%s\": %s\n", progname, argv[cmd], strerror(err));
	return err == ENOENT ? EXIT_ENOENT : EXIT_CANNOT_INVOKE;
}
