/* Opaque Vulkan cache envelope: public header, lengths, checksummed zstd frame. */
#pragma once
#include <zstd.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#define ZMD_CACHE_LIMIT (UINT64_C(8) * 1024 * 1024 * 1024)
#define ZMD_CACHE_HEADER 64
static const unsigned char zmd_magic[16] = "ZMD-ZSTD-PSO-1";

/* Caller owns result. One compression pass, bounded below the game's signed
 * 32-bit write limit. Large caches use four workers; small ones stay inline. */
static void *cache_encode(const void *raw, size_t size, size_t *encoded_size)
{
    if (size < 32 || size > ZMD_CACHE_LIMIT) return NULL;
    size_t capacity = ZSTD_compressBound(size);
    if (capacity > INT32_MAX - ZMD_CACHE_HEADER) capacity = INT32_MAX - ZMD_CACHE_HEADER;
    unsigned char *data = malloc(capacity + ZMD_CACHE_HEADER);
    if (!data) return NULL;
    ZSTD_CCtx *ctx = ZSTD_createCCtx();
    if (!ctx) { free(data); return NULL; }
    size_t n = 0;
    if (!ZSTD_isError(ZSTD_CCtx_setParameter(ctx, ZSTD_c_compressionLevel, 1)) &&
        !ZSTD_isError(ZSTD_CCtx_setParameter(ctx, ZSTD_c_checksumFlag, 1)) &&
        !ZSTD_isError(ZSTD_CCtx_setParameter(ctx, ZSTD_c_nbWorkers, size >= 16 * 1024 * 1024 ? 4 : 0))) {
        n = ZSTD_compress2(ctx, data + ZMD_CACHE_HEADER, capacity, raw, size);
    }
    ZSTD_freeCCtx(ctx);
    if (!n || ZSTD_isError(n)) { free(data); return NULL; }
    memcpy(data, raw, 32);
    memcpy(data + 32, zmd_magic, 16);
    uint64_t raw_size = size, packed_size = n;
    memcpy(data + 48, &raw_size, 8);
    memcpy(data + 56, &packed_size, 8);
    *encoded_size = n + ZMD_CACHE_HEADER;
    void *compact = realloc(data, *encoded_size);
    return compact ? compact : data;
}

static int cache_is_encoded(const void *data, size_t size)
{
    return size >= 48 && !memcmp((const char *)data + 32, zmd_magic, 16);
}

static void *cache_decode(const void *encoded, size_t size, size_t *raw_size)
{
    if (size < ZMD_CACHE_HEADER || !cache_is_encoded(encoded, size)) return NULL;
    const unsigned char *data = encoded, *frame = data + ZMD_CACHE_HEADER;
    uint64_t n, packed;
    memcpy(&n, data + 48, 8);
    memcpy(&packed, data + 56, 8);
    if (n < 32 || n > ZMD_CACHE_LIMIT || size > INT32_MAX ||
        packed != size - ZMD_CACHE_HEADER || packed < 5) return NULL;
    /* Require one standard frame with a content checksum (descriptor bit 2).
     * zstd validates that checksum during decompression, without a SHA pass. */
    if (memcmp(frame, "\x28\xb5\x2f\xfd", 4) || !(frame[4] & 4) ||
        ZSTD_getFrameContentSize(frame, packed) != n ||
        ZSTD_findFrameCompressedSize(frame, packed) != packed) return NULL;
    unsigned char *raw = malloc(n);
    if (!raw) return NULL;
    size_t written = ZSTD_decompress(raw, n, frame, packed);
    if (!ZSTD_isError(written) && written == n && !memcmp(raw, data, 32)) {
        *raw_size = n;
        return raw;
    }
    free(raw);
    return NULL;
}
