// +build linux
package io_uring

// Copyright (C) 2024 Sio Kreuzer.
// TODO: License is BSD 3-clause so this can wander into the Odin source tree

import "core:sys/linux"

// NOTE (sio): untested, but especially untested on non-amd64.

// the following are in the order that they appear in the Sqe and Cqe structs
// the structs have been amended to include type-checked easier to use fields for
//     convenience

Sqe_Opcode :: enum u8 {
    NOP = 0,
    READV, WRITEV,
    FSYNC,
    READ_FIXED, WRITE_FIXED,
    POLL_ADD, POLL_REMOVE,
    SYNC_FILE_RANGE,
    SENDMSG, RECVMSG,
    TIMEOUT, TIMEOUT_REMOVE,
    ACCEPT,
    ASYNC_CANCEL,
    LINK_TIMEOUT,
    CONNECT,
    FALLOCATE,
    OPENAT,
    CLOSE,
    FILES_UPDATE,
    STATX,
    READ, WRITE,
    FADVISE,
    MADVISE,
    SEND, RECV,
    OPENAT2,
    EPOLL_CTL,
    SPLICE,
    PROVIDE_BUFFERS, REMOVE_BUFFERS,
    TEE,
    SHUTDOWN,
    RENAMEAT,
    UNLINKAT,
    MKDIRAT,
    SYMLINKAT,
    LINKAT,
    MSG_RING,
    FSETXATTR,
    SETXATTR,
    FGETXATTR,
    GETXATTR,
    SOCKET,
    URING_CMD,
    SEND_ZC,
    SENDMSG_ZC,
    LAST
}

Sqe_Flag :: enum u8 {
    FIXED_FILE       = 0,
    IO_DRAIN         = 1,
    IO_LINK          = 2,
    IO_HARDLINK      = 3,
    ASYNC            = 4,
    BUFFER_SELECT    = 5,
    CQE_SKIP_SUCCESS = 6,
    // 1 unused flag bit
}
Sqe_Flags :: distinct bit_set[Sqe_Flag; u8]

// send/sendmsg, recv/recvmsg flags for sqe.ioprio
Send_Recv_Ioprio_Flag :: enum {
    RECVSEND_POLL_FIRST  = 0,
    RECV_MULTISHOT       = 1,
    RECVSEND_FIXED_BUF   = 2,
    SEND_ZC_REPORT_USAGE = 3,
}
Send_Recv_Ioprio_Flags :: distinct bit_set[Send_Recv_Ioprio_Flag; u16]

Accept_IoPrio_Flag :: enum {
    MULTISHOT = 0,
}
Accept_Ioprio_Flags :: distinct bit_set[Accept_Ioprio_Flag; u16]

Msg_Ring_Command_Type :: enum u64 {
    DATA = 0,
    SEND_FD = 1,
}

// TODO Kernel_rwf_t

// sqe.fsync_flags
Fsync_Flag :: enum { DATASYNC = 0 }
Fsync_Flags :: distinct bit_set[Fsync_Flag; u32]

// sqe.poll_events
// command flags for .ADD_* are stored in sqe.len
Poll_Event :: enum {
    ADD_MULTI        = 0,
    UPDATE_EVENTS    = 1,
    UPDATE_USER_DATA = 2,
    ADD_LEVEL        = 3,
}
Poll_Events :: distinct bit_set[Poll_Event; u32]

// TODO: poll32_events, sync_range_events, msg_flags

// sqe.timeout_flags
Timeout_Flag :: enum {
    ABS           = 0,
    UPDATE        = 1,
    BOOTTIME      = 2,
    REALTIME      = 3,
    LINK_UPDATE   = 4, // IORING_LINK_TIMEOUT_UPDATE
    ETIME_SUCCESS = 5,
    MULTISHOT     = 6,
}
Timeout_Flags :: distinct bit_set[Timeout_Flag; u32]
Timeout_Clock_Mask :: Timeout_Flags { .BOOTTIME, .REALTIME }
Timeout_Update_Mask :: Timeout_Flags { .UPDATE, .LINK_UPDATE }

