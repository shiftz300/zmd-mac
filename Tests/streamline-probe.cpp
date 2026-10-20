// Isolated integration test; requires Streamline headers and the user-installed game DLLs.
#include <windows.h>
#include <dxgi1_2.h>
#include <d3d11.h>
#include <cstdio>
#include <string>
#include <climits>
#include "sl.h"
#include "sl_dlss.h"

int wmain(int argc,wchar_t **argv) {
 if(argc!=2) return 2;
 std::wstring dir=argv[1];
 SetDllDirectoryW(dir.c_str());
 auto dll=LoadLibraryW((dir+L"\\sl.interposer.dll").c_str());
 if(!dll){printf("Load interposer failed %lu\n",GetLastError());return 3;}
 auto init=(PFun_slInit*)GetProcAddress(dll,"slInit");
 auto supported=(PFun_slIsFeatureSupported*)GetProcAddress(dll,"slIsFeatureSupported");
 auto shutdown=(PFun_slShutdown*)GetProcAddress(dll,"slShutdown");
 if(!init||!supported||!shutdown)return 4;
 const wchar_t *paths[]={dir.c_str()};
 const sl::Feature features[]={sl::kFeatureDLSS};
 sl::Preferences pref{};
 pref.logLevel=sl::LogLevel::eVerbose;
 pref.logMessageCallback=[](sl::LogType type,const char *msg){printf("SL: %s\n",msg);};
 pref.pathsToPlugins=paths;pref.numPathsToPlugins=1;
 pref.featuresToLoad=features;pref.numFeaturesToLoad=1;
 pref.flags=sl::PreferenceFlags::eDisableCLStateTracking | sl::PreferenceFlags::eUseManualHooking;
 pref.engine=sl::EngineType::eCustom;pref.engineVersion="zmd-probe";
 pref.projectId="b5818e24-7065-405f-9f53-21c2056be532";
 pref.renderAPI=sl::RenderAPI::eD3D11;
 auto result=init(pref,sl::kSDKVersion);
 printf("slInit=%d\n",(int)result);fflush(stdout);
 if(result!=sl::Result::eOk) return 8;
 IDXGIFactory1 *factory=nullptr;IDXGIAdapter1 *adapter=nullptr;
 if(FAILED(CreateDXGIFactory1(__uuidof(IDXGIFactory1),(void**)&factory)))return 5;
 if(FAILED(factory->EnumAdapters1(0,&adapter)))return 6;
 DXGI_ADAPTER_DESC1 desc{};adapter->GetDesc1(&desc);
 printf("Adapter Vendor=%x Device=%x\n",desc.VendorId,desc.DeviceId);
 sl::AdapterInfo info{};info.deviceLUID=(uint8_t*)&desc.AdapterLuid;info.deviceLUIDSizeInBytes=sizeof(desc.AdapterLuid);
 auto support=supported(sl::kFeatureDLSS,info);
 printf("slIsFeatureSupported(DLSS)=%d\n",(int)support);fflush(stdout);

 ID3D11Device *device=nullptr;ID3D11DeviceContext *context=nullptr;D3D_FEATURE_LEVEL level;
 auto hr=D3D11CreateDevice(adapter,D3D_DRIVER_TYPE_UNKNOWN,nullptr,0,nullptr,0,D3D11_SDK_VERSION,&device,&level,&context);
 printf("D3D11CreateDevice=%lx\n",hr);fflush(stdout);
 if(FAILED(hr)) return 9;
 auto setDevice=(PFun_slSetD3DDevice*)GetProcAddress(dll,"slSetD3DDevice");
 if(!setDevice) return 10;
 auto deviceResult=setDevice(device);
 printf("slSetD3DDevice=%d\n",(int)deviceResult);fflush(stdout);
 auto getFunction=(PFun_slGetFeatureFunction*)GetProcAddress(dll,"slGetFeatureFunction");
 if(!getFunction) return 11;
 void *function=nullptr;
 auto fnResult=getFunction(sl::kFeatureDLSS,"slDLSSGetOptimalSettings",function);
 printf("slGetFeatureFunction=%d function=%p NGX=%p\n",(int)fnResult,function,GetModuleHandleW(L"nvngx.dll"));fflush(stdout);
 bool qualityOK=false;
 if(function){
  sl::DLSSOptions options{}; options.mode=sl::DLSSMode::eMaxQuality;options.outputWidth=3840;options.outputHeight=2160;
  sl::DLSSOptimalSettings settings{};
  auto fn=(PFun_slDLSSGetOptimalSettings*)function;
  auto rr=fn(options,settings);
  qualityOK = rr==sl::Result::eOk && settings.optimalRenderWidth==2560 && settings.optimalRenderHeight==1440;
  printf("DLSS settings result=%d render=%ux%u\n",(int)rr,settings.optimalRenderWidth,settings.optimalRenderHeight);fflush(stdout);
 }
 shutdown();if(context)context->Release();if(device)device->Release();adapter->Release();factory->Release();FreeLibrary(dll);
 return support==sl::Result::eOk && deviceResult==sl::Result::eOk && fnResult==sl::Result::eOk && qualityOK ? 0 : 7;
}
