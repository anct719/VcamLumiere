#include <stdint.h>
#include <stdio.h>
#include "monocypher-ed25519.h"

static int hex_to_bytes(const char *hex, uint8_t *out, size_t length) {
    for (size_t i = 0; i < length; i++) {
        unsigned int byte = 0;
        if (sscanf(hex + (i * 2), "%2x", &byte) != 1) return -1;
        out[i] = (uint8_t)byte;
    }
    return 0;
}

int main(void) {
    // RFC 8032 test vector 1: empty message.
    uint8_t public_key[32];
    uint8_t signature[64];
    const uint8_t empty_message[1] = {0};

    if (hex_to_bytes("d75a980182b10ab7d54bfed3c964073a"
                     "0ee172f3daa62325af021a68f707511a",
                     public_key, sizeof(public_key)) != 0 ||
        hex_to_bytes("e5564300c360ac729086e2cc806e828a"
                     "84877f1eb8e5d974d873e06522490155"
                     "5fb8821590a33bacc61e39701cf9b46b"
                     "d25bf5f0595bbe24655141438e7a100b",
                     signature, sizeof(signature)) != 0) {
        return 1;
    }

    if (crypto_ed25519_check(signature, public_key, empty_message, 0) != 0) {
        fprintf(stderr, "valid Ed25519 signature was rejected\n");
        return 1;
    }

    signature[0] ^= 1;
    if (crypto_ed25519_check(signature, public_key, empty_message, 0) == 0) {
        fprintf(stderr, "tampered Ed25519 signature was accepted\n");
        return 1;
    }

    puts("Ed25519 verification tests passed");
    return 0;
}
