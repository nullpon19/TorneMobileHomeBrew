// Fast FIPS-197 AES-128-CBC decryption for DTCP-IP PCP streams (Fire TV optimization).
//
// Replacing pure-Dart pointycastle AESEngine on Android avoids pinning the main
// UI isolate for tens of seconds during fast LAN bursts (which triggered ANRs
// on 32-bit Fire TV Stick). S-boxes and inverse T-tables are derived once from
// GF(2^8) arithmetic and verified against NIST SP 800-38A / pointycastle tests.

#include <pthread.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>

#if defined(__GNUC__) || defined(__clang__)
#define TMHB_EXPORT __attribute__((visibility("default"))) __attribute__((used))
#else
#define TMHB_EXPORT
#endif

static uint8_t sbox[256];
static uint8_t inv_sbox[256];
static uint32_t td0[256];
static uint32_t td1[256];
static uint32_t td2[256];
static uint32_t td3[256];
static pthread_once_t tables_once = PTHREAD_ONCE_INIT;

static inline uint8_t gf_mul(uint8_t a, uint8_t b) {
    uint8_t p = 0;
    for (int i = 0; i < 8; i++) {
        if (b & 1) {
            p ^= a;
        }
        uint8_t hi = (uint8_t)(a & 0x80u);
        a <<= 1;
        if (hi) {
            a ^= 0x1bu;
        }
        b >>= 1;
    }
    return p;
}

static inline uint8_t rotl8(uint8_t x, int shift) {
    return (uint8_t)((x << shift) | (x >> (8 - shift)));
}

static inline uint32_t rotr32(uint32_t x, int shift) {
    return (x >> shift) | (x << (32 - shift));
}

static void init_tables(void) {
    uint8_t pow_tbl[256];
    uint8_t log_tbl[256];
    uint8_t x = 1;
    for (int i = 0; i < 256; i++) {
        pow_tbl[i] = x;
        log_tbl[x] = (uint8_t)i;
        // Generator 0x03 in GF(2^8) with polynomial 0x11b: x * 3 = (x << 1 ^ reduce) ^ x
        uint8_t hi = (uint8_t)(x & 0x80u);
        uint8_t x2 = (uint8_t)((x << 1) ^ (hi ? 0x1bu : 0u));
        x = (uint8_t)(x2 ^ x);
    }

    sbox[0] = 0x63u;
    inv_sbox[0x63u] = 0;
    for (int a = 1; a < 256; a++) {
        uint8_t inv = pow_tbl[255 - log_tbl[a]];
        uint8_t s = (uint8_t)(inv ^ rotl8(inv, 1) ^ rotl8(inv, 2) ^
                              rotl8(inv, 3) ^ rotl8(inv, 4) ^ 0x63u);
        sbox[a] = s;
        inv_sbox[s] = (uint8_t)a;
    }

    for (int i = 0; i < 256; i++) {
        uint8_t isb = inv_sbox[i];
        uint32_t m0 = gf_mul(0x0eu, isb);
        uint32_t m1 = gf_mul(0x09u, isb);
        uint32_t m2 = gf_mul(0x0du, isb);
        uint32_t m3 = gf_mul(0x0bu, isb);
        uint32_t t0 = (m0 << 24) | (m1 << 16) | (m2 << 8) | m3;
        td0[i] = t0;
        td1[i] = rotr32(t0, 8);
        td2[i] = rotr32(t0, 16);
        td3[i] = rotr32(t0, 24);
    }
}

static inline uint32_t load_be32(const uint8_t* p) {
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) |
           ((uint32_t)p[2] << 8) | (uint32_t)p[3];
}

static inline void store_be32(uint8_t* p, uint32_t v) {
    p[0] = (uint8_t)(v >> 24);
    p[1] = (uint8_t)(v >> 16);
    p[2] = (uint8_t)(v >> 8);
    p[3] = (uint8_t)v;
}

TMHB_EXPORT void* tmhb_aes_alloc(size_t size) {
    return malloc(size == 0 ? 1 : size);
}

TMHB_EXPORT void tmhb_aes_free(void* ptr) {
    free(ptr);
}

// Expands a 16-byte AES-128 key into 44 uint32_t decryption round keys
// ordered for the Equivalent Inverse Cipher (rounds 1..9 have InvMixColumns).
TMHB_EXPORT void tmhb_aes128_expand_dec_key(const uint8_t* key, uint32_t* rk) {
    static const uint32_t rcon[11] = {
        0x00000000u, 0x01000000u, 0x02000000u, 0x04000000u,
        0x08000000u, 0x10000000u, 0x20000000u, 0x40000000u,
        0x80000000u, 0x1b000000u, 0x36000000u,
    };
    pthread_once(&tables_once, init_tables);

    uint32_t ek[44];
    for (int i = 0; i < 4; i++) {
        ek[i] = load_be32(key + i * 4);
    }
    for (int i = 4; i < 44; i++) {
        uint32_t temp = ek[i - 1];
        if ((i & 3) == 0) {
            temp = (temp << 8) | (temp >> 24);
            temp = ((uint32_t)sbox[(temp >> 24) & 0xffu] << 24) |
                   ((uint32_t)sbox[(temp >> 16) & 0xffu] << 16) |
                   ((uint32_t)sbox[(temp >> 8) & 0xffu] << 8) |
                   ((uint32_t)sbox[temp & 0xffu]);
            temp ^= rcon[i >> 2];
        }
        ek[i] = ek[i - 4] ^ temp;
    }

    // First decryption round key = last encryption round key.
    for (int j = 0; j < 4; j++) {
        rk[j] = ek[40 + j];
    }
    // Middle round keys pass through InvMixColumns via td*(sbox[*]).
    for (int r = 1; r < 10; r++) {
        int src_base = (10 - r) * 4;
        int dst_base = r * 4;
        for (int j = 0; j < 4; j++) {
            uint32_t w = ek[src_base + j];
            rk[dst_base + j] =
                td0[sbox[(w >> 24) & 0xffu]] ^
                td1[sbox[(w >> 16) & 0xffu]] ^
                td2[sbox[(w >> 8) & 0xffu]] ^
                td3[sbox[w & 0xffu]];
        }
    }
    // Final decryption round key = initial encryption key.
    for (int j = 0; j < 4; j++) {
        rk[40 + j] = ek[j];
    }
}