// TODO: accept_flags

Async_Cancel_Flag :: enum {
    ALL      = 0,
    FD       = 1,
    ANY      = 2,
    FD_FIXED = 3,
    USERDATA = 4,
    OP       = 5,
}
Async_Cancel_Flags :: distinct bit_set[Async_Cancel_Flag; u32]

// TODO: open_flags, statx_flags, fadvise_advice

// sqe.splice_flags
Splice_Flag :: enum {
    // NOTE (sio): extends splice(2) flags
    // NOTE (sio): implementation in core:sys/linux is wrong (!)
    MOVE        = 0,
    NONBLOCK    = 1,
    MORE        = 2,
    GIFT        = 3,
    FD_IN_FIXED = 31,
}
Splice_Flags :: distinct bit_set[Splice_Flag; u32]

// TODO: rename_flags, unlink_flags, hardlink_flags, xattr_flags

// sqe.msg_ring_flags
Msg_Ring_Flag :: enum {
    CQE_SKIP = 0, // don't post a cqe; not applicable for .DATA
    FLAGS_PASS = 1, // pass through sqe.file_index to cqe.flags
}
Msg_Ring_Flags :: distinct bit_set[Msg_Ring_Flag; u32]

// sqe.uring_cmd_flags
Uring_Cmd_Flag :: enum {
    FIXED  =  0, // use registered buffer; pass along with sqe.buf_index
    POLLED = 31, // driver use only?
}
Uring_Cmd_Flags :: distinct bit_set[Uring_Cmd_Flag; u32]

// TODO

// submission queue event (sqe)
// NOTE (sio): size 64B, aka cacheline size on amd64
Sqe :: struct {
    opcode: Sqe_Opcode,
    flags: Sqe_flags,
    using _: struct #raw_union {
        ioprio: u16, // I/O priority
        ioprio_recvsend_flags: Send_Recv_Ioprio_Flags,
        ioprio_accept_flags: Accept_Ioprio_Flags,
    },
    
    fd: i32, // file descriptor
    
    using _: struct #raw_union {    
        off: u64, // file offset
        addr2: u64,
        using _: struct {
            cmd_op: u32,
            pad1: u32,
        },
    },

    using _: struct #raw_union {
        using _: struct #raw_union {
            addr: u64, // pointer to buffer or io vec array
            msg_ring_command_type: Msg_Ring_Command_Type,
        },
        splice_off_in: u64,
    },

    using _: struct #raw_union {
        len: u32, // either buffer size in bytes or number of io vecs
        poll_flags: u32, // TODO
    },

    // TODO (sio): make these just use the actual flags, for convenience
    using _: struct #raw_union {
        rw_flags:         Kernel_rwf_t,
        fsync_flags:      Fsync_Flags,
        poll_events:      Poll_Events,
        poll32_events:    u32,
        sync_range_flags: u32,
        msg_flags:        u32,
        timeout_flags:    Timeout_Flags,
        accept_flags:     u32,
        cancel_flags:     Async_Cancel_Flags,
        open_flags:       u32,
        statx_flags:      u32,
        fadvise_advice:   u32,
        splice_flags:     Splice_Flags,
        rename_flags:     u32,
        unlink_flags:     u32,
        hardlink_flags:   u32,
        xattr_flags:      u32,
        msg_ring_flags:   u32,
        uring_cmd_flags:  Uring_Cmd_Flags,
    },
    user_data: u64, // passed back in in CQE

    using _: struct #raw_union #packed {
        buf_index: u16,
        buf_group: u16,
    },
    personality: u16,

    using _: struct #raw_union {
        splice_fd_in: u32,
        file_index: u32,
        using _: struct #raw_union {
            addr_len: u16,
            pad3: [1]u16,
        },
    },
    using _: struct #raw_union {
        using _: struct {
            addr3: u64,
            pad2: [1]u64,
        },
        // this is the start of 80B command data if ring is set up with IORING_SETUP_SQE128
        cmd: [1]u8,
    },
}

