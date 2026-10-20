#include <windows.h>
#include <stdio.h>
#include <string.h>

static int game;
static int helper;
static void mark(const char *event)
{
    char path[80];
    snprintf(path, sizeof(path), "%s-%s", helper ? "helper" : game ? "game" : "launcher", event);
    FILE *f = fopen(path, "w");
    if (f) fclose(f);
}
static LRESULT CALLBACK window_proc(HWND window, UINT message, WPARAM wp, LPARAM lp)
{
    if (message == WM_APP + 1 && !game && !helper)
    {
        mark("tray-exit");
        PostMessageW(window, WM_CLOSE, 0, 0);
        return 0;
    }
    if (message == WM_TIMER && helper)
    {
        /* The launcher owns its worker's lifetime; allow time to detect an
         * erroneous independent shutdown request to this worker. */
        static unsigned ended_ticks;
        if (GetFileAttributesA("launcher-ended") != INVALID_FILE_ATTRIBUTES &&
            ++ended_ticks >= 10)
        {
            mark("ended");
            DestroyWindow(window);
            PostQuitMessage(0);
        }
        return 0;
    }
    if (message == WM_QUERYENDSESSION)
    {
        mark("query");
        /* Reproduce a game that vetoes session-end but accepts normal close. */
        return !game && !helper;
    }
    if (message == WM_ENDSESSION) { if (wp) mark("ended"); return 0; }
    if (message == WM_CLOSE)
    {
        mark("close");
        if (!game && !helper) mark("ended");
        DestroyWindow(window);
        PostQuitMessage(0);
        return 0;
    }
    return DefWindowProcW(window, message, wp, lp);
}
int WINAPI WinMain(HINSTANCE instance, HINSTANCE previous, LPSTR args, int show)
{
    game = strstr(args, "game") != NULL;
    helper = strstr(args, "helper") != NULL;
    WCHAR directory[32768];
    if (GetEnvironmentVariableW(L"ZMD_SESSION_TEST_DIR", directory, 32768))
        SetCurrentDirectoryW(directory);
    WNDCLASSW cls = {0};
    cls.lpfnWndProc = window_proc;
    cls.hInstance = instance;
    cls.lpszClassName = game ? L"UnityWndClass" :
                       helper ? L"ZmdHelperFixture" : L"ZmdLauncherFixture";
    if (!RegisterClassW(&cls)) return 1;
    /* Hidden Windows windows: no extra visible test windows or Dock icons. */
    HWND window = CreateWindowW(cls.lpszClassName, L"ZMD session fixture", WS_OVERLAPPEDWINDOW,
                               0, 0, 100, 100, NULL, NULL, instance, NULL);
    if (!window) return 2;
    if (helper) SetTimer(window, 1, 100, NULL);
    if (!game && !helper && !LoadLibraryW(L"Qt5Core.dll")) return 3;
    mark("ready");
    MSG msg;
    while (GetMessageW(&msg, NULL, 0, 0)) DispatchMessageW(&msg);
    return 0;
}
