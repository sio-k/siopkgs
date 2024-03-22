package alloc

import rt "core:runtime"
import "core:sync"

// TODO: make this work on Windows, too
import "core:sys/linux"

virtual_map :: proc "contextless" (size: u64) -> (res: rawptr, err: linux.Errno) {
    res, err = linux.mmap(uintptr(0), uint(size), { .READ, .WRITE }, { .PRIVATE, .ANONYMOUS });
    return;
}

virtual_unmap :: proc "contextless" (addr: rawptr, size: u64) -> (err: linux.Errno) {
    return linux.munmap(addr, uint(size));
}

// TODO: make the max. allocations overridable at least overall

// default: 2M
VIRTUAL_ALLOC_MAX_ALLOCATIONS :: 2 * 1024 * 1024

// 24B
Virtual_Allocator_Allocation :: struct {
    address: rawptr,
    size: u64, // requested size
    alignment: u64, // requested alignment (considered fulfilled by default (!))
}

VIRTUAL_ALLOC_ALLOCATION_DATA_STORAGE_SIZE :: VIRTUAL_ALLOC_MAX_ALLOCATIONS * size_of(Virtual_Allocator_Allocation)

Virtual_Allocator :: struct {
    mtx: sync.Mutex,
    allocations_fill: u32,
    allocations: [VIRTUAL_ALLOC_MAX_ALLOCATIONS]Virtual_Allocator_Allocation,
}

virtual_alloc_allocate :: proc(
    data: ^Virtual_Allocator,
    size: u64,
    align: u64
    ) -> (res: Virtual_Allocator_Allocation, err: rt.Allocator_Error = .None)
{
    using data;
    if sync.mutex_guard(&mtx) {
        if allocations_fill == VIRTUAL_ALLOC_MAX_ALLOCATIONS {
            err = .Out_Of_Memory;
            return;
        }
        
        errno: linux.Errno;
        res.address, errno = virtual_map(size);
        if errno != .NONE {
            err = .Out_Of_Memory;
            return;
        }
        res.size = size;
        res.alignment = align;
        
        allocations[allocations_fill] = res;
        allocations_fill += 1;
    }
    return;
}

virtual_alloc_free :: proc(data: ^Virtual_Allocator, mem: rawptr) -> (err: rt.Allocator_Error = .None) {
    using data;
    if sync.mutex_guard(&mtx) {
        allocation: Virtual_Allocator_Allocation;
        allocation_index: u32 = VIRTUAL_ALLOC_MAX_ALLOCATIONS + 1;
        
        for i: u32 = 0; i < allocations_fill; i += 1 {
            if allocations[i].address == mem {
                allocation = allocations[i];
                allocation_index = i;
            }
        }
        
        if allocation_index >= VIRTUAL_ALLOC_MAX_ALLOCATIONS {
            err = .Invalid_Pointer;
            return;
        }
        
        errno := virtual_unmap(allocation.address, allocation.size);
        if errno != .NONE {
            err = .Invalid_Argument;
            return;
        }
        
        for i: u32 = allocation_index; i < allocations_fill - 1; i += 1 {
            allocations[i] = allocations[i + 1];
        }
        allocations_fill -= 1;
    }
    return;
}

virtual_alloc_info :: proc(
    data: ^Virtual_Allocator,
    mem: rawptr
    ) -> (res: Virtual_Allocator_Allocation, err: rt.Allocator_Error = .None)
{
    using data;
    if sync.mutex_guard(&mtx) {
        for i: u32; i < allocations_fill; i += 1 {
            if allocations[i].address == mem {
                res = allocations[i];
                return;
            }
        }
        
        err = .Invalid_Pointer;
    }
    return;
}

virtual_alloc_proc :: proc(
    rdata: rawptr, mode: rt.Allocator_Mode,
    size: int, alignment: int,
    old_memory: rawptr, old_size: int,
    location := #caller_location
    ) -> (data: []byte, err: rt.Allocator_Error)
{
    va := transmute(^Virtual_Allocator) rdata;
    
    switch mode {
        case .Alloc, .Alloc_Non_Zeroed: {
            res: Virtual_Allocator_Allocation;
            res, err = virtual_alloc_allocate(va, u64(size), u64(alignment));
            if err != .None {
                break;
            }
            
            data = transmute([]byte) (rt.Raw_Slice { data = res.address, len = size });
            
            if mode == .Alloc {
                rt.mem_zero(res.address, size);
            }
        }
        
        case .Free: {
            err = virtual_alloc_free(va, old_memory);
        }
        
        case .Query_Features: {
            set := transmute(^rt.Allocator_Mode_Set) old_memory;
            if set != nil {
                set^ = { .Alloc, .Alloc_Non_Zeroed, .Free, .Query_Features, .Query_Info };
            } else {
                err = .Invalid_Argument;
            }
        }
        
        // TODO (sio): return the approximate actual current size, rounded up to page size?
        case .Query_Info: {
            info := transmute(^rt.Allocator_Query_Info) old_memory;
            if info != nil && old_size >= size_of(rt.Allocator_Query_Info) {
                info.pointer = rdata;
                info.size = size_of(Virtual_Allocator);
                info.alignment = 4096;
                data = transmute([]byte) (rt.Raw_Slice { data = rdata, len = size_of(Virtual_Allocator) });
            } else {
                err = .Invalid_Argument;
            }
        }
        
        case .Free_All, .Resize, .Resize_Non_Zeroed: {
            err = .Mode_Not_Implemented;
        }
    }
    
    return;
}

init_virtual_alloc_data :: proc "contextless" (res: ^Virtual_Allocator) {
    // ensure only relevant values are zeroed so we don't commit more than we want
    res.allocations_fill = 0;
    rt.mem_zero(&(res.mtx), size_of(sync.Mutex));
}

create_virtual_alloc_data :: proc "contextless" () -> (res: ^Virtual_Allocator, err: linux.Errno = .NONE)
{
    result: rawptr;
    result, err = virtual_map(size_of(Virtual_Allocator));
    if err != .NONE {
        return;
    }
    res = transmute(^Virtual_Allocator) result;
    
    init_virtual_alloc_data(res);
    return;
}

// returns only the FIRST error encountered, but will keep trying to unmap
destroy_virtual_alloc_data :: proc "contextless" (
    data: ^Virtual_Allocator
    ) -> (err: linux.Errno = .NONE)
{
    using data;
    sync.mutex_lock(&mtx); // final lock
    for i: u32; i < allocations_fill; i += 1 {
        errno := virtual_unmap(allocations[i].address, allocations[i].size);
        if err == .NONE {
            err = errno;
        }
    }
    
    errno := virtual_unmap(transmute(rawptr) data, size_of(Virtual_Allocator));
    if err == .NONE {
        err = errno;
    }
    return;
}

make_virtual_alloc :: proc "contextless" (
    data: ^Virtual_Allocator
    ) -> rt.Allocator
{
    return rt.Allocator { procedure = virtual_alloc_proc, data = transmute(rawptr) data };
}