Notif_Usage_Res_Bits :: enum {
    COPIED = 31,
}
Notif_Usage_Res :: distinct bit_set[Notif_Usage_Res_Bits; u32]

Cqe_Flag :: enum {
    BUFFER = 0, // upper 16b of cqe.raw_flags are buffer id
    MORE = 1, // parent sqe will generate more cqes
    SOCK_NONEMPTY = 2, // more data to read on socket
    NOTIF = 3, // notification CQE. For distinguishing from send CQEs
}
Cqe_Flags :: distinct bit_set[Cqe_Flag; u32]

CQE_BUFFER_SHIFT :: 16

// completion queue event (cqe)
Cqe :: struct {
    user_data: u64, // user_data from the sqe passed back in
    
    using _: struct #raw_union {
        // result code for event (usually extractable using `Errno(~(cqe.res))`)
        res: i32,
    
        // in case of SEND_ZC_REPORT_USAGE
        notif_usage_res: Notif_Usage_Res,
    },

    using _: struct #raw_union {
        flags: Cqe_Flags,
        raw_flags: u32,
    },
}

// if the ring is initialized with Setup_Flag.CQE32, then CQEs are 32B in size, so
// contain 16B of padding
Big_Cqe :: struct {
    using Cqe,
    big_cqe: [2]u64,
}

// magic mmap offsets
OFF_SQ_RING   :: 0
OFF_CQ_RING   :: 0x08000000
OFF_SQES      :: 0x10000000
OFF_PBUF_RING :: 0x80000000
OFF_MMAP_MASK :: 0xf8000000
OFF_PBUF_SHIFT :: 16

Sqring_Flag :: enum {
    NEED_WAKEUP = 0,
    CQ_OVERFLOW = 1,
    TASKRUN = 2,
}
Sqring_Flags :: distinct bit_set[Sqring_Flag; u32]

Sqring_Offsets :: struct {
    head:         u32,
    tail:         u32,
    ring_mask:    u32,
    ring_entries: u32,
    flags:        Sqring_Flags,
    dropped:      u32,
    array:        u32,
    resv1:        u32,
    user_addr:    u64,
}

Cqring_Flag :: enum {
    EVENTFD_DISABLED = 0,
}
Cqring_Flags :: distinct bit_set[Cqring_Flag; u32]

Cqring_Offsets :: struct {
    head:         u32,
    tail:         u32,
    ring_mask:    u32,
    ring_entries: u32,
    overflow:     u32,
    cqes:         u32,
    flags:        Cqring_Flags,
    resv1:        u32,
    user_addr:    u64,
}

Setup_Flag :: enum u32 {
    IOPOLL             =  0,
    SQPOLL             =  1,
    SQ_AFF             =  2,
    CQSIZE             =  3,
    CLAMP              =  4,
    ATTACH_WQ          =  5,
    R_DISABLED         =  6,
    SUBMIT_ALL         =  7,
    COOP_TASKRUN       =  8,
    TASKRUN_FLAG       =  9,
    SQE128             = 10,
    CQE32              = 11,
    SINGLE_ISSUER      = 12,
    DEFER_TASKRUN      = 13,
    NO_MMAP            = 14,
    REGISTERED_FD_ONLY = 15,
    NO_SQARRAY         = 16,
}
Setup_Flags :: distinct bit_set[Setup_Flag; u32] // TODO: u32 or u16?

Uring_Param_Feature :: enum u32 {
    SINGLE_MMAP = 0,
    NODROP = 1,
    SUBMIT_STABLE = 2,
    RW_CUR_POS =3,
    CUR_PERSONALITY = 4,
    FAST_POLL = 5,
    POLL_32BITS = 6,
    SQPOLL_NONFIXED = 7,
    EXT_ARG = 8,
    NATIVE_WORKERS = 9,
    RSRC_TAGS = 10,
    CQE_SKIP = 11,
    LINKED_FILE = 12,
    REG_REG_RING = 13,
}
Uring_Param_Features :: distinct bit_set[Uring_Param_Feature; u32]

