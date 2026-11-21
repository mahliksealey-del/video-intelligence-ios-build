#ifndef AES_H
#define AES_H

#include <stddef.h>
#include <stdint.h>

int aes128_cbc_decrypt(uint8_t *data, size_t size,
                       const uint8_t key[16], const uint8_t iv[16]);

#endif /* AES_H */