// Decrypts [len] bytes (must be a multiple of 16) in AES-128-CBC mode.
// Supports in-place operation (src == dst) and updates [iv] (16 bytes)
// to the last ciphertext block processed.
TMHB_EXPORT void tmhb_aes128_cbc_decrypt(const uint32_t* rk, uint8_t* iv,
                                         const uint8_t* src, uint8_t* dst,
                                         size_t len) {
    pthread_once(&tables_once, init_tables);
    size_t blocks = len >> 4;
    if (blocks == 0) {
        return;
    }

    uint32_t c0 = load_be32(iv);
    uint32_t c1 = load_be32(iv + 4);
    uint32_t c2 = load_be32(iv + 8);
    uint32_t c3 = load_be32(iv + 12);

    for (size_t b = 0; b < blocks; b++) {
        const uint8_t* sp = src + (b << 4);
        uint8_t* dp = dst + (b << 4);

        uint32_t in0 = load_be32(sp);
        uint32_t in1 = load_be32(sp + 4);
        uint32_t in2 = load_be32(sp + 8);
        uint32_t in3 = load_be32(sp + 12);

        uint32_t s0 = in0 ^ rk[0];
        uint32_t s1 = in1 ^ rk[1];
        uint32_t s2 = in2 ^ rk[2];
        uint32_t s3 = in3 ^ rk[3];

        for (int r = 1; r < 10; r++) {
            const uint32_t* rkp = rk + (r << 2);
            uint32_t t0 = td0[(s0 >> 24) & 0xffu] ^ td1[(s3 >> 16) & 0xffu] ^
                          td2[(s2 >> 8) & 0xffu] ^ td3[s1 & 0xffu] ^ rkp[0];
            uint32_t t1 = td0[(s1 >> 24) & 0xffu] ^ td1[(s0 >> 16) & 0xffu] ^
                          td2[(s3 >> 8) & 0xffu] ^ td3[s2 & 0xffu] ^ rkp[1];
            uint32_t t2 = td0[(s2 >> 24) & 0xffu] ^ td1[(s1 >> 16) & 0xffu] ^
                          td2[(s0 >> 8) & 0xffu] ^ td3[s3 & 0xffu] ^ rkp[2];
            uint32_t t3 = td0[(s3 >> 24) & 0xffu] ^ td1[(s2 >> 16) & 0xffu] ^
                          td2[(s1 >> 8) & 0xffu] ^ td3[s0 & 0xffu] ^ rkp[3];
            s0 = t0;
            s1 = t1;
            s2 = t2;
            s3 = t3;
        }

        uint32_t p0 = (((uint32_t)inv_sbox[(s0 >> 24) & 0xffu] << 24) |
                       ((uint32_t)inv_sbox[(s3 >> 16) & 0xffu] << 16) |
                       ((uint32_t)inv_sbox[(s2 >> 8) & 0xffu] << 8) |
                       ((uint32_t)inv_sbox[s1 & 0xffu])) ^
                      rk[40] ^ c0;
        uint32_t p1 = (((uint32_t)inv_sbox[(s1 >> 24) & 0xffu] << 24) |
                       ((uint32_t)inv_sbox[(s0 >> 16) & 0xffu] << 16) |
                       ((uint32_t)inv_sbox[(s3 >> 8) & 0xffu] << 8) |
                       ((uint32_t)inv_sbox[s2 & 0xffu])) ^
                      rk[41] ^ c1;
        uint32_t p2 = (((uint32_t)inv_sbox[(s2 >> 24) & 0xffu] << 24) |
                       ((uint32_t)inv_sbox[(s1 >> 16) & 0xffu] << 16) |
                       ((uint32_t)inv_sbox[(s0 >> 8) & 0xffu] << 8) |
                       ((uint32_t)inv_sbox[s3 & 0xffu])) ^
                      rk[42] ^ c2;
        uint32_t p3 = (((uint32_t)inv_sbox[(s3 >> 24) & 0xffu] << 24) |
                       ((uint32_t)inv_sbox[(s2 >> 16) & 0xffu] << 16) |
                       ((uint32_t)inv_sbox[(s1 >> 8) & 0xffu] << 8) |
                       ((uint32_t)inv_sbox[s0 & 0xffu])) ^
                      rk[43] ^ c3;

        store_be32(dp, p0);
        store_be32(dp + 4, p1);
        store_be32(dp + 8, p2);
        store_be32(dp + 12, p3);

        c0 = in0;
        c1 = in1;
        c2 = in2;
        c3 = in3;
    }

    store_be32(iv, c0);
    store_be32(iv + 4, c1);
    store_be32(iv + 8, c2);
    store_be32(iv + 12, c3);
}
