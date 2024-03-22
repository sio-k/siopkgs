package alloc

import "core:fmt"
import rt "core:runtime"
import "core:sys/linux"

global_virtual_allocator: ^Virtual_Allocator;
global_heap_allocator: ^Generic_Heap_Allocator;

@(private="file")
init_if_needed :: proc "contextless" () {
    context = rt.default_context();
    if global_virtual_allocator != nil || global_heap_allocator != nil {
        return;
    }
    
    err: linux.Errno = .NONE;
    global_virtual_allocator, err = create_virtual_alloc_data();
    if err != .NONE {
        fmt.eprintln("Failed to initialize the backing allocator:", err);
        rt.trap();
    }
    
    alloc_err: rt.Allocator_Error;
    global_heap_allocator, alloc_err = create_generic_heap_allocator(make_virtual_alloc(global_virtual_allocator), 16384);
    if alloc_err != .None {
        fmt.eprintln("Failed to initialize global heap allocator:", alloc_err);
        rt.trap();
    }
}

@export
global_heap_allocator_init :: proc "cdecl" () -> rt.Allocator {
    init_if_needed();
    return make_generic_heap_allocator(global_heap_allocator);
}

// TODO: make a C wrapper that statically links this in and defines malloc/realloc etc.

@export
malloc_replacement :: proc "cdecl" (count: u64) -> rawptr {
    init_if_needed();
    return generic_heap_allocator_malloc_replacement(global_heap_allocator, count);
}

@export
calloc_replacement :: proc "cdecl" (count: u64, size: u64) -> rawptr {
    init_if_needed();
    return generic_heap_allocator_calloc_replacement(global_heap_allocator, count, size);
}

@export
realloc_replacement :: proc "cdecl" (p: rawptr, new_size: u64) -> rawptr {
    init_if_needed();
    return generic_heap_allocator_realloc_replacement(global_heap_allocator, p, new_size);
}

@export
reallocarray_replacement :: proc "cdecl" (p: rawptr, new_count: u64, new_size: u64) -> rawptr {
    init_if_needed();
    return generic_heap_allocator_reallocarray_replacement(global_heap_allocator, p, new_count, new_size);
}

@export
free_replacement :: proc "cdecl" (p: rawptr) {
    init_if_needed();
    generic_heap_allocator_free_replacement(global_heap_allocator, p);
}

@export
posix_memalign_replacement :: proc "cdecl" (p: ^rawptr, alignment: u64, size: u64) -> i32 {
    init_if_needed();
    return generic_heap_allocator_posix_memalign_replacement(global_heap_allocator, p, alignment, size);
}

@export
aligned_alloc_replacement :: proc "cdecl" (alignment: u64, size: u64) -> rawptr {
    init_if_needed();
    return generic_heap_allocator_aligned_alloc_replacement(global_heap_allocator, alignment, size);
}

@export
valloc_replacement :: proc "cdecl" (size: u64) -> rawptr {
    init_if_needed();
    return generic_heap_allocator_valloc_replacement(global_heap_allocator, size);
}

@export
memalign_replacement :: proc "cdecl" (alignment: u64, size: u64) -> rawptr {
    init_if_needed();
    return generic_heap_allocator_memalign_replacement(global_heap_allocator, alignment, size);
}

@export
pvalloc_replacement :: proc "cdecl" (size: u64) -> rawptr {
    init_if_needed();
    return generic_heap_allocator_pvalloc_replacement(global_heap_allocator, size);
}