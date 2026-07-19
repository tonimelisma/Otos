#include "OtosXXH3.h"

#include "../Vendor/xxHash-0.8.3/xxhash.h"

#include <stdlib.h>
#include <string.h>

struct OtosXXH3State {
    XXH3_state_t *state;
};

OtosXXH3State *otos_xxh3_create(void) {
    OtosXXH3State *wrapper = (OtosXXH3State *)malloc(sizeof(OtosXXH3State));
    if (wrapper == NULL) {
        return NULL;
    }
    wrapper->state = XXH3_createState();
    if (wrapper->state == NULL) {
        free(wrapper);
        return NULL;
    }
    return wrapper;
}

void otos_xxh3_free(OtosXXH3State *wrapper) {
    if (wrapper == NULL) {
        return;
    }
    XXH3_freeState(wrapper->state);
    free(wrapper);
}

int otos_xxh3_reset(OtosXXH3State *wrapper) {
    if (wrapper == NULL) {
        return XXH_ERROR;
    }
    return XXH3_128bits_reset(wrapper->state);
}

int otos_xxh3_update(OtosXXH3State *wrapper, const void *input, size_t length) {
    if (wrapper == NULL) {
        return XXH_ERROR;
    }
    return XXH3_128bits_update(wrapper->state, input, length);
}

int otos_xxh3_digest(const OtosXXH3State *wrapper, unsigned char output[16]) {
    if (wrapper == NULL || wrapper->state == NULL || output == NULL) {
        return XXH_ERROR;
    }
    XXH128_canonical_t canonical;
    XXH128_hash_t digest = XXH3_128bits_digest(wrapper->state);
    XXH128_canonicalFromHash(&canonical, digest);
    memcpy(output, canonical.digest, sizeof(canonical.digest));
    return XXH_OK;
}
