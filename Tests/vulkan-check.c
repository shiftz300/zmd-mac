#define VK_USE_PLATFORM_WIN32_KHR
#define VK_NO_PROTOTYPES
#include <windows.h>
#include <vulkan.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* End-to-end Windows Vulkan surface, device, clear, and presentation smoke test.
 * This tests our runtime, not Endfield's shaders, gameplay, or anti-cheat. */
#define CHECK(call) do { VkResult r = (call); if (r != VK_SUCCESS) { \
    fprintf(stderr, "%s failed: %d\n", #call, r); return 1; } } while (0)
#define FN(name) PFN_##name name = (PFN_##name)get(instance, #name); \
    if (!name) { fprintf(stderr, "Missing %s\n", #name); return 2; }

static unsigned display_index, wanted_display;
static RECT fullscreen_rect;
static BOOL CALLBACK find_display(HMONITOR monitor, HDC dc, LPRECT rect, LPARAM data)
{
    if (++display_index == wanted_display) fullscreen_rect = *rect;
    return TRUE;
}

int main(int argc, char **argv)
{
    setvbuf(stdout, NULL, _IONBF, 0);
    SetProcessDPIAware();
    unsigned expected_width = 0, expected_height = 0;
    if (argc == 4) {
        wanted_display = strtoul(argv[1], NULL, 10);
        expected_width = strtoul(argv[2], NULL, 10);
        expected_height = strtoul(argv[3], NULL, 10);
        EnumDisplayMonitors(NULL, NULL, find_display, 0);
        if (!wanted_display || fullscreen_rect.right <= fullscreen_rect.left) return 10;
    }
    HMODULE lib = LoadLibraryA("vulkan-1.dll");
    if (!lib) { fprintf(stderr, "vulkan-1.dll: %lu\n", GetLastError()); return 3; }
    PFN_vkGetInstanceProcAddr get = (void *)GetProcAddress(lib, "vkGetInstanceProcAddr");
    if (!get) return 4;
    VkInstance instance = VK_NULL_HANDLE;
    FN(vkCreateInstance);
    const char *exts[] = {"VK_KHR_surface", "VK_KHR_win32_surface"};
    VkApplicationInfo app = { .sType = VK_STRUCTURE_TYPE_APPLICATION_INFO,
        .pApplicationName = "ZMD Vulkan Check", .apiVersion = VK_API_VERSION_1_1 };
    VkInstanceCreateInfo ici = { .sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
        .pApplicationInfo = &app, .enabledExtensionCount = 2, .ppEnabledExtensionNames = exts };
    CHECK(vkCreateInstance(&ici, NULL, &instance));
    FN(vkEnumeratePhysicalDevices); FN(vkGetPhysicalDeviceProperties);
    FN(vkGetPhysicalDeviceQueueFamilyProperties); FN(vkCreateWin32SurfaceKHR);
    FN(vkGetPhysicalDeviceSurfaceSupportKHR); FN(vkGetPhysicalDeviceSurfaceCapabilitiesKHR);
    FN(vkGetPhysicalDeviceSurfaceFormatsKHR); FN(vkCreateDevice);
    FN(vkGetDeviceQueue); FN(vkCreateSwapchainKHR); FN(vkGetSwapchainImagesKHR);
    FN(vkCreateCommandPool); FN(vkAllocateCommandBuffers); FN(vkBeginCommandBuffer);
    FN(vkCmdPipelineBarrier); FN(vkCmdClearColorImage); FN(vkEndCommandBuffer);
    FN(vkCreateSemaphore); FN(vkAcquireNextImageKHR); FN(vkQueueSubmit);
    FN(vkQueuePresentKHR); FN(vkDeviceWaitIdle); FN(vkDestroyCommandPool);
    FN(vkDestroySemaphore); FN(vkDestroySwapchainKHR); FN(vkDestroyDevice);
    FN(vkDestroySurfaceKHR); FN(vkDestroyInstance);

    uint32_t count = 0;
    CHECK(vkEnumeratePhysicalDevices(instance, &count, NULL));
    if (!count) { fprintf(stderr, "No Vulkan GPU\n"); return 5; }
    VkPhysicalDevice *gpus = calloc(count, sizeof(*gpus));
    CHECK(vkEnumeratePhysicalDevices(instance, &count, gpus));
    VkPhysicalDevice gpu = gpus[0];
    free(gpus);
    VkPhysicalDeviceProperties props;
    vkGetPhysicalDeviceProperties(gpu, &props);
    printf("Vulkan GPU: %s; API %u.%u.%u\n", props.deviceName,
        VK_VERSION_MAJOR(props.apiVersion), VK_VERSION_MINOR(props.apiVersion),
        VK_VERSION_PATCH(props.apiVersion));

    HINSTANCE module = GetModuleHandleA(NULL);
    WNDCLASSA wc = { .lpfnWndProc = DefWindowProcA, .hInstance = module,
        .lpszClassName = "ZmdVulkanCheck" };
    RegisterClassA(&wc);
    HWND window = CreateWindowA(wc.lpszClassName, "Vulkan runtime check",
        (wanted_display ? WS_POPUP : WS_OVERLAPPEDWINDOW) | WS_VISIBLE,
        wanted_display ? fullscreen_rect.left : 50, wanted_display ? fullscreen_rect.top : 50,
        wanted_display ? fullscreen_rect.right - fullscreen_rect.left : 480,
        wanted_display ? fullscreen_rect.bottom - fullscreen_rect.top : 300, NULL, NULL, module, NULL);
    if (!window) return 6;
    VkSurfaceKHR surface;
    VkWin32SurfaceCreateInfoKHR sci = { .sType = VK_STRUCTURE_TYPE_WIN32_SURFACE_CREATE_INFO_KHR,
        .hinstance = module, .hwnd = window };
    CHECK(vkCreateWin32SurfaceKHR(instance, &sci, NULL, &surface));
    vkGetPhysicalDeviceQueueFamilyProperties(gpu, &count, NULL);
    VkQueueFamilyProperties *families = calloc(count, sizeof(*families));
    vkGetPhysicalDeviceQueueFamilyProperties(gpu, &count, families);
    uint32_t family = UINT32_MAX;
    for (uint32_t i = 0; i < count; ++i) {
        VkBool32 support = VK_FALSE;
        CHECK(vkGetPhysicalDeviceSurfaceSupportKHR(gpu, i, surface, &support));
        if (support && (families[i].queueFlags & VK_QUEUE_GRAPHICS_BIT)) { family = i; break; }
    }
    free(families);
    if (family == UINT32_MAX) return 7;
    float priority = 1;
    VkDeviceQueueCreateInfo qci = { .sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
        .queueFamilyIndex = family, .queueCount = 1, .pQueuePriorities = &priority };
    const char *device_exts[] = {"VK_KHR_swapchain"};
    VkDeviceCreateInfo dci = { .sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
        .queueCreateInfoCount = 1, .pQueueCreateInfos = &qci,
        .enabledExtensionCount = 1, .ppEnabledExtensionNames = device_exts };
    VkDevice device;
    CHECK(vkCreateDevice(gpu, &dci, NULL, &device));
    VkQueue queue;
    vkGetDeviceQueue(device, family, 0, &queue);
    VkSurfaceCapabilitiesKHR caps;
    CHECK(vkGetPhysicalDeviceSurfaceCapabilitiesKHR(gpu, surface, &caps));
    CHECK(vkGetPhysicalDeviceSurfaceFormatsKHR(gpu, surface, &count, NULL));
    if (!count) return 8;
    VkSurfaceFormatKHR *formats = calloc(count, sizeof(*formats));
    CHECK(vkGetPhysicalDeviceSurfaceFormatsKHR(gpu, surface, &count, formats));
    VkSurfaceFormatKHR format = formats[0];
    free(formats);
    if (!(caps.supportedUsageFlags & VK_IMAGE_USAGE_TRANSFER_DST_BIT)) return 9;
    VkExtent2D extent = caps.currentExtent;
    if (extent.width == UINT32_MAX) extent = (VkExtent2D){480, 300};
    if (wanted_display && (extent.width != expected_width || extent.height != expected_height)) {
        fprintf(stderr, "FAIL: fullscreen surface %ux%u; expected %ux%u\n",
                extent.width, extent.height, expected_width, expected_height);
        return 11;
    }
    VkSwapchainCreateInfoKHR swapinfo = { .sType = VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR,
        .surface = surface, .minImageCount = caps.minImageCount,
        .imageFormat = format.format, .imageColorSpace = format.colorSpace,
        .imageExtent = extent, .imageArrayLayers = 1,
        .imageUsage = VK_IMAGE_USAGE_TRANSFER_DST_BIT, .imageSharingMode = VK_SHARING_MODE_EXCLUSIVE,
        .preTransform = caps.currentTransform, .presentMode = VK_PRESENT_MODE_FIFO_KHR,
        .compositeAlpha = caps.supportedCompositeAlpha & -caps.supportedCompositeAlpha, .clipped = VK_TRUE };
    VkSwapchainKHR swapchain;
    CHECK(vkCreateSwapchainKHR(device, &swapinfo, NULL, &swapchain));
    CHECK(vkGetSwapchainImagesKHR(device, swapchain, &count, NULL));
    VkImage *images = calloc(count, sizeof(*images));
    CHECK(vkGetSwapchainImagesKHR(device, swapchain, &count, images));
    printf("Swapchain created: %ux%u, %u images\n", extent.width, extent.height, count);
    VkCommandPoolCreateInfo pci = { .sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
        .queueFamilyIndex = family };
    VkCommandPool pool;
    CHECK(vkCreateCommandPool(device, &pci, NULL, &pool));
    VkCommandBufferAllocateInfo cai = { .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
        .commandPool = pool, .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY, .commandBufferCount = 1 };
    VkCommandBuffer cmd;
    CHECK(vkAllocateCommandBuffers(device, &cai, &cmd));
    VkSemaphoreCreateInfo seminfo = { .sType = VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO };
    VkSemaphore acquired, rendered;
    CHECK(vkCreateSemaphore(device, &seminfo, NULL, &acquired));
    CHECK(vkCreateSemaphore(device, &seminfo, NULL, &rendered));
    uint32_t index;
    CHECK(vkAcquireNextImageKHR(device, swapchain, 5000000000ULL, acquired, VK_NULL_HANDLE, &index));
    VkCommandBufferBeginInfo begin = { .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO };
    CHECK(vkBeginCommandBuffer(cmd, &begin));
    VkImageMemoryBarrier barrier = { .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
        .dstAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT, .oldLayout = VK_IMAGE_LAYOUT_UNDEFINED,
        .newLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
        .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED, .image = images[index],
        .subresourceRange = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 } };
    vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT,
        0, 0, NULL, 0, NULL, 1, &barrier);
    VkClearColorValue color = { .float32 = {0.05f, 0.35f, 0.50f, 1.0f} };
    vkCmdClearColorImage(cmd, images[index], VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
        &color, 1, &barrier.subresourceRange);
    barrier.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
    barrier.dstAccessMask = 0;
    barrier.oldLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
    barrier.newLayout = VK_IMAGE_LAYOUT_PRESENT_SRC_KHR;
    vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT,
        0, 0, NULL, 0, NULL, 1, &barrier);
    CHECK(vkEndCommandBuffer(cmd));
    VkPipelineStageFlags stage = VK_PIPELINE_STAGE_TRANSFER_BIT;
    VkSubmitInfo submit = { .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO,
        .waitSemaphoreCount = 1, .pWaitSemaphores = &acquired, .pWaitDstStageMask = &stage,
        .commandBufferCount = 1, .pCommandBuffers = &cmd,
        .signalSemaphoreCount = 1, .pSignalSemaphores = &rendered };
    CHECK(vkQueueSubmit(queue, 1, &submit, VK_NULL_HANDLE));
    VkPresentInfoKHR present = { .sType = VK_STRUCTURE_TYPE_PRESENT_INFO_KHR,
        .waitSemaphoreCount = 1, .pWaitSemaphores = &rendered,
        .swapchainCount = 1, .pSwapchains = &swapchain, .pImageIndices = &index };
    CHECK(vkQueuePresentKHR(queue, &present));
    CHECK(vkDeviceWaitIdle(device));
    printf("Windowed surface, GPU clear and present: PASS (%ux%u)\n", extent.width, extent.height);
    MSG msg;
    DWORD until = GetTickCount() + 1500;
    while ((LONG)(until - GetTickCount()) > 0) {
        while (PeekMessageA(&msg, NULL, 0, 0, PM_REMOVE)) { TranslateMessage(&msg); DispatchMessageA(&msg); }
        Sleep(10);
    }
    vkDestroySemaphore(device, acquired, NULL);
    vkDestroySemaphore(device, rendered, NULL);
    vkDestroyCommandPool(device, pool, NULL);
    vkDestroySwapchainKHR(device, swapchain, NULL);
    vkDestroyDevice(device, NULL);
    vkDestroySurfaceKHR(instance, surface, NULL);
    vkDestroyInstance(instance, NULL);
    free(images);
    DestroyWindow(window);
    return 0;
}
