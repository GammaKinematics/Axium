package axium

import "base:runtime"
import "core:c"
import "core:crypto/ed25519"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:sys/linux"

// ---------------------------------------------------------------------------
// Extension process state
// ---------------------------------------------------------------------------

Ext_Process :: struct {
    name:       string,
    path:       string,    // full path to executable
    pid:        linux.Pid,
    control_fd: linux.Fd,  // socketpair to extension process
}

ext_processes: [dynamic]Ext_Process

// ---------------------------------------------------------------------------
// SCM_RIGHTS support (not in Odin's linux package)
// ---------------------------------------------------------------------------

SCM_RIGHTS :: 1

CMsg_Hdr :: struct {
    len:   uint,     // cmsg_len
    level: i32,      // SOL_SOCKET
    type_: i32,      // SCM_RIGHTS
}

// Send a file descriptor over a unix socket via SCM_RIGHTS.
send_fd :: proc(sock: linux.Fd, fd: linux.Fd) -> bool {
    // Ancillary data buffer: cmsghdr + one fd
    CMSG_SIZE :: size_of(CMsg_Hdr) + size_of(linux.Fd)
    // Align to uint boundary
    BUF_SIZE  :: (CMSG_SIZE + size_of(uint) - 1) & ~(size_of(uint) - 1)

    buf: [BUF_SIZE]u8
    mem.zero(&buf[0], BUF_SIZE)

    cmsg := cast(^CMsg_Hdr)&buf[0]
    cmsg.len   = CMSG_SIZE
    cmsg.level = i32(linux.SOL_SOCKET)
    cmsg.type_ = SCM_RIGHTS

    // Copy fd into cmsg data area (right after the header)
    fd_val := fd
    mem.copy(&buf[size_of(CMsg_Hdr)], &fd_val, size_of(linux.Fd))

    // Need at least 1 byte of real data for sendmsg
    dummy: u8 = 0
    iov := linux.IO_Vec{
        base = &dummy,
        len  = 1,
    }

    msg := linux.Msg_Hdr{
        iov     = {iov},
        control = buf[:],
    }

    _, errno := linux.sendmsg(sock, &msg, {})
    if errno != .NONE {
        fmt.eprintln("[ext] send_fd failed:", errno)
        return false
    }
    return true
}

// ---------------------------------------------------------------------------
// Init — scan, verify, launch
// ---------------------------------------------------------------------------

extension_init :: proc() {
    dir_path := xdg_path(.Config, "extensions/")
    os.make_directory(dir_path)

    dh, err := os.open(dir_path)
    if err != nil do return
    defer os.close(dh)

    entries, rerr := os.read_dir(dh, -1)
    if rerr != nil do return
    defer delete(entries)

    for entry in entries {
        name := entry.name
        if !strings.has_suffix(name, ".axe") do continue

        exe_path := strings.concatenate({dir_path, name})
        sig_path := strings.concatenate({exe_path, ".sig"})

        // Read executable + signature
        exe_data, eok := os.read_entire_file(exe_path)
        if !eok {
            fmt.eprintln("[ext] failed to read:", name)
            delete(exe_path)
            delete(sig_path)
            continue
        }

        sig_data, sok := os.read_entire_file(sig_path)
        if !sok {
            fmt.eprintln("[ext]", name, "— no .sig file, skipping")
            delete(exe_data)
            delete(exe_path)
            delete(sig_path)
            continue
        }
        delete(sig_path)

        // Verify ed25519 signature
        if !ext_verify_signature(exe_data, sig_data) {
            fmt.eprintln("[ext]", name, "— signature verification failed")
            delete(exe_data)
            delete(sig_data)
            delete(exe_path)
            continue
        }
        delete(exe_data)
        delete(sig_data)

        // Launch
        ext_name := strings.clone(name[:len(name) - 4]) // strip .axe
        if extension_launch(ext_name, exe_path) {
            fmt.eprintln("[ext]", ext_name, "— launched")
        } else {
            delete(ext_name)
            delete(exe_path)
        }
    }

    fmt.eprintln("[ext] init:", len(ext_processes), "extension(s) running")
}

