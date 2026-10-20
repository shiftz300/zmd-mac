/* Minimal Qt-ABI fixture. No Qt implementation or proprietary code is bundled.
 * The real launcher's Qt 5.15.8 integration is verified separately. */
#include <windows.h>
#include <stdio.h>
#include <string.h>

struct argument { const void *data; const char *name; };

void *qt_instance(void)
{
    return FindWindowW(L"ZmdLauncherFixture", NULL);
}

unsigned char qt_invoke(void *app, const char *method, int connection,
                       struct argument a0, struct argument a1,
                       struct argument a2, struct argument a3,
                       struct argument a4, struct argument a5,
                       struct argument a6, struct argument a7,
                       struct argument a8, struct argument a9)
{
    struct argument args[] = {a0,a1,a2,a3,a4,a5,a6,a7,a8,a9};
    if (!app || strcmp(method, "OnTrayReqExitApp") || connection != 2) return 0;
    for (unsigned i = 0; i < 10; ++i)
        if (args[i].data || args[i].name) return 0;
    if (GetFileAttributesA("reject-qt") != INVALID_FILE_ATTRIBUTES)
    {
        FILE *f = fopen("launcher-qt-rejected", "w");
        if (f) fclose(f);
        return 0;
    }
    return PostMessageW(app, WM_APP + 1, 0, 0) != 0;
}
