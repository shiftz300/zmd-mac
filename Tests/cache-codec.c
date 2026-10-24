#include <assert.h>
#include <stdio.h>
#include <sys/mman.h>
#include "../Sources/VulkanCache/cache_codec.h"

int main(int argc, char **argv)
{
    size_t size = argc > 1 && !strcmp(argv[1], "--large") ? (UINT64_C(1) << 32) + 65537 : 16 * 1024 * 1024 + 7;
    unsigned char *raw = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    assert(raw != MAP_FAILED);
    memset(raw, 0xab, 32); raw[size - 1] = 0x7e;
    size_t packed_size = 0, decoded_size = 0;
    unsigned char *packed = cache_encode(raw, size, &packed_size);
    assert(packed && packed_size < INT32_MAX && cache_is_encoded(packed, packed_size));
    unsigned char *decoded = cache_decode(packed, packed_size, &decoded_size);
    assert(decoded && decoded_size == size && !memcmp(decoded, raw, size));
    free(decoded);
    assert(!cache_decode(packed, packed_size - 1, &decoded_size));
    packed[64] ^= 1;
    assert(!cache_decode(packed, packed_size, &decoded_size));
    packed[64] ^= 1;
    /* Last byte is the frame checksum; corrupted payloads must not load. */
    packed[packed_size - 1] ^= 1;
    assert(!cache_decode(packed, packed_size, &decoded_size));
    packed[packed_size - 1] ^= 1;
    packed[68] ^= 4;
    assert(!cache_decode(packed, packed_size, &decoded_size));
    packed[68] ^= 4;
    packed[0] ^= 1;
    assert(!cache_decode(packed, packed_size, &decoded_size));
    packed[0] ^= 1;
    uint64_t invalid = ZMD_CACHE_LIMIT + 1;
    memcpy(packed + 48, &invalid, 8);
    assert(!cache_decode(packed, packed_size, &decoded_size));
    assert(!cache_decode(packed, 64, &decoded_size));
    printf("PASS: codec raw=%zu packed=%zu exact round-trip, truncation, corruption, size bounds\n", size, packed_size);
    free(packed); munmap(raw, size);
    return 0;
}
