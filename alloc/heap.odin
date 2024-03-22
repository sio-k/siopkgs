package alloc

import "core:fmt"
import "core:intrinsics"
import rt "core:runtime"
import "core:sync"

// TODO: make this work on Windows, too
import "core:sys/linux"

GENERIC_HEAP_ALLOCATOR_MAX_BIN_COUNT :: 16384

// a generic heap allocator for systems that use virtual memory and lazy page
// allocation
// You most likely don't want to straight up preallocate this struct, because
// it's very likely to be orders of magnitude larger than you need.
Generic_Heap_Allocator :: struct #align(4096)
{
    // the simplest way I can think of to make this MT-safe
    mtx: sync.Mutex,
    
    // the backing allocator, everything above 2048B goes to this one
    // NOTE (sio): NOT guarded by mtx (!). Considered immutable after creation.
    backing_allocator: rt.Allocator,
    
    // how many pages we're allowed to use
    bin_count: u16,
    
    // how many pages are filled (starting at the bottom) for allocations
    bin_fill: u16,
    
    // bitmap showing whether the bin in question is used for allocations
    bin_in_use: [2048]u8,
    
    // pad to 4096B page size
    pad: [4096 - 2048 - size_of(u16) * 4]u8,
    
    // largest contiguous free space we can serve from a particular bin
    largest_free_space_in_bin: [16384]u16,
    
    // fill bitmap; records where there is still free space in a bin
    fill_maps: [16384][32]u8,
    
    // the following up to 16384 4K pages following this are all reserved, but not committed
    // that's a good 256M of address space, that'll be sufficient for most things I'd think?
    bins: [16384]Generic_Heap_Bin,
}

// a single-page allocator bin
// minimum alignment: 8B (!)
Generic_Heap_Bin :: struct #align(4096)
{
    bucket: [256][2]u64,
}

// currently, every allocation is preceded by this struct. That poses some security risk,
// as one could simply allocate, then an attacker could modify the info there
// I can't currently come up with a better way of storing this info somewhere else.
// size: 16B
Generic_Heap_Alloc_Info :: struct {
    size: u16,
    alignment: u8,
    pad1: u8,
    pad2: u32,
    pad3: u64,
}

// an alloc info needs to exactly fit within a bucket element
#assert(size_of(Generic_Heap_Alloc_Info) == size_of([2]u64))

create_generic_heap_allocator_from_mapped :: proc "contextless" (
    backing: rt.Allocator,
    bin_count: u16,
    mem: rawptr // NOTE (sio): must be size_of(Generic_Heap_Allocator)!
    ) -> (err: rt.Allocator_Error = .None)
{
    context = rt.default_context();
    if bin_count > 16384 {
        fmt.eprintln("Can't create a Generic Heap Allocator with more than 16384 bins. Requested:", bin_count);
        err = .Invalid_Argument;
        return;
    }
    
    // zero out the first page since we expect that to be zero-initialized
    rt.mem_zero(mem, 4096);
    
    res: = transmute(^Generic_Heap_Allocator) mem;
    
    res.backing_allocator = backing;
    res.bin_count = bin_count;
    
    return;
}

create_generic_heap_allocator :: proc "contextless" (
    backing: rt.Allocator,
    bin_count: u16,
    vmap := virtual_map
    ) -> (res: ^Generic_Heap_Allocator, err: rt.Allocator_Error)
{
    context = rt.default_context();
    
    mem, errno := vmap(size_of(Generic_Heap_Allocator));
    if errno != .NONE {
        fmt.eprintln("Failed to map space for Generic_Heap_Allocator:", errno);
        err = .Out_Of_Memory;
        return;
    }
    
    create_generic_heap_allocator_from_mapped(backing, bin_count, mem);
    err = .None;
    return;
}

destroy_generic_heap_allocator :: proc "contextless" (
    gha: ^Generic_Heap_Allocator,
    vunmap := virtual_unmap
    ) -> (success: bool)
{
    context = rt.default_context();
    
    sync.mutex_lock(&gha.mtx); // last lock
    gha.bin_count = 0; // invalidate everything
    
    errno := vunmap(transmute(rawptr) gha, size_of(Generic_Heap_Allocator));
    if errno != .NONE {
        fmt.eprintln("Failed to unmap Generic_Heap_Allocator at", gha, "; got error", errno);
        return false;
    } else {
        return true;
    }
}

make_generic_heap_allocator :: proc "contextless" (
    data: ^Generic_Heap_Allocator
    ) -> rt.Allocator
{
    return rt.Allocator { procedure = generic_heap_allocator_alloc_proc, data = data };
}

generic_heap_allocator_inside_mapped_space :: proc "contextless" (data: ^Generic_Heap_Allocator, mem: rawptr) -> bool {
    not_before := mem >= transmute(rawptr) &data.bins;
    not_after := mem < (intrinsics.ptr_offset(transmute([^]u8) data, size_of(Generic_Heap_Allocator)));
    return not_before && not_after;
}