Uring_Params :: struct {
    sq_entries: u32,
    cq_entries: u32,
    flags: u32,
    sq_thread_cpu: u32,
    sq_thread_idle: u32,
    features: Uring_Param_Features,
    wq_fd: u32,
    resv: [3]u32,
    sq_off: Sqring_Offsets,
    cq_off: Cqring_Offsets,
}

setup_sys :: proc "contextless" (entries: u32, params: [^]Uring_Params) -> (count: u32, err: linux.Errno) {
    x := linux.syscall(linux.SYS_io_uring_setup, entries, transmute(rawptr) params);
    if x >= 0 {
        count = x;
        err = nil;
    } else {
        count = 0;
        err = linux.Errno(-x);
    }
    return;
}

setup_slice :: proc "contextless" (params: []Uring_Params) -> (count: u32, err: linux.Errno) {
    return enter_sys(u32(len(params)), raw_data(params));
}

setup :: proc { setup_sys, setup_slice }

Enter_Flag :: enum u32 {
    GETEVENTS = 0,
    SQ_WAKEUP = 1,
    SQ_WAIT = 2,
    EXT_ARG = 3,
    ENTER_REGISTERED_RING = 4,
}
Enter_Flags :: distinct bit_set[Enter_Flag; u32]

enter :: proc "contextless" (
    fd: u32,
    to_submit: u32,
    min_complete: u32,
    flags: Enter_Flags,
    sig: ^Sigset_t
    ) -> (count: u32, err: linux.Errno)
{
    x := linux.syscall(linux.SYS_io_uring_enter, fd, to_submit, min_complete, transmute(u32) flags, transmute(rawptr) sig);
    if x >= 0 {
        count = x;
        err = nil;
    } else {
        count = 0;
        err = linux.Errno(-x);
    }
    return;
}

enter2 :: proc "contextless" (
    fd: u32,
    to_submit: u32,
    min_complete: u32,
    flags: Enter_Flags,
    sig: ^Sigset_t,
    sz: u64
    ) -> (count: u32, err: linux.Errno)
{
    x := linux.syscall(linux.SYS_io_uring_enter2, fd, to_submit, min_complete, transmute(u32) flags, transmute(rawptr) sig, sz);
    if x >= 0 {
        count = x;
        err = nil;
    } else {
        count = 0;
        err = linux.Errno(-x);
    }
    return;
}

@(deprecated="see Rsrc_Update")
Files_Update :: struct #align(8) {
    offset: u32,
    resv: u32,
    fds: ^i32,
}

Wq_Worker_Category :: enum u8 { BOUND, UNBOUND }

Rsrc_Register_Flag :: enum { SPARSE = 0 }
Rsrc_Register_Flags :: distinct bit_set[Rsrc_Register_Flag; u32]

Rsrc_Register :: struct #align(8) {
    nr: u32,
    flags: Rsrc_Register_Flags,
    resv2: u64,
    data: u64,
    tags: u64,
}

Rsrc_Update :: struct #align(8) {
    offset: u32,
    resv: u32,
    data: u64,
}

Rsrc_Update2 :: struct #align(8) {
    offset: u32,
    resv: u32,
    data: u64,
    tags: u64,
    nr: u32,
    resv2: u32,
}

REGISTER_FILES_SKIP :: -2

Probe_Op_Flag :: enum {
    SUPPORTED = 0,
}
Probe_Op_Flags :: distinct bit_set[Probe_Op_Flag; u16]

Probe_Op :: struct {
    op: u8,
    resv: u8,
    flags: Probe_Op_Flags,
    resv2: u32,
}

Probe :: struct {
    last_op: u8, // last opcode supported
    ops_len: u8, // length of opcode array
    resv: u16,
    resv2: [3]u32,
    ops: [0]Probe_Op,
}

