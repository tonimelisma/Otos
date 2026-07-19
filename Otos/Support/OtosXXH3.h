#ifndef OTOS_XXH3_H
#define OTOS_XXH3_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct OtosXXH3State OtosXXH3State;

OtosXXH3State *otos_xxh3_create(void);
void otos_xxh3_free(OtosXXH3State *state);
int otos_xxh3_reset(OtosXXH3State *state);
int otos_xxh3_update(OtosXXH3State *state, const void *input, size_t length);
int otos_xxh3_digest(const OtosXXH3State *state, unsigned char output[16]);

#ifdef __cplusplus
}
#endif

#endif
