package axium

import "core:c"
import "core:encoding/base64"
import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:strings"
import "core:sys/posix"

// --- Socket state ---

keepass_socket: posix.FD = posix.FD(-1)

client_public_key:  [crypto_box_PUBLICKEYBYTES]u8
client_secret_key:  [crypto_box_SECRETKEYBYTES]u8
server_public_key:  [crypto_box_PUBLICKEYBYTES]u8
client_id:          [crypto_box_NONCEBYTES]u8
current_nonce:      [crypto_box_NONCEBYTES]u8

// Recv buffer — reused across calls
@(private)
recv_buf: [64 * 1024]u8

// --- Socket operations ---

keepass_connect :: proc() -> bool {
    runtime_dir := posix.getenv("XDG_RUNTIME_DIR")
    if runtime_dir == nil do return false

    path := fmt.tprintf("%s/app/org.keepassxc.KeePassXC/org.keepassxc.KeePassXC.BrowserServer", runtime_dir)

    addr: posix.sockaddr_un
    addr.sun_family = .UNIX
    path_bytes := transmute([]u8)path
    if len(path_bytes) >= len(addr.sun_path) do return false
    for i in 0..<len(path_bytes) {
        addr.sun_path[i] = c.char(path_bytes[i])
    }

    fd := posix.socket(.UNIX, .STREAM)
    if fd < 0 do return false

    res := posix.connect(fd, cast(^posix.sockaddr)&addr, size_of(posix.sockaddr_un))
    if res != .OK {
        posix.close(fd)
        return false
    }

    // Set non-blocking
    flags := posix.fcntl(fd, .GETFL)
    posix.fcntl(fd, .SETFL, flags | c.int(posix.O_Flags{.NONBLOCK}))

    keepass_socket = fd

    // Generate session keypair and client ID
    crypto_box_keypair(&client_public_key[0], &client_secret_key[0])
    randombytes_buf(&client_id, crypto_box_NONCEBYTES)

    return true
}

keepass_disconnect :: proc() {
    if keepass_socket >= 0 {
        posix.close(keepass_socket)
        keepass_socket = posix.FD(-1)
    }
}

keepass_fd :: proc() -> c.int {
    return c.int(keepass_socket)
}

keepass_send :: proc(data: string) {
    if keepass_socket < 0 do return
    bytes := transmute([]u8)data
    posix.write(keepass_socket, raw_data(bytes), len(bytes))
}

keepass_recv :: proc() -> (string, bool) {
    if keepass_socket < 0 do return "", false
    n := posix.read(keepass_socket, &recv_buf[0], len(recv_buf))
    if n <= 0 do return "", false
    return string(recv_buf[:n]), true
}

// --- Key exchange ---

keepass_exchange_keys :: proc() -> bool {
    pk_b64 := base64_encode(client_public_key[:])
    id_b64 := base64_encode(client_id[:])
    defer delete(pk_b64)
    defer delete(id_b64)

    msg := fmt.tprintf(
        `{{"action":"change-public-keys","publicKey":"%s","nonce":"%s","clientID":"%s"}}`,
        pk_b64, id_b64, id_b64,
    )
    keepass_send(msg)

    // Wait for response (blocking with timeout)
    pfd := posix.pollfd{fd = keepass_socket, events = {.IN}}
    if posix.poll(&pfd, 1, 3000) <= 0 do return false

    data, ok := keepass_recv()
    if !ok do return false

    // Parse response
    parsed, err := json.parse(transmute([]u8)data)
    if err != .None do return false
    defer json.destroy_value(parsed)

    root, rok := parsed.(json.Object)
    if !rok do return false

    success := root["success"].(json.String) or_else ""
    if success != "true" do return false

    server_pk_b64 := root["publicKey"].(json.String) or_else ""
    if server_pk_b64 == "" do return false

    server_pk, dok := base64_decode(server_pk_b64)
    if !dok do return false
    defer delete(server_pk)
    if len(server_pk) != crypto_box_PUBLICKEYBYTES do return false

    mem.copy(&server_public_key[0], raw_data(server_pk), crypto_box_PUBLICKEYBYTES)
    return true
}

// --- Encrypt / Decrypt ---

keepass_encrypt :: proc(msg: string) -> string {
    msg_bytes := transmute([]u8)msg
    ct_len := len(msg_bytes) + crypto_box_MACBYTES
    ct := make([]u8, ct_len)

    // Generate fresh nonce
    randombytes_buf(&current_nonce, crypto_box_NONCEBYTES)

    rc := crypto_box_easy(
        raw_data(ct), raw_data(msg_bytes), c.ulonglong(len(msg_bytes)),
        &current_nonce[0], &server_public_key[0], &client_secret_key[0],
    )
    if rc != 0 {
        delete(ct)
        return ""
    }

    result := base64_encode(ct[:])
    delete(ct)
    return result
}

keepass_decrypt :: proc(b64_ct: string) -> (result: string, ok: bool) {
    ct, dok := base64_decode(b64_ct)
    if !dok do return "", false
    defer delete(ct)

    if len(ct) < crypto_box_MACBYTES do return "", false

    msg_len := len(ct) - crypto_box_MACBYTES
    msg := make([]u8, msg_len)

    // Response nonce = request nonce incremented by 1
    response_nonce := current_nonce
    sodium_increment(&response_nonce[0], crypto_box_NONCEBYTES)

    rc := crypto_box_open_easy(
        raw_data(msg), raw_data(ct), c.ulonglong(len(ct)),
        &response_nonce[0], &server_public_key[0], &client_secret_key[0],
    )
    if rc != 0 {
        delete(msg)
        return "", false
    }

    return string(msg), true
}

// --- Request builder ---

keepass_build_request :: proc(action: string, message: string) -> string {
    encrypted := keepass_encrypt(message)
    nonce_b64 := base64_encode(current_nonce[:])
    id_b64 := base64_encode(client_id[:])
    defer delete(encrypted)
    defer delete(nonce_b64)
    defer delete(id_b64)

    return fmt.aprintf(
        `{{"action":"%s","message":"%s","nonce":"%s","clientID":"%s"}}`,
        action, encrypted, nonce_b64, id_b64,
    )
}

// --- Base64 helpers ---

@(private)
base64_encode :: proc(data: []u8) -> string {
    return base64.encode(data)
}

@(private)
base64_decode :: proc(s: string) -> ([]u8, bool) {
    result, err := base64.decode(s)
    if err != nil do return nil, false
    return result, true
}
