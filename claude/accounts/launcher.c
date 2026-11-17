// Account app launcher: runs the bundled Claude.real with its own profile folder.
// Build: clang -DPROFILE='"Claude Account 2"' launcher.c -o "<App>.app/Contents/MacOS/<exe>"
#include <mach-o/dyld.h>
#include <libgen.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char *argv[]) {
    char self[PATH_MAX], copy[PATH_MAX], real[PATH_MAX], profile[PATH_MAX + 32];
    uint32_t size = sizeof(self);
    const char *home = getenv("HOME");
    if (_NSGetExecutablePath(self, &size) != 0 || !home || !*home) { fputs("launcher: bad environment\n", stderr); return 1; }
    strlcpy(copy, self, sizeof(copy));
    int a = snprintf(real, sizeof(real), "%s/Claude.real", dirname(copy));
    int b = snprintf(profile, sizeof(profile), "--user-data-dir=%s/Library/Application Support/" PROFILE, home);
    if (a < 0 || (size_t)a >= sizeof(real) || b < 0 || (size_t)b >= sizeof(profile)) { fputs("launcher: path too long\n", stderr); return 1; }

    char **args = calloc((size_t)argc + 2, sizeof(char *));
    if (!args) return 1;
    args[0] = real;
    args[1] = profile;
    for (int i = 1; i < argc; i++) args[i + 1] = argv[i];
    execv(real, args);
    perror("launcher: execv");
    return 1;
}
