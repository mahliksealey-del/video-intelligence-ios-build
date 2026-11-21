// iOS CommonCrypto adapter replacing upstream mbedTLS dependency.
// Does not bypass FairPlay/DRM. Only public HLS AES-128 segment keys are
// considered; Swift's playlist preflight rejects SAMPLE-AES and protected
// key formats.
#import <CommonCrypto/CommonCryptor.h>
#include <stdint.h>
#include <stddef.h>
#include "aes.h"
#include "hls2mp4.h"

int aes128_cbc_decrypt(uint8_t *data, size_t size,
                       const uint8_t key[16], const uint8_t iv[16]) {
    if (!data || !key || !iv || (size % 16) != 0)
        return HLS2MP4_ERR_DECRYPT;
    if (!size) return HLS2MP4_OK;
    size_t moved = 0;
    CCCryptorStatus status = CCCrypt(kCCDecrypt, kCCAlgorithmAES, 0,
                                     key, 16, iv, data, size,
                                     data, size, &moved);
    return status == kCCSuccess && moved == size
        ? HLS2MP4_OK : HLS2MP4_ERR_DECRYPT;
}
