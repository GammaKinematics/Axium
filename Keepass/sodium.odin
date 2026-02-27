package axium

import "core:c"

foreign import sodium_lib "system:sodium"

crypto_box_PUBLICKEYBYTES :: 32
crypto_box_SECRETKEYBYTES :: 32
crypto_box_NONCEBYTES     :: 24
crypto_box_MACBYTES        :: 16

@(default_calling_convention = "c")
foreign sodium_lib {
    sodium_init          :: proc() -> c.int ---
    randombytes_buf      :: proc(buf: rawptr, size: c.size_t) ---
    crypto_box_keypair   :: proc(pk: [^]u8, sk: [^]u8) -> c.int ---
    crypto_box_easy      :: proc(ct: [^]u8, msg: [^]u8, mlen: c.ulonglong,
                                 nonce: [^]u8, pk: [^]u8, sk: [^]u8) -> c.int ---
    crypto_box_open_easy :: proc(msg: [^]u8, ct: [^]u8, clen: c.ulonglong,
                                 nonce: [^]u8, pk: [^]u8, sk: [^]u8) -> c.int ---
    sodium_increment     :: proc(n: [^]u8, nlen: c.size_t) ---
}