Restriction_Opcode :: enum u16 {
    REGISTER_OP = 0,
    SQE_OP = 1,
    SQE_FLAGS_ALLOWED = 2,
    SQE_FLAGS_REQUIRED = 3,
    LAST,
}

Restriction :: struct {
    opcode: Restriction_Opcode,
    using _: struct #raw_union {
        register_op: u8, // Register_Opcode
        sqe_op: Sqe_Opcode,
        sqe_flags: Sqe_Flags,
    },
    resv: u8,
    resv2: [3]u32,
}

Buf :: struct {
    addr: u64,
    len: u32,
    bid: u16,
    resv: u16,
}

Buf_Ring :: struct #raw_union {
    using _: struct {
        resv1: u32,
        resv2: u32,
        resv3: u16,
        tail:  u16,
    },
    bufs: [0]Buf,
}

Register_Pbuf_Ring_Flag :: enum {
    MMAP = 0,
}
Register_Pbuf_Ring_Flags :: distinct bit_set[Register_Pbuf_Ring_Flag; u16]

// arg for un/registering pbuf ring
Buf_Reg :: struct {
    ring_addr: u64,
    ring_entries: u32,
    bgid: u16,
    flags: Register_Pbuf_Ring_Flags,
    resv: [3]u64,
}

Getevents_Arg :: struct {
    sigmask: u64,
    sigmask_sz: u32,
    pad: u32,
    ts: u64,
}

Sync_Cancel_Reg :: struct {
    addr: u64,
    fd: i32,
    flags: u32,
    timeout: kernel_timespec, // TODO
    opcode: u8, // TODO?
    pad: [7]u8,
    pad2: [3]u64,
}

File_Index_Range :: struct {
    off: u32,
    len: u32,
    resv: u64,
}

Recvmsg_Out :: struct {
    namelen: u32,
    controllen: u32,
    payloadlen: u32,
    flags: u32, // TODO
}

Cmd_Socket_Op :: enum {
    SIOCINQ = 0,
    SIOCOUTQ,
}

Register_Opcode :: enum u32 {
    REGISTER_BUFFERS = 0, UNREGISTER_BUFFERS = 1,
    REGISTER_FILES = 2, UNREGISTER_FILES = 3,
    REGISTER_EVENTFD = 4, UNREGISTER_EVENTFD = 5,
    REGISTER_FILES_UPDATE = 6,
    REGISTER_EVENTFD_ASYNC = 7,
    REGISTER_PROBE = 8,
    REGISTER_PERSONALITY = 9, UNREGISTER_PERSONALITY = 10,
    REGISTER_RESTRICTIONS = 11,
    REGISTER_ENABLE_RINGS = 12,
    
    REGISTER_FILES2 = 13,
    REGISTER_FILES_UPDATE2 = 14,
    REGISTER_BUFFERS2 = 15,
    REGISTER_BUFFERS_UPDATE = 16,
    
    REGISTER_IOWQ_AFF = 17, UNREGISTER_IOWQ_AFF = 18,
    
    REGISTER_IOWQ_MAX_WORKERS = 19,
    
    REGISTER_RING_FDS = 20,
    UNREGSITER_RING_FDS = 21,
    
    REGISTER_PBUF_RING = 22,
    UNREGISTER_PBUF_RING = 23,
    
    REGISTER_SYNC_CANCEL = 24,
    REGISTER_FILE_ALLOC_RANGE = 25,
    
    REGISTER_LAST,
    
    REGISTER_USE_REGISTERED_RING = 1 << 31,
}

register :: proc "contextless" (fd: linux.Fd, opcode: Register_Opcode, arg: rawptr, nr_args: u32) -> (res: u32, err: linux.Errno) {
    x := linux.syscall(linux.SYS_io_uring_register, transmute(u32) fd, transmute(u32) opcode, arg, nr_args);
    if x >= 0 {
        res = x;
        err = nil;
    } else {
        res = 0;
        err = linux.Errno(-x);
    }
    return;
}

// TODO (sio): sample code for interacting with io_uring