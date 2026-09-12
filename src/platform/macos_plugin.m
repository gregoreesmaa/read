// Plugin renderer launcher source (issue #323; split from src/platform/macos.m
// for the AGENTS.md §7 differential-twin size gate). Owns exactly the three
// C entry points declared for Zig in src/platform/bridge.zig
// (launchPluginRender + pollPluginCompletions + pluginOutcomeFor) plus their
// static helpers and tables — nothing else. Included at the end of macos.m
// (single TU, so the -Oz outliner keeps ship __TEXT byte-identical); the
// stub twin includes macos_plugin_stub.m instead (same TU, same flags).
#include <spawn.h> // posix_spawnp: no NSTask/threads/timers (audit-safe)
#include <sys/wait.h> // waitpid/WNOHANG/WIFEXITED for the reap drain
#include <sys/stat.h> // outfile validation (exists + nonzero + mtime)
#include <time.h> // start stamp for the mtime check
#include <unistd.h> // access/unlink
#include <fcntl.h> // O_WRONLY for the quiet-spawn redirections
#include <stdio.h> // snprintf/fprintf/stderr
#include <string.h> // strcmp/strlen/strchr
#include <crt_externs.h> // _NSGetEnviron: children inherit our environment
#include <sys/types.h> // pid_t

// Async plugin renderer launcher (issue #323, PR-1 Task 3; lives in this
// TU after the macos.m split, so macos.m layout notes do not apply here).
// Three C entry points (declared for Zig
// in src/platform/bridge.zig): launchPluginRender + pollPluginCompletions
// + pluginOutcomeFor. Model: main-loop reap, no threads/locks/atomics/
// timers. Children are reaped per-slot with waitpid(pid, WNOHANG) out of
// a static 8-slot in-flight table. Cap note: the Zig job table holds 16
// entries (MAX_PLUGIN_JOBS in src/core/plugin_cache.zig) while at most 8
// render children are in flight here (PLUGIN_MAX_INFLIGHT); the Zig side
// (Task 5) keeps the overflow queued. This layer only launches, reaps,
// validates the outfile (exists + nonzero size + mtime >= start), records
// the per-job outcome, and unlinks the staged srcfile at terminal states
// (ownership passes from the caller at launch and ends at reap).
// Failures append to stderr; nothing here ever dialogs, crashes,
// invalidates, or touches Viewport/cache state — arrival wiring is Task 5.
#define PLUGIN_MAX_INFLIGHT 8
static pid_t plugin_pid[PLUGIN_MAX_INFLIGHT] = { 0 };
static time_t plugin_start[PLUGIN_MAX_INFLIGHT] = { 0 };
static char plugin_src[PLUGIN_MAX_INFLIGHT][512];
static char plugin_out[PLUGIN_MAX_INFLIGHT][512];

// Per-job outcome history for Task 5: the reap frees the slot, so the
// exit-status dimension would be unrecoverable from the drain count
// alone; each reap records (outfile, ok) here for later query by outfile
// path (the key Task 5 holds — launch never reveals slot indices).
// Non-consuming ring, last 16 outcomes retained; query promptly after
// poll reports completions (an in-flight path may still show its prior
// generation). Empty slot = outfile[0] == 0 (BSS zero-init).
#define PLUGIN_HIST 16
static char plugin_hist_out[PLUGIN_HIST][512];
static char plugin_hist_ok[PLUGIN_HIST];
static int plugin_hist_pos = 0;
static void plugin_hist_record(const char* outfile, int ok) {
    snprintf(plugin_hist_out[plugin_hist_pos], 512, "%s", outfile);
    plugin_hist_ok[plugin_hist_pos] = ok ? 1 : 0;
    plugin_hist_pos = (plugin_hist_pos + 1) % PLUGIN_HIST;
}
// Outcome query for Task 5: 1 clean render (exit 0 + outfile validated),
// 0 renderer failed (nonzero exit or bad outfile — even when bytes exist),
// -1 no record (never launched or evicted from the ring).
int pluginOutcomeFor(const char* outfile) {
    if (!outfile || !*outfile) return -1;
    for (int i = 0; i < PLUGIN_HIST; i++)
        if (plugin_hist_out[i][0] && strcmp(plugin_hist_out[i], outfile) == 0)
            return plugin_hist_ok[i];
    return -1;
}

