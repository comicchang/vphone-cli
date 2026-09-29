#include "../Shared/InjectionEnvironment.h"
#include "../Shared/RootHideLoaderLinks.h"
#include <fcntl.h>
#include <limits.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

// vphoned installs RootHide under this one name (`roothideRoot`).
#define VP_ROOTHIDE_ROOT "/private/var/containers/Bundle/Application/.jbroot-000114514191980C"

static char vpBootRoot[PATH_MAX];

static void vpLogInjection(const char *event, const char *path, int status) {
    int fd = open("/var/mobile/Library/Caches/vphone-launchdhook-injection.log",
                  O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0644);
    if (fd < 0)
        return;
    dprintf(fd, "%s path=%s status=%d\n", event, path ? path : "<null>", status);
    close(fd);
}

static void vpLogSpawn(const char *event, const char *path, pid_t child, int status) {
    int fd = open("/var/mobile/Library/Caches/vphone-launchdhook-spawn.log",
                  O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0644);
    if (fd < 0)
        return;
    dprintf(fd, "event=%s child=%d path=%s status=%d\n", event, child,
            path ? path : "<null>", status);
    close(fd);
}

static int vpIsAppProgram(const char *path) {
    if (!path || !strstr(path, ".app/"))
        return 0;
    return strncmp(path, "/Applications/", sizeof("/Applications/") - 1) == 0 ||
           strncmp(path, "/var/containers/Bundle/Application/",
                   sizeof("/var/containers/Bundle/Application/") - 1) == 0 ||
           strncmp(path, "/private/var/containers/Bundle/Application/",
                   sizeof("/private/var/containers/Bundle/Application/") - 1) == 0;
}

static int vpIsBootstrapProgram(const char *path) {
    if (!path)
        return 0;
    if (strncmp(path, "/var/jb/", 8) == 0)
        return 1;
    const char *root = vpBootRoot;
    if (strncmp(root, "/private/var/", 13) == 0 && strncmp(path, "/var/", 5) == 0) {
        root += 8; // /private/var/... and /var/... name the same directory.
    }
    size_t length = strlen(root);
    return length && strncmp(path, root, length) == 0 && path[length] == '/';
}

// Neither bootstrap exists on the first boot, and one may be installed while
// launchd runs, so spawns look again until a root appears.
static int vpFindJBRoot(char root[PATH_MAX]) {
    static const char *const roots[] = {"/var/jb", VP_ROOTHIDE_ROOT};
    for (size_t index = 0; index < sizeof(roots) / sizeof(roots[0]); index++) {
        char library[PATH_MAX];
        struct stat info;
        snprintf(library, sizeof(library), "%s/usr/lib", roots[index]);
        if (stat(library, &info) == 0 && S_ISDIR(info.st_mode) && realpath(roots[index], root))
            return 1;
    }
    root[0] = '\0';
    return 0;
}

typedef int (*VPSpawnFunction)(pid_t *restrict, const char *restrict, const posix_spawn_file_actions_t *restrict,
                               const posix_spawnattr_t *restrict, char *const[restrict], char *const[restrict]);

static int vpSpawnWith(VPSpawnFunction spawn, pid_t *restrict pid, const char *restrict path,
                       const posix_spawn_file_actions_t *restrict actions, const posix_spawnattr_t *restrict attributes,
                       char *const argv[restrict], char *const envp[restrict]) {
    if (!vpBootRoot[0] && vpFindJBRoot(vpBootRoot))
        vpLogInjection("bootstrap-root", vpBootRoot, 0);
    int bootstrapProgram = vpIsBootstrapProgram(path);
    int appProgram = vpIsAppProgram(path);
    if (bootstrapProgram || appProgram) {
        int linkStatus = vpEnsureRootHideLoaderLink(path, vpBootRoot);
        if (linkStatus || (path && strstr(path, "/.jbroot-")))
            vpLogInjection("loader-link", path, linkStatus);
    }
    // Every process chain-loads SystemHook, including one started with tweaks
    // disabled: SystemHook itself honors DISABLE_TWEAKS and safe mode by not
    // loading ElleKit. Only launchd re-executing itself is left alone.
    if (!path || strcmp(path, "/sbin/launchd") == 0)
        return spawn(pid, path, actions, attributes, argv, envp);
    VPInjectionEnvironment injected = vpInsertHook(envp, vpBootRoot);
    int status = spawn(pid, path, actions, attributes, argv, injected.values ? injected.values : envp);
    if (bootstrapProgram || appProgram || strcmp(path, "/usr/libexec/xpcproxy") == 0) {
        const char *event = !injected.values ? "unchanged" :
                            vpInjectionDisabled(envp) ? "inserted-tweaks-disabled" : "inserted";
        vpLogInjection(event, path, status);
        vpLogSpawn(event, path, status == 0 && pid ? *pid : -1, status);
    }
    vpFreeEnvironment(&injected);
    return status;
}

static int vpSpawn(pid_t *restrict pid, const char *restrict path, const posix_spawn_file_actions_t *restrict actions,
                   const posix_spawnattr_t *restrict attributes, char *const argv[restrict],
                   char *const envp[restrict]) {
    return vpSpawnWith(posix_spawn, pid, path, actions, attributes, argv, envp);
}

// launchd starts jobs through posix_spawnp: xpcproxy, and each bootstrap
// LaunchDaemon such as sshd or ighostvtd when it elides the proxy. Without
// this none of them gets SystemHook.
static int vpSpawnP(pid_t *restrict pid, const char *restrict path, const posix_spawn_file_actions_t *restrict actions,
                    const posix_spawnattr_t *restrict attributes, char *const argv[restrict],
                    char *const envp[restrict]) {
    return vpSpawnWith(posix_spawnp, pid, path, actions, attributes, argv, envp);
}

// The bootstrap's LaunchDaemons are not imported here: vphoned loads them
// after boot under their own paths, as RootHide's jbctl does.
extern int memorystatus_control(uint32_t, int32_t, uint32_t, void *, size_t);

enum { VPSetJetsamHighWaterMark = 5, VPSetJetsamTaskLimit = 6 };

static int vpMemoryStatus(uint32_t command, int32_t pid, uint32_t flags, void *buffer, size_t size) {
    if (getpid() == 1 && command == VPSetJetsamTaskLimit && (pid == 1 || pid == 0)) {
        return 0;
    }
    return memorystatus_control(command, pid, flags, buffer, size);
}

__attribute__((constructor)) static void vpLaunchHookInit(void) {
    if (getpid() != 1)
        return;
    // The firmware panic-guard patch does not remove a limit already on PID 1.
    memorystatus_control(VPSetJetsamTaskLimit, 1, (uint32_t)-1, NULL, 0);
    memorystatus_control(VPSetJetsamHighWaterMark, 1, (uint32_t)-1, NULL, 0);
}

// This image is loaded by launchd's LC_LOAD_WEAK_DYLIB. Interposing spawn here
// keeps the injection chain available before ElleKit is installed. SystemHook
// owns xpcproxy's exec and loads ElleKit's TweakLoader when it appears.
__attribute__((used, section("__DATA,__interpose"))) static const struct {
    const void *replacement;
    const void *replacee;
} vpInterpose[] = {
    {(const void *)vpSpawn, (const void *)posix_spawn},
    {(const void *)vpSpawnP, (const void *)posix_spawnp},
    {(const void *)vpMemoryStatus, (const void *)memorystatus_control},
};
