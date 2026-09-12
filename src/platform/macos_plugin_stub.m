// Empty plugin launcher stub (AGENTS.md §7 differential twin). Included by
// src/platform/macos.m when READ_PLUGIN_STUB=1 instead of macos_plugin.m:
// same TU, same flags, trivial bodies. No child ever launches (launch fails
// like a missing renderer, drain finds nothing, outcomes stay unrecorded),
// so the twin's __TEXT delta is exactly the plugin-attributable launcher
// code. Never shipped, never bundled — observability tooling only.
int launchPluginRender(const char* renderer, const char* srcfile, const char* outfile) {
    (void)renderer;
    (void)srcfile;
    (void)outfile;
    return -1;
}
int pollPluginCompletions(void) {
    return 0;
}
int pluginOutcomeFor(const char* outfile) {
    (void)outfile;
    return -1;
}
#ifdef TEST_HOOKS
int platform_test_plugin_active(void) {
    return 0;
}
#endif