// Quiet spawn: children inherit neither our stdout nor our stderr (both
// to /dev/null), so renderer chatter can never pollute the reader's own
// output streams (--dump-* purity). Returns the posix_spawnp status.
static int plugin_spawnq(const char* file, char* const argv[], pid_t* pid) {
    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0);
    posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0);
    int rc = posix_spawnp(pid, file, &actions, NULL, argv, *_NSGetEnviron());
    posix_spawn_file_actions_destroy(&actions);
    return rc;
}

// `which` semantics for a renderer: slash paths are checked directly,
// bare names must resolve on PATH. 1 when executable, else 0.
static int plugin_which_ok(const char* renderer) {
    if (strchr(renderer, '/') != NULL) return access(renderer, X_OK) == 0 ? 1 : 0;
    pid_t pid = 0;
    char* const argv[] = { (char*)"which", (char*)renderer, NULL };
    if (plugin_spawnq("/usr/bin/which", argv, &pid) != 0) return 0;
    int status = 0;
    if (waitpid(pid, &status, 0) < 0) return 0;
    return status == 0 ? 1 : 0;
}

// Non-blocking launch of `renderer srcfile outfile`. Returns 1 active
// (slot spent), 0 queued (table full: silent, the cache retries later),
// -1 failed (bad args, unresolvable or unlaunchable binary: no slot
// spent). Never waits, never dialogs; errors go to stderr only.
int launchPluginRender(const char* renderer, const char* srcfile, const char* outfile) {
    if (!renderer || !*renderer || !srcfile || !*srcfile || !outfile || !*outfile) return -1;
    if (strlen(srcfile) >= 512 || strlen(outfile) >= 512) {
        fprintf(stderr, "read: plugin render path too long\n");
        return -1;
    }
    if (!plugin_which_ok(renderer)) {
        fprintf(stderr, "read: plugin renderer missing: %s\n", renderer);
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
    snprintf(plugin_src[slot], 512, "%s", srcfile);
    snprintf(plugin_out[slot], 512, "%s", outfile);
    return 1;
}

// Main-loop drain, called once per frame (Task 5 calls it only while the
// in-flight count is > 0, so idle frames cost nothing): reap exited
// children without blocking, validate each outfile, record the per-job
// outcome, unlink the staged srcfile, free the slot. Per-slot
// waitpid(pid, WNOHANG) reaps only our own children — never waitpid(-1),
// which could steal a foreign child's status. Returns completions
// drained. Touches no Viewport/cache/UI state.
int pollPluginCompletions(void) {
    int drained = 0;
    for (int i = 0; i < PLUGIN_MAX_INFLIGHT; i++) {
        if (plugin_pid[i] <= 0) continue;
        int status = 0;
        pid_t pid = waitpid(plugin_pid[i], &status, WNOHANG);
        if (pid <= 0) continue;
        struct stat st;
        int ok = WIFEXITED(status) && WEXITSTATUS(status) == 0 &&
            stat(plugin_out[i], &st) == 0 && st.st_size > 0 &&
            st.st_mtime >= plugin_start[i];
        if (!ok) fprintf(stderr, "read: plugin render failed pid=%d out=%s\n", (int)pid, plugin_out[i]);
        plugin_hist_record(plugin_out[i], ok);
        plugin_pid[i] = 0;
        drained++;
        unlink(plugin_src[i]);
        plugin_src[i][0] = '\0';
        plugin_out[i][0] = '\0';
    }
    return drained;
}

#ifdef TEST_HOOKS
// Headless probe for the Task 3 integration test: in-flight child count.
int platform_test_plugin_active(void) {
    int n = 0;
    for (int i = 0; i < PLUGIN_MAX_INFLIGHT; i++) if (plugin_pid[i] > 0) n++;
    return n;
}
#endif
