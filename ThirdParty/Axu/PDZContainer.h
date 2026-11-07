#pragma once
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
// Local PDZ 1.00/1.01, currently valid type-0 certificates, Blowfish pages.
// No network login or support for account-bound authorization.
// Returns an ordinary in-memory ZIP archive for the existing book pipeline.
// 0 = success. Caller frees *output with pdg_free. Outputs reset on any failure.
int pdz_to_uvz(const uint8_t *input, size_t length, uint8_t **output,
               size_t *outputLength, char *error, size_t errorCapacity);
#ifdef __cplusplus
}
#endif
