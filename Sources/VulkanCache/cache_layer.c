/* Native explicit Vulkan layer: compress opaque application cache data only.
 * No shader rewriting, disk IO, driver-private structures or draw interception.
 * Cache snapshots are invalidated by pipeline creation and cache merges. */
#define VK_NO_PROTOTYPES
#include <vk_layer.h>
#include <pthread.h>
#include <stdio.h>
#include <time.h>
#include "cache_codec.h"

#define EXPORT __attribute__((visibility("default")))
struct instance {
    void *key;
    VkInstance handle;
    PFN_vkGetInstanceProcAddr gipa;
    PFN_GetPhysicalDeviceProcAddr gpdpa;
    struct instance *next;
};
struct snapshot {
    VkPipelineCache cache;
    void *data;
    size_t size;
    struct snapshot *next;
};
struct device {
    void *key;
    VkDevice handle;
    PFN_vkGetDeviceProcAddr gdpa;
    PFN_vkGetPipelineCacheData get;
    PFN_vkCreatePipelineCache create;
    PFN_vkDestroyPipelineCache destroy;
    pthread_mutex_t lock;
    struct snapshot *snapshots;
    struct device *next;
};
static pthread_mutex_t registry = PTHREAD_MUTEX_INITIALIZER;
static struct instance *instances;
static struct device *devices;
static double seconds(void)
{
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec + t.tv_nsec / 1e9;
}
static PFN_vkVoidFunction VKAPI_CALL get_instance(VkInstance, const char *);
static PFN_vkVoidFunction VKAPI_CALL get_device(VkDevice, const char *);