generic_heap_allocator_compute_bin_available_free_space :: proc "contextless" (fill_map: ^[32]u8) -> (res: u16 = 0) {
    counter: u16 = 0;
    for bucket: u16 = 0; bucket < 32; bucket += 1 {
        for sub: u16 = 0; sub < 8; sub += 1 {
            val := (fill_map[bucket] >> sub) & 1;
            if val == 0 {
                counter += 1;
            } else {
                if counter > res {
                    res = counter;
                }
                counter = 0;
            }
        }
    }
    if counter > res {
        res = counter;
    }
    return;
}

generic_heap_allocator_alloc :: proc(
    data: ^Generic_Heap_Allocator,
    isize: int,
    ialignment: int,
    loc := #caller_location
    ) -> (res: []byte, err: rt.Allocator_Error)
{
    assert(isize > 0 && ialignment > 0);
    
    if isize > 2048 || ialignment > 16 {
        return rt.mem_alloc(size = isize, alignment = ialignment, allocator = data.backing_allocator, loc = loc);
    }
    
    size := u16(isize);
    alignment := u16(ialignment);
    
    if sync.mutex_guard(&data.mtx) {
        using data;
        
        actual_size: u16 = size + u16(size_of(Generic_Heap_Alloc_Info));
        
        bin: ^Generic_Heap_Bin;
        bin_index: u16;
        
        // see if we can satisfy the allocation from an existing bin
        {
            smallest_fitting_free_space_found: u16 = 0xFFFF;
            for i: u16 = 0; i < bin_fill; i += 1 {
                free_space := largest_free_space_in_bin[i];
                if free_space >= actual_size && free_space < smallest_fitting_free_space_found {
                    bin = &bins[i];
                    bin_index = i;
                    smallest_fitting_free_space_found = free_space;
                }
            }
        }
        
        // we need a new bin
        if bin == nil {
            // try to increase the amount of bins we use, and prep a new bin
            if bin_fill >= bin_count {
                err = .Out_Of_Memory;
                return;
            }
            
            // add another bin, zero out all it's relevant structs
            rt.mem_zero(&bins[bin_fill], size_of(Generic_Heap_Bin));
            rt.mem_zero(&fill_maps[bin_fill], size_of(Generic_Heap_Bin));
            largest_free_space_in_bin[bin_fill] = 4096;
            bin_fill += 1;
            
            bin = &bins[bin_fill - 1];
            bin_index = bin_fill - 1;
        }
        
        fill_map := &fill_maps[bin_index];
        
        // allocate from bin
        {
            alloc_info := Generic_Heap_Alloc_Info {
                size = size,
                alignment = u8(alignment),
                pad1 = 0,
                pad2 = 0,
                pad3 = 0,
            };
            
            block_size := u16(size_of(bin.bucket[0]));
            size_in_blocks := actual_size / block_size;
            size_in_blocks = (size_in_blocks + block_size - 1) & -block_size;
            
            // find the smallest fitting free space that'll fit what we need in the fill map
            found_start_idx: u16 = 0xFFFF;
            found_length: u16 = 0;
            
            counter_start: u16 = 0xFFFF;
            counter_length: u16 = 0;
            for block_idx: u16 = 0; block_idx < 32; block_idx += 1 {
                block := &fill_map[block_idx];
                for sub_idx: u16 = 0; sub_idx < 8; sub_idx += 1 {
                    sub_value := (block^ >> sub_idx) & 1;
                    if sub_value == 0 {
                        if counter_length == 0 {
                            counter_start = block_idx * 8 + sub_idx;
                        }
                        counter_length += 1;
                    } else {
                        if counter_length >= size_in_blocks && counter_length < found_length {
                            found_start_idx = counter_start;
                            found_length = counter_length;
                        }
                        counter_start = 0xFFFF;
                        counter_length = 0;
                    }
                }
            }
            
            if counter_start != 0xFFFF && counter_length >= size_in_blocks {
                if counter_length < found_length || found_length == 0 {
                    found_start_idx = counter_start;
                    found_length = counter_length;
                }
            }
            
            if found_start_idx == 0xFFFF || found_length == 0 {
                err = .Out_Of_Memory;
                return;
            }
            
            res = transmute([]byte) rt.Raw_Slice { data = transmute(rawptr) &(bin.bucket[found_start_idx + 1]), len = isize };
            
            // set bits in fill map to filled
            for i := found_start_idx; i < found_start_idx + size_in_blocks; i += 1 {
                block_idx := i / 8;
                sub_idx := i % 8;
                fill_map[block_idx] &= ~(1 << sub_idx);
            }
            
            bin.bucket[found_start_idx] = transmute([2]u64) alloc_info;
        }
        
        largest_free_space_in_bin[bin_index] = generic_heap_allocator_compute_bin_available_free_space(fill_map);
    }
    return;
}

