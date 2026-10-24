#define VK_NO_PROTOTYPES
#include <windows.h>
#include <vulkan.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* A no-op compute pipeline tests cache transport, not game performance. Each
 * invocation is a fresh process; the caller owns an isolated Wine prefix. */
#define CHECK(call) do { VkResult r = (call); if (r != VK_SUCCESS) { \
    fprintf(stderr, "%s failed: %d\n", #call, r); return 1; } } while (0)
#define FN(name) PFN_##name name = (PFN_##name)get(instance, #name); \
    if (!name) { fprintf(stderr, "Missing %s\n", #name); return 2; }

int main(int argc, char **argv)
{
    if (argc != 3 || (strcmp(argv[1], "cold") && strcmp(argv[1], "cold-repeat") &&
                     strcmp(argv[1], "warm") && strcmp(argv[1], "warm-repeat"))) return 2;
    setvbuf(stdout, NULL, _IONBF, 0);
    HMODULE lib = LoadLibraryA("vulkan-1.dll");
    if (!lib) return 2;
    PFN_vkGetInstanceProcAddr get = (void *)GetProcAddress(lib, "vkGetInstanceProcAddr");
    if (!get) return 2;
    VkInstance instance = VK_NULL_HANDLE;
    FN(vkCreateInstance);
    VkApplicationInfo app = { .sType = VK_STRUCTURE_TYPE_APPLICATION_INFO,
        .pApplicationName = "ZMD cache probe", .apiVersion = VK_API_VERSION_1_1 };
    VkInstanceCreateInfo ici = { .sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, .pApplicationInfo = &app };
    CHECK(vkCreateInstance(&ici, NULL, &instance));
    FN(vkEnumeratePhysicalDevices); FN(vkGetPhysicalDeviceProperties);
    FN(vkGetPhysicalDeviceQueueFamilyProperties); FN(vkEnumerateDeviceExtensionProperties);
    FN(vkCreateDevice); FN(vkCreatePipelineCache); FN(vkGetPipelineCacheData);
    FN(vkCreateShaderModule); FN(vkCreatePipelineLayout); FN(vkCreateComputePipelines);
    FN(vkGetDeviceQueue); FN(vkCreateCommandPool); FN(vkAllocateCommandBuffers);
    FN(vkBeginCommandBuffer); FN(vkCmdBindPipeline); FN(vkCmdDispatch);
    FN(vkEndCommandBuffer); FN(vkQueueSubmit); FN(vkDeviceWaitIdle);
    FN(vkDestroyCommandPool); FN(vkDestroyPipeline); FN(vkDestroyPipelineLayout);
    FN(vkDestroyShaderModule); FN(vkDestroyPipelineCache); FN(vkDestroyDevice); FN(vkDestroyInstance);
    uint32_t count = 0;
    CHECK(vkEnumeratePhysicalDevices(instance, &count, NULL));
    if (!count) return 2;
    VkPhysicalDevice *gpus = calloc(count, sizeof(*gpus));
    CHECK(vkEnumeratePhysicalDevices(instance, &count, gpus));
    VkPhysicalDevice gpu = gpus[0]; free(gpus);
    VkPhysicalDeviceProperties props;
    vkGetPhysicalDeviceProperties(gpu, &props);
    vkGetPhysicalDeviceQueueFamilyProperties(gpu, &count, NULL);
    VkQueueFamilyProperties *families = calloc(count, sizeof(*families));
    vkGetPhysicalDeviceQueueFamilyProperties(gpu, &count, families);
    uint32_t family = UINT32_MAX;
    for (uint32_t i = 0; i < count; ++i)
        if (families[i].queueFlags & VK_QUEUE_COMPUTE_BIT) { family = i; break; }
    free(families);
    if (family == UINT32_MAX) return 2;
    CHECK(vkEnumerateDeviceExtensionProperties(gpu, NULL, &count, NULL));
    VkExtensionProperties *exts = calloc(count, sizeof(*exts));
    CHECK(vkEnumerateDeviceExtensionProperties(gpu, NULL, &count, exts));
    int feedback_supported = 0;
    for (uint32_t i = 0; i < count; ++i)
        if (!strcmp(exts[i].extensionName, VK_EXT_PIPELINE_CREATION_FEEDBACK_EXTENSION_NAME)) feedback_supported = 1;
    free(exts);
    float priority = 1;
    VkDeviceQueueCreateInfo qci = { .sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
        .queueFamilyIndex = family, .queueCount = 1, .pQueuePriorities = &priority };
    const char *feedback_extension = VK_EXT_PIPELINE_CREATION_FEEDBACK_EXTENSION_NAME;
    VkDeviceCreateInfo dci = { .sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
        .queueCreateInfoCount = 1, .pQueueCreateInfos = &qci,
        .enabledExtensionCount = feedback_supported ? 1 : 0, .ppEnabledExtensionNames = &feedback_extension };
    VkDevice device;
    CHECK(vkCreateDevice(gpu, &dci, NULL, &device));
    size_t input_size = 0; void *input = NULL;
    if (strncmp(argv[1], "cold", 4)) {
        FILE *f = fopen(argv[2], "rb");
        if (!f || fseek(f, 0, SEEK_END)) return 3;
        long length = ftell(f);
        if (length < 32 || length > 16 * 1024 * 1024 || fseek(f, 0, SEEK_SET)) return 3;
        input_size = (size_t)length; input = malloc(input_size);
        if (fread(input, 1, input_size, f) != input_size) return 3;
        fclose(f);
    }
    VkPipelineCacheCreateInfo cci = { .sType = VK_STRUCTURE_TYPE_PIPELINE_CACHE_CREATE_INFO,
        .initialDataSize = input_size, .pInitialData = input };
    VkPipelineCache cache;
    CHECK(vkCreatePipelineCache(device, &cci, NULL, &cache)); free(input);
    /* SPIR-V 1.0: GLCompute main(), local size 1, no resources or side effects. */
    const uint32_t spirv[] = {
        0x07230203, 0x00010000, 0, 5, 0,
        0x00020011, 1, 0x0003000e, 0, 1,
        0x0005000f, 5, 3, 0x6e69616d, 0,
        0x00060010, 3, 17, 1, 1, 1,
        0x00020013, 1, 0x00030021, 2, 1,
        0x00050036, 1, 3, 0, 2, 0x000200f8, 4, 0x000100fd, 0x00010038
    };
    VkShaderModuleCreateInfo smci = { .sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
        .codeSize = sizeof(spirv), .pCode = spirv };
    VkShaderModule shader;
    CHECK(vkCreateShaderModule(device, &smci, NULL, &shader));
    VkPipelineLayoutCreateInfo lci = { .sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO };
    VkPipelineLayout layout;
    CHECK(vkCreatePipelineLayout(device, &lci, NULL, &layout));
    VkPipelineCreationFeedback feedback = {0};
    VkPipelineCreationFeedbackCreateInfo fci = { .sType = VK_STRUCTURE_TYPE_PIPELINE_CREATION_FEEDBACK_CREATE_INFO,
        .pPipelineCreationFeedback = &feedback };
    VkComputePipelineCreateInfo pci = { .sType = VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO,
        .pNext = feedback_supported ? &fci : NULL, .layout = layout,
        .stage = { .sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
                   .stage = VK_SHADER_STAGE_COMPUTE_BIT, .module = shader, .pName = "main" } };
    VkPipeline pipeline;
    LARGE_INTEGER start, end, frequency;
    QueryPerformanceFrequency(&frequency); QueryPerformanceCounter(&start);
    CHECK(vkCreateComputePipelines(device, cache, 1, &pci, NULL, &pipeline));
    QueryPerformanceCounter(&end);
    /* Cross a stdio buffer boundary: a 1 KB cache cannot catch the game's
     * failure after its first successful 4 KB write. Keep timing/feedback
     * above scoped to the first pipeline for cold/warm comparison. */
    VkPipelineCreationFeedback first_feedback = feedback;
    size_t early_size = 0;
    CHECK(vkGetPipelineCacheData(device, cache, &early_size, NULL));
    for (uint32_t local_size = 2; local_size <= 64; ++local_size) {
        uint32_t variant[sizeof(spirv) / sizeof(spirv[0])];
        memcpy(variant, spirv, sizeof(variant));
        variant[18] = local_size;
        VkShaderModuleCreateInfo variant_info = smci;
        variant_info.pCode = variant;
        VkShaderModule variant_shader;
        CHECK(vkCreateShaderModule(device, &variant_info, NULL, &variant_shader));
        VkComputePipelineCreateInfo variant_pipeline_info = pci;
        variant_pipeline_info.pNext = NULL;
        variant_pipeline_info.stage.module = variant_shader;
        VkPipeline variant_pipeline;
        CHECK(vkCreateComputePipelines(device, cache, 1, &variant_pipeline_info, NULL, &variant_pipeline));
        vkDestroyPipeline(device, variant_pipeline, NULL);
        vkDestroyShaderModule(device, variant_shader, NULL);
    }
    feedback = first_feedback;
    VkCommandPoolCreateInfo pool_info = { .sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO, .queueFamilyIndex = family };
    VkCommandPool pool;
    CHECK(vkCreateCommandPool(device, &pool_info, NULL, &pool));
    VkCommandBufferAllocateInfo ai = { .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
        .commandPool = pool, .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY, .commandBufferCount = 1 };
    VkCommandBuffer cmd;
    CHECK(vkAllocateCommandBuffers(device, &ai, &cmd));
    VkCommandBufferBeginInfo bi = { .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO };
    CHECK(vkBeginCommandBuffer(cmd, &bi));
    vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_COMPUTE, pipeline); vkCmdDispatch(cmd, 1, 1, 1);
    CHECK(vkEndCommandBuffer(cmd));
    VkQueue queue; vkGetDeviceQueue(device, family, 0, &queue);
    VkSubmitInfo si = { .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1, .pCommandBuffers = &cmd };
    CHECK(vkQueueSubmit(queue, 1, &si, VK_NULL_HANDLE)); CHECK(vkDeviceWaitIdle(device));
    size_t output_size = 0;
    CHECK(vkGetPipelineCacheData(device, cache, &output_size, NULL));
    if (output_size <= 32 || output_size > 16 * 1024 * 1024) return 4;
    /* Unity probes only the public header before deciding whether to save. */
    struct { unsigned char header[32]; unsigned char guard[32]; } partial;
    memset(&partial, 0xa5, sizeof(partial));
    size_t partial_size = sizeof(partial.header);
    VkResult partial_result = vkGetPipelineCacheData(device, cache, &partial_size, partial.header);
    if ((partial_result != VK_SUCCESS && partial_result != VK_INCOMPLETE) || partial_size > 32) return 4;
    for (size_t i = 0; i < sizeof(partial.guard); i++) if (partial.guard[i] != 0xa5) return 4;
    void *output = malloc(output_size);
    if (!output) return 4;
    CHECK(vkGetPipelineCacheData(device, cache, &output_size, output));
    uint64_t raw_size = output_size;
    int compressed = output_size >= 64 && !memcmp((char *)output + 32, "ZMD-ZSTD-PSO-1", 16);
    if (compressed) memcpy(&raw_size, (char *)output + 48, sizeof(raw_size));
    if (raw_size <= 4096) return 4;
    void *repeat = malloc(output_size);
    size_t repeat_size = output_size;
    if (!repeat) return 4;
    CHECK(vkGetPipelineCacheData(device, cache, &repeat_size, repeat));
    if (repeat_size != output_size || memcmp(repeat, output, output_size)) return 4;
    free(repeat);
    if (compressed) {
        /* An invalid compressed file must be ignored as an empty cache. */
        ((unsigned char *)output)[64] ^= 1;
        VkPipelineCacheCreateInfo broken_info = cci;
        broken_info.initialDataSize = output_size; broken_info.pInitialData = output;
        VkPipelineCache broken_cache;
        CHECK(vkCreatePipelineCache(device, &broken_info, NULL, &broken_cache));
        vkDestroyPipelineCache(device, broken_cache, NULL);
        ((unsigned char *)output)[64] ^= 1;
    }
    FILE *f = fopen(argv[2], "wb");
    if (!f || fwrite(output, 1, output_size, f) != output_size || fclose(f)) return 3;
    free(output);
    printf("CACHE_RESULT {\"mode\":\"%s\",\"vendor\":%u,\"device\":%u,\"uuid\":\"", argv[1], props.vendorID, props.deviceID);
    for (unsigned i = 0; i < VK_UUID_SIZE; ++i) printf("%02x", props.pipelineCacheUUID[i]);
    printf("\",\"pipeline_count\":64,\"input_bytes\":%zu,\"output_bytes\":%zu,\"raw_bytes\":%llu,\"compressed\":%s,\"feedback_supported\":%s,\"feedback_valid\":%s,\"cache_hit\":%s,\"create_ms\":%.3f}\n",
        input_size, output_size, (unsigned long long)raw_size, compressed ? "true" : "false", feedback_supported ? "true" : "false",
        (feedback.flags & VK_PIPELINE_CREATION_FEEDBACK_VALID_BIT) ? "true" : "false",
        (feedback.flags & VK_PIPELINE_CREATION_FEEDBACK_APPLICATION_PIPELINE_CACHE_HIT_BIT) ? "true" : "false",
        (end.QuadPart - start.QuadPart) * 1000.0 / frequency.QuadPart);
    vkDestroyCommandPool(device, pool, NULL); vkDestroyPipeline(device, pipeline, NULL);
    vkDestroyPipelineLayout(device, layout, NULL); vkDestroyShaderModule(device, shader, NULL);
    vkDestroyPipelineCache(device, cache, NULL); vkDestroyDevice(device, NULL);
    vkDestroyInstance(instance, NULL); FreeLibrary(lib);
    return 0;
}
