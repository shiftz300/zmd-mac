/* Read-only display integration test. Its invisible window is the only window moved. */
#include <windows.h>
#include <stdio.h>
static int count, failed;
static HWND test_window;
static BOOL CALLBACK check_monitor(HMONITOR monitor, HDC dc, LPRECT rect, LPARAM data)
{
    MONITORINFO info = {sizeof(info)};
    ++count;
    if (!monitor || !GetMonitorInfoW(monitor, &info)) {
        fprintf(stderr, "FAIL: invalid monitor handle\n"); failed = 1; return TRUE;
    }
    SetWindowPos(test_window, NULL, rect->left + 16, rect->top + 16, 100, 100,
                 SWP_NOACTIVATE | SWP_NOZORDER);
    if (MonitorFromWindow(test_window, MONITOR_DEFAULTTONULL) != monitor) {
        fprintf(stderr, "FAIL: window did not map to its display\n"); failed = 1;
    }
    printf("display %d: %ldx%ld, valid handle and window mapping\n", count,
           rect->right - rect->left, rect->bottom - rect->top);
    return TRUE;
}
int main(void)
{
    SetProcessDPIAware();
    test_window = CreateWindowExW(0, L"STATIC", L"ZMD display test", WS_POPUP,
                                 0, 0, 100, 100, NULL, NULL, NULL, NULL);
    if (!test_window) return 2;
    if (!EnumDisplayMonitors(NULL, NULL, check_monitor, 0)) failed = 1;
    DestroyWindow(test_window);
    if (!count) failed = 1;
    return failed;
}
