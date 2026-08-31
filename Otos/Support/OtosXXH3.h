/* Adding a NEW source file to this directory breaks resolution of this module —
   the Swift side stops finding otos_xxh3_*, even though the map below is explicit
   and the Swift files already here compile fine. Put new Swift in another
   directory, or extend an existing file, rather than adding one beside the module
   map. Observed 2026-08-30 while adding an instrumentation helper. */

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