generic_heap_allocator_free :: proc(data: ^Generic_Heap_Allocator, mem: rawptr) -> (err: rt.Allocator_Error) {
    if !generic_heap_allocator_inside_mapped_space(data, mem) {
        // this definitely wasn't allocated by this allocator, let's ask the backing allocator
        return rt.free(mem, allocator = data.backing_allocator);
    }
    
    using data;
    
    // figure out if the allocation has a valid header before it, and if not, signal an error
    // TODO: add a 32-bit header crc to the header I guess, since we have the space and the allocator doesn't need to be fast so much as reliable?
    alloc_info_p := transmute(^Generic_Heap_Alloc_Info) (transmute(uintptr) mem - uintptr(size_of(Generic_Heap_Alloc_Info)));
    
    alloc_info := alloc_info_p^;
    if alloc_info.size > 2048 || alloc_info.alignment > 16 || alloc_info.pad1 != 0 || alloc_info.pad2 != 0 || alloc_info.pad3 != 0 {
        fmt.eprintln("Allocation info of a heap allocator allocation at", mem, "became corrupted. Current values:", alloc_info);
        rt.trap();
    }
    
    relative_to_bins := transmute(u64) intrinsics.ptr_sub(transmute([^]u8) alloc_info_p, transmute([^]u8) &bins);
    bin_index := relative_to_bins / size_of(Generic_Heap_Bin);
    in_bin_index := relative_to_bins % size_of(Generic_Heap_Bin);
    bin := &bins[bin_index];
    fill_map := &fill_maps[bin_index];
    
    if sync.mutex_guard(&mtx) {
        rt.mem_zero(transmute(rawptr) alloc_info_p, int(alloc_info.size) + size_of(Generic_Heap_Alloc_Info));
        
        // mark this allocation's space as unfilled in the fill map
        block_index := u16(in_bin_index / size_of([2]u64));
        starting_block_index := block_index - 1;
        
        size_in_blocks := alloc_info.size / size_of([2]u64);
        size_in_blocks = u16(((int(alloc_info.size) / size_of([2]u64)) + (size_of([2]u64) - 1)) & int(-(size_of([2]u64))));
        size_in_blocks += 1; // alloc info needs to go somewhere, after all
        
        for i := starting_block_index; i < size_in_blocks; i += 1 {
            block_idx := i / 8;
            sub_idx := i % 8;
            fill_map[block_idx] &= ~(1 << sub_idx);
        }
        
        largest_free_space_in_bin[bin_index] = generic_heap_allocator_compute_bin_available_free_space(fill_map);
    }
    return;
}

generic_heap_allocator_allocation_info :: proc "contextless"(data: ^Generic_Heap_Allocator, allocation: rawptr) -> (res: Generic_Heap_Alloc_Info, success: bool) {
    if !generic_heap_allocator_inside_mapped_space(data, allocation) {
        success = false;
        return;
    }
    
    success = true;
    res = (transmute(^Generic_Heap_Alloc_Info) intrinsics.ptr_sub(transmute([^]u8) allocation, transmute([^]u8) u64(size_of(Generic_Heap_Alloc_Info))))^;
    return;
}

generic_heap_allocator_get_space_in_use :: proc "contextless" (
    data: ^Generic_Heap_Allocator
    ) -> (size_in_use: u64)
{
    pages_used :: proc "contextless" (bytecount: u64) -> (pagecount: u64) {
        return (bytecount / 4096) + (bytecount % 4096 > 0 ? 1 : 0);
    }
    
    if sync.mutex_guard(&data.mtx) {
        bins_in_use := u64(data.bin_fill);
        
        fill_map_space_in_use := bins_in_use * size_of([64]u8);
        fill_map_pages_in_use := pages_used(fill_map_space_in_use);
        
        contiguous_free_space_space_in_use := bins_in_use * size_of(u16);
        contiguous_free_space_pages_in_use := pages_used(contiguous_free_space_space_in_use);
        
        pages_in_use: u64 = 1 /* base usage */;
        pages_in_use += contiguous_free_space_space_in_use;
        pages_in_use += fill_map_pages_in_use;
        pages_in_use += bins_in_use;
        
        size_in_use = pages_in_use * 4096;
    }
    return;
}

