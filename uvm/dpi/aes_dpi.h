//============================================================================
// File: aes_dpi.h
// Description:
//   DPI-C header for linking AES-128 golden model with SystemVerilog.
//============================================================================

#ifndef AES_DPI_H
#define AES_DPI_H

#include "svdpi.h"

#ifdef __cplusplus
extern "C" {
#endif

// DPI-C export: called from SystemVerilog scoreboard
// Takes key[16] and plaintext[16], returns ciphertext[16]
// All arrays are byte-level, big-endian (MSB first)
void aes_encrypt_dpi(
    const svOpenArrayHandle key_in,       // input:  16-byte key
    const svOpenArrayHandle pt_in,        // input:  16-byte plaintext
    svOpenArrayHandle       ct_out        // output: 16-byte ciphertext
);

#ifdef __cplusplus
}
#endif

#endif // AES_DPI_H
