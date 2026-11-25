// Plugin renderer launcher for Linux (port of src/platform/macos_plugin.m).
//
// Owns exactly the three C entry points declared for Zig in
// src/platform/bridge.zig (launchPluginRender + pollPluginCompletions +
// pluginOutcomeFor) plus their static helpers and tables — nothing else.
// Included at the end of linux.c (single TU, same -Oz outliner discipline
// as macos.m; a stub twin is swapped in by the build when the twin select
// is on). Cocoa/process specifics are replaced with POSIX: posix_spawnp
// (via <spawn.h>), waitpid/WNOHANG, environ inheritance through <unistd.h>.
// Model, table sizes, and return contract (1 active / 0 queued / -1
// failed) are unchanged: main-loop reap, no threads/locks/atomics/timers,
// static 8-slot in-flight table, 16-entry outcome ring, srcfile ownership
// passes at launch and ends at reap (unlinked at terminal states).
#ifndef _POSIX_C_SOURCE
#define _POSIX_C_SOURCE 200809L
#endif
#ifndef _DEFAULT_SOURCE
#define _DEFAULT_SOURCE
#endif
#include <spawn.h> // posix_spawnp: no threads/timers
#include <sys/wait.h> // waitpid/WNOHANG/WIFEXITED for the reap drain
#include <sys/stat.h> // outfile validation (exists + nonzero + mtime)
#include <time.h> // start stamp for the mtime check
#include <unistd.h> // access/unlink/environ
#include <fcntl.h> // O_WRONLY for the quiet-spawn redirections
#include <stdio.h> // fprintf/stderr
#include <string.h> // strcmp/strlen/memcpy

#ifndef PLUGIN_MAX_INFLIGHT
#define PLUGIN_MAX_INFLIGHT 8
#endif
static pid_t plugin_pid[PLUGIN_MAX_INFLIGHT] = { 0 };
static time_t plugin_start[PLUGIN_MAX_INFLIGHT] = { 0 };
static char plugin_src[PLUGIN_MAX_INFLIGHT][512];
static char plugin_out[PLUGIN_MAX_INFLIGHT][512];

// Per-job outcome history: the reap frees the slot, so the exit-status
// dimension would be unrecoverable from the drain count alone; each reap
// records (outfile, ok) here for later query by outfile path.
// Non-consuming ring, last 16 outcomes retained. Empty slot =
// outfile[0] == 0 (BSS zero-init).
#define PLUGIN_HIST 16
static char plugin_hist_out[PLUGIN_HIST][512];
static char plugin_hist_ok[PLUGIN_HIST];
static int plugin_hist_pos = 0;

// Bounded "%s" copy without the format machinery.
static void plugin_copy512(char dst[512], const char* src) {
    size_t n = strlen(src);
    if (n > 511) n = 511;
    memcpy(dst, src, n);
    dst[n] = '\0';
}
static void plugin_hist_record(const char* outfile, int ok) {
    plugin_copy512(plugin_hist_out[plugin_hist_pos], outfile);
    plugin_hist_ok[plugin_hist_pos] = (char)ok;
    plugin_hist_pos = (plugin_hist_pos + 1) % PLUGIN_HIST;
}

// Outcome query: 1 clean render (exit 0 + outfile validated), 0 renderer
// failed (nonzero exit or bad outfile), -1 no record.
int pluginOutcomeFor(const char* outfile) {
    if (!outfile || !*outfile) return -1;
    for (int i = 0; i < PLUGIN_HIST; i++)
        if (strcmp(plugin_hist_out[i], outfile) == 0)
            return plugin_hist_ok[i];
    return -1;
}

// Quiet spawn: children inherit neither our stdout nor our stderr (both
// to /dev/null). Returns the posix_spawnp status.
extern char** environ;
static int plugin_spawnq(const char* file, char* const argv[], pid_t* pid) {
    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    for (int fd = 1; fd <= 2; fd++)
        posix_spawn_file_actions_addopen(&actions, fd, "/dev/null", O_WRONLY, 0);
    int rc = posix_spawnp(pid, file, &actions, NULL, argv, environ);
    posix_spawn_file_actions_destroy(&actions);
    return rc;
}

// Non-blocking launch of `renderer srcfile outfile`. Returns 1 active
// (slot spent), 0 queued (table full: silent, the cache retries later),
// -1 failed (bad args, unresolvable or unlaunchable binary: no slot
// spent). Never waits, never dialogs; errors go to stderr only.
int launchPluginRender(const char* renderer, const char* srcfile, const char* outfile) {
    if (!renderer || !*renderer || !srcfile || !*srcfile || !outfile || !*outfile) return -1;
    if (strlen(srcfile) >= 512 || strlen(outfile) >= 512) {
        (void)write(STDERR_FILENO, "read: plugin render path too long\n", sizeof("read: plugin render path too long\n") - 1);
        return -1;
    }
    int slot = -1;
    for (int i = 0; i < PLUGIN_MAX_INFLIGHT; i++)
        if (plugin_pid[i] <= 0) { slot = i; break; }
    if (slot < 0) return 0;
    time_t start = time(NULL);
    char* const argv[] = { (char*)renderer, (char*)srcfile, (char*)outfile, NULL };
    pid_t pid = 0;
    if (plugin_spawnq(renderer, argv, &pid) != 0) {
        fprintf(stderr, "read: plugin render launch failed: %s\n", renderer);
        return -1;
    }
    plugin_pid[slot] = pid;
    plugin_start[slot] = start;
    plugin_copy512(plugin_src[slot], srcfile);
    plugin_copy512(plugin_out[slot], outfile);
    return 1;
}

// Main-loop drain: reap exited children without blocking, validate each
// outfile, record the per-job outcome, unlink the staged srcfile, free
// the slot. Per-slot waitpid(pid, WNOHANG) only — never waitpid(-1).
// Returns completions drained. Touches no Viewport/cache/UI state.
int pollPluginCompletions(void) {
    int drained = 0;
    for (int i = 0; i < PLUGIN_MAX_INFLIGHT; i++) {
        if (plugin_pid[i] <= 0) continue;
        int status = 0;
        pid_t pid = waitpid(plugin_pid[i], &status, WNOHANG);
        if (pid <= 0) continue;
        struct stat st;
        int ok = WIFEXITED(status) && WEXITSTATUS(status) == 0 &&
            stat(plugin_out[i], &st) == 0 && (long long)st.st_size > 0 &&
            st.st_mtime >= plugin_start[i];
        if (!ok) fprintf(stderr, "read: plugin render failed pid=%d out=%s\n", (int)pid, plugin_out[i]);
        plugin_hist_record(plugin_out[i], ok);
        plugin_pid[i] = 0;
        drained++;
        unlink(plugin_src[i]);
    }
    return drained;
}

#ifdef TEST_HOOKS
// Headless probe: in-flight render child count.
int platform_test_plugin_active(void) {
    int n = 0;
    for (int i = 0; i < PLUGIN_MAX_INFLIGHT; i++) if (plugin_pid[i] > 0) n++;
    return n;
}
#endif