generic_heap_allocator_alloc_proc :: proc(
    rdata: rawptr, mode: rt.Allocator_Mode,
    size: int, alignment: int,
    old_memory: rawptr, old_size: int,
    location := #caller_location
    ) -> (allocated: []byte, err: rt.Allocator_Error)
{
    data := transmute(^Generic_Heap_Allocator) rdata;
    switch mode {
        case .Alloc, .Alloc_Non_Zeroed: {
            allocated, err = generic_heap_allocator_alloc(data, size, alignment, loc = location);
            
            if mode == .Alloc {
                rt.mem_zero(raw_data(allocated), len(allocated));
            }
        }
        
        case .Free: {
            err = generic_heap_allocator_free(data, old_memory);
        }
        
        case .Query_Features: {
            set := transmute(^rt.Allocator_Mode_Set) old_memory;
            if set != nil {
                set^ = { .Alloc, .Alloc_Non_Zeroed, .Free, .Query_Features, .Query_Info };
            } else {
                err = .Invalid_Argument;
            }
        }
        
        case .Query_Info: {
            info := transmute(^rt.Allocator_Query_Info) old_memory;
            if info != nil && old_size >= size_of(rt.Allocator_Query_Info) {
                space_in_use := int(generic_heap_allocator_get_space_in_use(data));
                
                info.pointer = rdata;
                info.size = space_in_use;
                info.alignment = 4096;
                allocated = transmute([]byte) (rt.Raw_Slice { data = rdata, len = space_in_use });
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

// TODO: build a separate library that just contains these, named correctly so we can interpose them over the standard implementation and so I can test this implementation thoroughly

generic_heap_allocator_malloc_replacement :: proc "contextless" (allocator: ^Generic_Heap_Allocator, count: u64) -> rawptr {
    return generic_heap_allocator_aligned_alloc_replacement(allocator, 16, count);
}

generic_heap_allocator_calloc_replacement :: proc "contextless" (allocator: ^Generic_Heap_Allocator, count: u64, size: u64) -> rawptr {
    // TODO: detect overflow
    return generic_heap_allocator_aligned_alloc_replacement(allocator, 16, count * size);
}

generic_heap_allocator_realloc_replacement :: proc "contextless" (allocator: ^Generic_Heap_Allocator, p: rawptr, new_size: u64) -> rawptr {
    info, have_alloc := generic_heap_allocator_allocation_info(allocator, p);
    if !have_alloc {
        return nil;
    }
    
    new_p := generic_heap_allocator_malloc_replacement(allocator, new_size);
    if new_p == nil {
        return nil;
    }
    
    rt.mem_copy(new_p, p, int(min(new_size, u64(info.size))));
    
    context = rt.default_context();
    
    generic_heap_allocator_free(allocator, p);
    
    return new_p;
}

generic_heap_allocator_reallocarray_replacement :: proc "contextless" (allocator: ^Generic_Heap_Allocator, p: rawptr, new_count: u64, new_size: u64) -> rawptr {
    // TODO: detect overflow
    return generic_heap_allocator_realloc_replacement(allocator, p, new_count * new_size);
}

generic_heap_allocator_free_replacement :: proc "contextless" (allocator: ^Generic_Heap_Allocator, p: rawptr) {
    context = rt.default_context();
    context.allocator = make_generic_heap_allocator(global_heap_allocator);
    err := generic_heap_allocator_free(allocator, p);
    if err != .None {
        fmt.eprintln("error in free():", err);
        rt.trap();
    }
}

generic_heap_allocator_posix_memalign_replacement :: proc "contextless" (allocator: ^Generic_Heap_Allocator, p: ^rawptr, alignment: u64, size: u64) -> (ret_val: i32) {
    context = rt.default_context();
    context.allocator = make_generic_heap_allocator(global_heap_allocator);
    mem, err := generic_heap_allocator_alloc(allocator, int(size), int(alignment));
    if err != .None {
        if err == .Out_Of_Memory {
            ret_val = i32(linux.Errno.ENOMEM);
        } else {
            ret_val = i32(linux.Errno.EINVAL);
        }
    } else {
        p^ = raw_data(mem);
        ret_val = 0;
    }
    
    return;
}

generic_heap_allocator_aligned_alloc_replacement :: proc "contextless" (allocator: ^Generic_Heap_Allocator, alignment: u64, size: u64) -> rawptr {
    p: rawptr = nil;
    _ = generic_heap_allocator_posix_memalign_replacement(allocator, &p, alignment, size);
    return p;
}

generic_heap_allocator_valloc_replacement :: proc "contextless" (allocator: ^Generic_Heap_Allocator, size: u64) -> rawptr {
    return generic_heap_allocator_pvalloc_replacement(allocator, size);
}

generic_heap_allocator_memalign_replacement :: proc "contextless" (allocator: ^Generic_Heap_Allocator, alignment: u64, size: u64) -> rawptr {
    return generic_heap_allocator_aligned_alloc_replacement(allocator, alignment, size);
}

generic_heap_allocator_pvalloc_replacement :: proc "contextless" (allocator: ^Generic_Heap_Allocator, size: u64) -> rawptr {
    return generic_heap_allocator_malloc_replacement(allocator, u64((int(size) + 4095) & -4096));
}