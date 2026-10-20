// Run inside an isolated Wine prefix; never loads game files or creates a window.
#include <windows.h>
#include <d3d11.h>
#include <cstdio>
#include <cstring>
#include "nvngx/nvngx.hpp"
#include "d3d11/d3d11_interfaces.hpp"

#define REQUIRE(condition) do { if (!(condition)) { \
    std::printf("FAIL line %d: %s (Win32 %lu)\n", __LINE__, #condition, GetLastError()); \
    return 1; } } while (0)

int main(int argc, char **argv) {
    const bool baseline = argc == 2 && !std::strcmp(argv[1], "--baseline");
    HMODULE module = LoadLibraryW(L"nvngx.dll");
    REQUIRE(module);
    auto allocate = reinterpret_cast<NVNGX_RESULT (*)(NVNGXParameter **)>(
        GetProcAddress(module, "NVSDK_NGX_D3D11_AllocateParameters"));
    auto destroy = reinterpret_cast<NVNGX_RESULT (*)(NVNGXParameter *)>(
        GetProcAddress(module, "NVSDK_NGX_D3D11_DestroyParameters"));
    auto create = reinterpret_cast<NVNGX_RESULT (*)(ID3D11DeviceContext *, unsigned int, NVNGXParameter *, unsigned int **)>(
        GetProcAddress(module, "NVSDK_NGX_D3D11_CreateFeature"));
    auto evaluate = reinterpret_cast<NVNGX_RESULT (*)(ID3D11DeviceContext *, const unsigned int *, NVNGXParameter *, void *)>(
        GetProcAddress(module, "NVSDK_NGX_D3D11_EvaluateFeature"));
    auto release = reinterpret_cast<NVNGX_RESULT (*)(const unsigned int *)>(
        GetProcAddress(module, "NVSDK_NGX_D3D11_ReleaseFeature"));
    REQUIRE(allocate && destroy && create && evaluate && release);
    NVNGXParameter *params = nullptr;
    REQUIRE(allocate(&params) == NVNGX_RESULT_OK);
    // Test the loaded DLL's vtable, not an inlined copy of ParametersImpl.
    int token = 1;
    params->Set("Color", static_cast<void *>(&token));
    ID3D11Resource *r11 = nullptr;
    auto result = params->Get("Color", &r11);
    if (baseline) {
        REQUIRE(result == NVNGX_RESULT_FAIL);
        destroy(params);
        std::puts("PASS: original v0.80 reproduces the void-pointer resource failure");
        return 0;
    }
    REQUIRE(result == NVNGX_RESULT_OK && r11 == reinterpret_cast<ID3D11Resource *>(&token));
    ID3D12Resource *r12 = nullptr;
    REQUIRE(params->Get("Color", &r12) == NVNGX_RESULT_OK);
    REQUIRE(r12 == reinterpret_cast<ID3D12Resource *>(&token));
    void *pointer = nullptr;
    params->Set("R11", r11);
    REQUIRE(params->Get("R11", &pointer) == NVNGX_RESULT_OK && pointer == &token);
    params->Set("R12", r12);
    REQUIRE(params->Get("R12", &pointer) == NVNGX_RESULT_OK && pointer == &token);
    params->Set("Null", static_cast<void *>(nullptr));
    REQUIRE(params->Get("Null", &r11) == NVNGX_RESULT_OK && r11 == nullptr);
    REQUIRE(params->Get("Missing", &r11) == NVNGX_RESULT_FAIL);
    std::puts("PASS: patched DLL converts D3D11/D3D12 resource pointers in both directions");

    ID3D11Device *device = nullptr;
    ID3D11DeviceContext *context = nullptr;
    D3D_FEATURE_LEVEL level;
    REQUIRE(SUCCEEDED(D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr, 0,
        nullptr, 0, D3D11_SDK_VERSION, &device, &level, &context)));
    IMTLD3D11ContextExt1 *ext = nullptr;
    REQUIRE(SUCCEEDED(context->QueryInterface(__uuidof(IMTLD3D11ContextExt1),
                                             reinterpret_cast<void **>(&ext))));
    BOOL supported = FALSE;
    REQUIRE(SUCCEEDED(ext->CheckFeatureSupport(MTL_FEATURE_METALFX_TEMPORAL_SCALER,
                                               &supported, sizeof(supported))) && supported);
    ext->Release();
    std::puts("PASS: DXMT reports MetalFX Temporal support on this GPU");

    auto texture = [&](DXGI_FORMAT format, UINT size, UINT bind, ID3D11Texture2D **out) {
        D3D11_TEXTURE2D_DESC desc = {};
        desc.Width = desc.Height = size;
        desc.MipLevels = desc.ArraySize = desc.SampleDesc.Count = 1;
        desc.Format = format;
        desc.Usage = D3D11_USAGE_DEFAULT;
        desc.BindFlags = bind;
        return device->CreateTexture2D(&desc, nullptr, out);
    };
    ID3D11Texture2D *color, *depth, *motion, *output;
    const UINT bind = D3D11_BIND_SHADER_RESOURCE | D3D11_BIND_RENDER_TARGET;
    REQUIRE(SUCCEEDED(texture(DXGI_FORMAT_R16G16B16A16_FLOAT, 64, bind, &color)));
    REQUIRE(SUCCEEDED(texture(DXGI_FORMAT_R32_FLOAT, 64, bind, &depth)));
    REQUIRE(SUCCEEDED(texture(DXGI_FORMAT_R16G16_FLOAT, 64, bind, &motion)));
    REQUIRE(SUCCEEDED(texture(DXGI_FORMAT_R16G16B16A16_FLOAT, 128,
                              bind | D3D11_BIND_UNORDERED_ACCESS, &output)));
    auto clear = [&](ID3D11Texture2D *tex, float r, float g, float b) {
        ID3D11RenderTargetView *view = nullptr;
        HRESULT hr = device->CreateRenderTargetView(tex, nullptr, &view);
        if (FAILED(hr)) return hr;
        float values[] = {r, g, b, 1.0f};
        context->ClearRenderTargetView(view, values);
        view->Release();
        return S_OK;
    };
    REQUIRE(SUCCEEDED(clear(color, 0.25f, 0.5f, 0.75f)));
    REQUIRE(SUCCEEDED(clear(depth, 0.5f, 0, 0)));
    REQUIRE(SUCCEEDED(clear(motion, 0, 0, 0)));
    REQUIRE(SUCCEEDED(clear(output, 0, 0, 0)));
    params->Reset();
    params->Set("Width", 64u);
    params->Set("Height", 64u);
    params->Set("OutWidth", 128u);
    params->Set("OutHeight", 128u);
    params->Set("PerfQualityValue", 2u);
    params->Set("DLSS.Feature.Create.Flags",
                static_cast<unsigned int>(NVNGX_DLSS_FLAG_AUTO_EXPOSURE | NVNGX_DLSS_FLAG_MV_LOWRES));
    unsigned int *handle = nullptr;
    REQUIRE(create(context, NVNGX_FEATURE_SUPERSAMPLING, params, &handle) == NVNGX_RESULT_OK);
    params->Set("Color", static_cast<void *>(color));
    params->Set("Depth", static_cast<void *>(depth));
    params->Set("MotionVectors", static_cast<void *>(motion));
    params->Set("Output", static_cast<void *>(output));
    params->Set("DLSS.Render.Subrect.Dimensions.Width", 64u);
    params->Set("DLSS.Render.Subrect.Dimensions.Height", 64u);
    params->Set("DLSS.Pre.Exposure", 1.0f);
    params->Set("Reset", 1);
    REQUIRE(evaluate(context, handle, params, nullptr) == NVNGX_RESULT_OK);

    D3D11_TEXTURE2D_DESC desc;
    output->GetDesc(&desc);
    desc.Usage = D3D11_USAGE_STAGING;
    desc.BindFlags = 0;
    desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
    ID3D11Texture2D *readback = nullptr;
    REQUIRE(SUCCEEDED(device->CreateTexture2D(&desc, nullptr, &readback)));
    context->CopyResource(readback, output);
    D3D11_MAPPED_SUBRESOURCE map = {};
    REQUIRE(SUCCEEDED(context->Map(readback, 0, D3D11_MAP_READ, 0, &map)));
    const auto pixel = reinterpret_cast<const unsigned short *>(
        static_cast<const unsigned char *>(map.pData) + 64 * map.RowPitch) + 64 * 4;
    std::printf("MetalFX center pixel (FP16): %04x %04x %04x %04x\n",
                pixel[0], pixel[1], pixel[2], pixel[3]);
    // Positive finite RGB verifies actual GPU work, beyond the NGX success code.
    REQUIRE(pixel[0] > 0 && pixel[0] < 0x7c00 &&
            pixel[1] > 0 && pixel[1] < 0x7c00 && pixel[2] > 0 && pixel[2] < 0x7c00);
    context->Unmap(readback, 0);
    release(handle);
    destroy(params);
    readback->Release(); output->Release(); motion->Release(); depth->Release(); color->Release();
    context->Release(); device->Release();
    FreeLibrary(module);
    std::puts("PASS: NGX evaluated void-pointer inputs through MetalFX and produced nonblack GPU output");
    return 0;
}
