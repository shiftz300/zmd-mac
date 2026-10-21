#define COBJMACROS
#include <windows.h>
#include <winhttp.h>
#include <d3d11.h>
#include <stdio.h>

/* Checks actual networking and graphics, not the game's anti-cheat state. */
int main(void)
{
    HINTERNET session, connection, request;
    DWORD status = 0, size = sizeof(status);
    DWORD redirects = WINHTTP_OPTION_REDIRECT_POLICY_NEVER;
    ID3D11Device *device = NULL;
    ID3D11DeviceContext *context = NULL;
    const D3D_FEATURE_LEVEL levels[] = {
        D3D_FEATURE_LEVEL_11_1, D3D_FEATURE_LEVEL_11_0
    };
    D3D_FEATURE_LEVEL selected = 0;
    HRESULT result;

    printf("Windows executable: %u-bit\n", (unsigned)(sizeof(void *) * 8));
    session = WinHttpOpen(L"ZMD-Runtime-Check/1", WINHTTP_ACCESS_TYPE_DEFAULT_PROXY,
                         WINHTTP_NO_PROXY_NAME, WINHTTP_NO_PROXY_BYPASS, 0);
    if (!session) return 10;
    WinHttpSetTimeouts(session, 15000, 15000, 15000, 15000);
    connection = WinHttpConnect(session, L"launcher.hypergryph.com",
                                INTERNET_DEFAULT_HTTPS_PORT, 0);
    if (!connection) return 11;
    request = WinHttpOpenRequest(connection, L"GET",
        L"/launcher/get_latest_launcher?appcode=abYeZZ16BPluCFyT&ta=endfield&channel=1&sub_channel=1",
        NULL, WINHTTP_NO_REFERER, WINHTTP_DEFAULT_ACCEPT_TYPES, WINHTTP_FLAG_SECURE);
    if (!request) return 12;
    WinHttpSetOption(request, WINHTTP_OPTION_REDIRECT_POLICY, &redirects, sizeof(redirects));
    if (!WinHttpSendRequest(request, WINHTTP_NO_ADDITIONAL_HEADERS, 0,
                           WINHTTP_NO_REQUEST_DATA, 0, 0, 0) ||
        !WinHttpReceiveResponse(request, NULL) ||
        !WinHttpQueryHeaders(request, WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER,
                             WINHTTP_HEADER_NAME_BY_INDEX, &status, &size, NULL)) {
        fprintf(stderr, "HTTPS failed: %lu\n", GetLastError());
        return 13;
    }
    printf("Official launcher HTTPS: %lu\n", status);
    WinHttpCloseHandle(request);
    WinHttpCloseHandle(connection);
    WinHttpCloseHandle(session);
    if (status < 200 || status >= 400) return 14;

    result = D3D11CreateDevice(NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, 0,
                              levels, 2, D3D11_SDK_VERSION,
                              &device, &selected, &context);
    printf("D3D11 hardware device: 0x%08lx, feature level: 0x%x\n",
           (unsigned long)result, selected);
    if (FAILED(result)) return 20;
    ID3D11DeviceContext_Release(context);
    ID3D11Device_Release(device);
    return 0;
}