// ---------------------------------------------------------------------------
// Launch — fork/exec with control socketpair
// ---------------------------------------------------------------------------

extension_launch :: proc(name: string, exe_path: string) -> bool {
    // Create control socketpair
    pair: [2]linux.Fd
    errno := linux.socketpair(.UNIX, .STREAM, {}, &pair)
    if errno != .NONE {
        fmt.eprintln("[ext]", name, "— socketpair failed:", errno)
        return false
    }

    pid, ferr := linux.fork()
    if ferr != .NONE {
        fmt.eprintln("[ext]", name, "— fork failed:", ferr)
        linux.close(pair[0])
        linux.close(pair[1])
        return false
    }

    if pid == 0 {
        // Child — becomes the extension process
        linux.close(pair[0]) // parent's end

        // Set AXIUM_CONTROL_FD env var so extension knows its control fd
        fd_str := fmt.tprintf("%d", i32(pair[1]))
        fd_env := strings.clone_to_cstring(fmt.tprintf("AXIUM_CONTROL_FD=%s", fd_str))
        path_cstr := strings.clone_to_cstring(exe_path)

        argv := [?]cstring{path_cstr, nil}
        envp: [dynamic]cstring
        defer delete(envp)

        // Pass through existing env + our control fd
        for entry in os.environ() {
            append(&envp, strings.clone_to_cstring(entry))
        }
        append(&envp, fd_env)
        append(&envp, nil)

        linux.execve(path_cstr, &argv[0], raw_data(envp[:]))
        // If we get here, exec failed
        linux.exit_group(1)
    }

    // Parent
    linux.close(pair[1]) // child's end

    append(&ext_processes, Ext_Process{
        name       = name,
        path       = exe_path,
        pid        = pid,
        control_fd = pair[0],
    })
    return true
}

// ---------------------------------------------------------------------------
// Fd callback — called from engine.c per WebProcess creation
// ---------------------------------------------------------------------------

@(export)
axium_get_ext_fds :: proc "c" (out_fds: ^[^]c.int) -> c.int {
    context = runtime.default_context()

    count := len(ext_processes)
    if count == 0 {
        out_fds^ = nil
        return 0
    }

    // Allocate fd array (caller doesn't free — static buffer is fine)
    @(static) fds: [64]c.int
    if count > 64 do count = 64

    actual := 0
    for i in 0..<count {
        ext := &ext_processes[i]

        // Create socketpair: one end for WebProcess, one for extension
        pair: [2]linux.Fd
        errno := linux.socketpair(.UNIX, .STREAM, {}, &pair)
        if errno != .NONE {
            fmt.eprintln("[ext]", ext.name, "— socketpair failed:", errno)
            continue
        }

        // Send extension-side fd to extension process via SCM_RIGHTS
        if !send_fd(ext.control_fd, pair[1]) {
            fmt.eprintln("[ext]", ext.name, "— failed to pass fd to extension")
            linux.close(pair[0])
            linux.close(pair[1])
            continue
        }

        // Extension has the fd now, close our copy
        linux.close(pair[1])

        // WebProcess-side fd
        fds[actual] = c.int(pair[0])
        actual += 1
    }

    out_fds^ = &fds
    return c.int(actual)
}

// ---------------------------------------------------------------------------
// Shutdown — kill all extensions
// ---------------------------------------------------------------------------

extension_shutdown :: proc() {
    for &ext in ext_processes {
        linux.close(ext.control_fd)
        linux.kill(ext.pid, .SIGTERM)
        linux.waitpid(ext.pid, nil, {})
        delete(ext.name)
        delete(ext.path)
    }
    clear(&ext_processes)
}

// ---------------------------------------------------------------------------
// Ed25519 signature verification
// ---------------------------------------------------------------------------

ext_verify_signature :: proc(data: []u8, sig_bytes: []u8) -> bool {
    if len(sig_bytes) != 64 do return false

    for key in ext_trusted_pubkeys {
        k := key
        pk: ed25519.Public_Key
        if !ed25519.public_key_set_bytes(&pk, k[:]) do continue
        if ed25519.verify(&pk, data, sig_bytes) do return true
    }
    return false
}