/* Dispatchable children (physical devices) share their parent's dispatch key. */
static void *dispatch_key(void *handle) { return handle ? *(void **)handle : NULL; }
static struct instance *find_instance(void *handle)
{
    pthread_mutex_lock(&registry);
    struct instance *i = instances;
    while (i && i->key != dispatch_key(handle)) i = i->next;
    pthread_mutex_unlock(&registry);
    return i;
}
static struct device *find_device(VkDevice handle)
{
    pthread_mutex_lock(&registry);
    struct device *d = devices;
    while (d && d->key != dispatch_key(handle)) d = d->next;
    pthread_mutex_unlock(&registry);
    return d;
}
static void invalidate(struct device *d, VkPipelineCache cache)
{
    pthread_mutex_lock(&d->lock);
    struct snapshot **link = &d->snapshots;
    while (*link) {
        struct snapshot *s = *link;
        if (s->cache == cache) { *link = s->next; free(s->data); free(s); break; }
        link = &s->next;
    }
    pthread_mutex_unlock(&d->lock);
}
static VkResult VKAPI_CALL create_instance(const VkInstanceCreateInfo *info,
                    const VkAllocationCallbacks *allocator, VkInstance *result)
{
    VkLayerInstanceCreateInfo *chain = (void *)info->pNext;
    while (chain && !(chain->sType == VK_STRUCTURE_TYPE_LOADER_INSTANCE_CREATE_INFO &&
                     chain->function == VK_LAYER_LINK_INFO)) chain = (void *)chain->pNext;
    if (!chain) return VK_ERROR_INITIALIZATION_FAILED;
    struct instance *i = calloc(1, sizeof(*i));
    if (!i) return VK_ERROR_OUT_OF_HOST_MEMORY;
    i->gipa = chain->u.pLayerInfo->pfnNextGetInstanceProcAddr;
    i->gpdpa = chain->u.pLayerInfo->pfnNextGetPhysicalDeviceProcAddr;
    chain->u.pLayerInfo = chain->u.pLayerInfo->pNext;
    PFN_vkCreateInstance next = (void *)i->gipa(NULL, "vkCreateInstance");
    VkResult r = next(info, allocator, result);
    if (r != VK_SUCCESS) { free(i); return r; }
    i->handle = *result; i->key = dispatch_key(*result);
    pthread_mutex_lock(&registry); i->next = instances; instances = i; pthread_mutex_unlock(&registry);
    return r;
}
static void VKAPI_CALL destroy_instance(VkInstance handle, const VkAllocationCallbacks *allocator)
{
    struct instance *i = find_instance(handle);
    PFN_vkDestroyInstance next = (void *)i->gipa(handle, "vkDestroyInstance");
    next(handle, allocator);
    pthread_mutex_lock(&registry);
    struct instance **link = &instances;
    while (*link != i) link = &(*link)->next;
    *link = i->next;
    pthread_mutex_unlock(&registry); free(i);
}
static VkResult VKAPI_CALL create_device(VkPhysicalDevice gpu, const VkDeviceCreateInfo *info,
                    const VkAllocationCallbacks *allocator, VkDevice *result)
{
    struct instance *i = find_instance(gpu);
    VkLayerDeviceCreateInfo *chain = (void *)info->pNext;
    while (chain && !(chain->sType == VK_STRUCTURE_TYPE_LOADER_DEVICE_CREATE_INFO &&
                     chain->function == VK_LAYER_LINK_INFO)) chain = (void *)chain->pNext;
    if (!chain || !i) return VK_ERROR_INITIALIZATION_FAILED;
    struct device *d = calloc(1, sizeof(*d));
    if (!d) return VK_ERROR_OUT_OF_HOST_MEMORY;
    PFN_vkGetInstanceProcAddr gipa = chain->u.pLayerInfo->pfnNextGetInstanceProcAddr;
    d->gdpa = chain->u.pLayerInfo->pfnNextGetDeviceProcAddr;
    chain->u.pLayerInfo = chain->u.pLayerInfo->pNext;
    PFN_vkCreateDevice next = (void *)gipa(i->handle, "vkCreateDevice");
    VkResult r = next(gpu, info, allocator, result);
    if (r != VK_SUCCESS) { free(d); return r; }
    d->handle = *result; d->key = dispatch_key(*result);
    d->get = (void *)d->gdpa(*result, "vkGetPipelineCacheData");
    d->create = (void *)d->gdpa(*result, "vkCreatePipelineCache");
    d->destroy = (void *)d->gdpa(*result, "vkDestroyPipelineCache");
    pthread_mutex_init(&d->lock, NULL);
    pthread_mutex_lock(&registry); d->next = devices; devices = d; pthread_mutex_unlock(&registry);
    return r;
}
static void VKAPI_CALL destroy_device(VkDevice handle, const VkAllocationCallbacks *allocator)
{
    struct device *d = find_device(handle);
    PFN_vkDestroyDevice next = (void *)d->gdpa(handle, "vkDestroyDevice");
    next(handle, allocator);
    while (d->snapshots) invalidate(d, d->snapshots->cache);
    pthread_mutex_destroy(&d->lock);
    pthread_mutex_lock(&registry);
    struct device **link = &devices;
    while (*link != d) link = &(*link)->next;
    *link = d->next;
    pthread_mutex_unlock(&registry); free(d);
}
static VkResult VKAPI_CALL create_cache(VkDevice handle, const VkPipelineCacheCreateInfo *info,
                    const VkAllocationCallbacks *allocator, VkPipelineCache *result)
{
    struct device *d = find_device(handle);
    VkPipelineCacheCreateInfo local = *info;
    void *decoded = NULL;
    if (cache_is_encoded(info->pInitialData, info->initialDataSize)) {
        size_t size = 0;
        double start = seconds();
        decoded = cache_decode(info->pInitialData, info->initialDataSize, &size);
        local.pInitialData = decoded; local.initialDataSize = size;
        fprintf(stderr, "[zmd-cache] restore packed=%zu raw=%zu valid=%d decode_s=%.3f\n",
                info->initialDataSize, size, decoded != NULL, seconds() - start);
    }
    VkResult r = d->create(handle, &local, allocator, result);
    free(decoded);
    return r;
}
static void VKAPI_CALL destroy_cache(VkDevice handle, VkPipelineCache cache,
                                    const VkAllocationCallbacks *allocator)
{
    struct device *d = find_device(handle);
    invalidate(d, cache); d->destroy(handle, cache, allocator);
}
static VkResult prepare_snapshot(struct device *d, struct snapshot *s)
{
    /* A live cache can grow between calls. Retry boundedly, never call a
     * partial serialization complete or expose an uncompressed oversized blob. */
    for (unsigned attempt = 0; attempt < 3; ++attempt) {
        double start = seconds();
        size_t size = 0;
        VkResult r = d->get(d->handle, s->cache, &size, NULL);
        if (r != VK_SUCCESS) return r;
        if (size < 32 || size > ZMD_CACHE_LIMIT) return VK_ERROR_OUT_OF_HOST_MEMORY;
        void *raw = malloc(size);
        if (!raw) return VK_ERROR_OUT_OF_HOST_MEMORY;
        r = d->get(d->handle, s->cache, &size, raw);
        if (r == VK_SUCCESS) {
            double encoded_at = seconds();
            s->data = cache_encode(raw, size, &s->size);
            free(raw);
            if (!s->data) return VK_ERROR_OUT_OF_HOST_MEMORY;
            fprintf(stderr, "[zmd-cache] snapshot raw=%zu packed=%zu serialize_s=%.3f encode_s=%.3f\n",
                    size, s->size, encoded_at - start, seconds() - encoded_at);
            return VK_SUCCESS;
        }
        free(raw);
        if (r != VK_INCOMPLETE) return r;
    }
    return VK_ERROR_OUT_OF_HOST_MEMORY;
}
static VkResult VKAPI_CALL get_cache(VkDevice handle, VkPipelineCache cache, size_t *size, void *data)
{
    struct device *d = find_device(handle);
    pthread_mutex_lock(&d->lock);
    struct snapshot *s = d->snapshots;
    while (s && s->cache != cache) s = s->next;
    if (!s) {
        s = calloc(1, sizeof(*s));
        if (!s) { pthread_mutex_unlock(&d->lock); return VK_ERROR_OUT_OF_HOST_MEMORY; }
        s->cache = cache; s->next = d->snapshots; d->snapshots = s;
    }
    VkResult r = s->data ? VK_SUCCESS : prepare_snapshot(d, s);
    if (r == VK_SUCCESS) {
        if (!data) *size = s->size;
        else if (*size >= s->size) { memcpy(data, s->data, s->size); *size = s->size; }
        else {
            /* Header-only is valid empty cache data, unlike a truncated
             * compression frame. Unity asks for exactly this before saving. */
            *size = *size >= 32 ? 32 : 0;
            if (*size) memcpy(data, s->data, *size);
            r = VK_INCOMPLETE;
        }
    }
    pthread_mutex_unlock(&d->lock);
    return r;
}
static VkResult VKAPI_CALL graphics(VkDevice handle, VkPipelineCache cache, uint32_t count,
        const VkGraphicsPipelineCreateInfo *info, const VkAllocationCallbacks *allocator, VkPipeline *out)
{
    struct device *d = find_device(handle);
    PFN_vkCreateGraphicsPipelines next = (void *)d->gdpa(handle, "vkCreateGraphicsPipelines");
    VkResult r = next(handle, cache, count, info, allocator, out);
    invalidate(d, cache); return r;
}
static VkResult VKAPI_CALL compute(VkDevice handle, VkPipelineCache cache, uint32_t count,
        const VkComputePipelineCreateInfo *info, const VkAllocationCallbacks *allocator, VkPipeline *out)
{
    struct device *d = find_device(handle);
    PFN_vkCreateComputePipelines next = (void *)d->gdpa(handle, "vkCreateComputePipelines");
    VkResult r = next(handle, cache, count, info, allocator, out);
    invalidate(d, cache); return r;
}
static VkResult VKAPI_CALL merge(VkDevice handle, VkPipelineCache dst, uint32_t count, const VkPipelineCache *src)
{
    struct device *d = find_device(handle);
    PFN_vkMergePipelineCaches next = (void *)d->gdpa(handle, "vkMergePipelineCaches");
    VkResult r = next(handle, dst, count, src);
    invalidate(d, dst); return r;
}
static PFN_vkVoidFunction intercept(const char *name)
{
#define MATCH(api, fn) if (!strcmp(name, #api)) return (PFN_vkVoidFunction)fn
    MATCH(vkGetInstanceProcAddr, get_instance); MATCH(vkGetDeviceProcAddr, get_device);
    MATCH(vkCreateInstance, create_instance); MATCH(vkDestroyInstance, destroy_instance);
    MATCH(vkCreateDevice, create_device); MATCH(vkDestroyDevice, destroy_device);
    MATCH(vkCreatePipelineCache, create_cache); MATCH(vkDestroyPipelineCache, destroy_cache);
    MATCH(vkGetPipelineCacheData, get_cache); MATCH(vkMergePipelineCaches, merge);
    MATCH(vkCreateGraphicsPipelines, graphics); MATCH(vkCreateComputePipelines, compute);
#undef MATCH
    return NULL;
}
static PFN_vkVoidFunction VKAPI_CALL get_instance(VkInstance handle, const char *name)
{
    PFN_vkVoidFunction f = intercept(name);
    if (f) return f;
    struct instance *i = find_instance(handle);
    return i ? i->gipa(handle, name) : NULL;
}
static PFN_vkVoidFunction VKAPI_CALL get_device(VkDevice handle, const char *name)
{
    struct device *d = find_device(handle);
    if (!d) return NULL;
    PFN_vkVoidFunction next = d->gdpa(handle, name);
    return next ? (intercept(name) ? intercept(name) : next) : NULL;
}
static PFN_vkVoidFunction VKAPI_CALL get_physical(VkInstance handle, const char *name)
{
    struct instance *i = find_instance(handle);
    return i && i->gpdpa ? i->gpdpa(handle, name) : NULL;
}
EXPORT VKAPI_ATTR VkResult VKAPI_CALL vkNegotiateLoaderLayerInterfaceVersion(VkNegotiateLayerInterface *version)
{
    if (version->loaderLayerInterfaceVersion < 2) return VK_ERROR_INITIALIZATION_FAILED;
    version->loaderLayerInterfaceVersion = 2;
    version->pfnGetInstanceProcAddr = get_instance;
    version->pfnGetDeviceProcAddr = get_device;
    version->pfnGetPhysicalDeviceProcAddr = get_physical;
    return VK_SUCCESS;
}
