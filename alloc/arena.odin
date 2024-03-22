package alloc

import rt "core:runtime"

import intrin "core:intrinsics"

ARENA_MAX_SIZE :: 32 * rt.Gigabyte

Arena_Fields :: struct {
    size: u64,
    fill: u64,
    max_fill: u64, // records the maximum fill we've reached
}

Arena :: struct($SIZE: u64) #align(4096) {
    using _: Arena_Fields,
    mem: [SIZE - size_of(Arena_Fields)]u8,
}

Type_Erased_Arena :: struct #align(4096) {
    using _: Arena_Fields,
    mem: [ARENA_MAX_SIZE - size_of(Arena_Fields)]u8,
}

Arena_Save_Point :: struct {
    fill: u64,
}

arena_temp_begin :: proc() -> Arena_Save_Point {
    assert(context.temp_allocator.procedure == arena_alloc_proc);
    arena := transmute(^Type_Erased_Arena) context.temp_allocator.data;
    return Arena_Save_Point { arena.fill };
}

arena_temp_end :: proc(save_point: Arena_Save_Point) {
    assert(context.temp_allocator.procedure == arena_alloc_proc);
    arena := transmute(^Type_Erased_Arena) context.temp_allocator.data;
    arena.fill = save_point.fill;
}

init_arena :: proc(arena: ^Arena($size)) -> ^Type_Erased_Arena {
    #assert(size < ARENA_MAX_SIZE);
    
    arena.size = size;
    arena.fill = 0;
    arena.max_fill = 0;
    
    return transmute(^Type_Erased_Arena) arena;
}

arena_alloc_proc :: proc(
    rarena: rawptr, mode: rt.Allocator_Mode,
    size: int, alignment: int,
    old_memory: rawptr, old_size: int,
    location := #caller_location
    ) -> (data: []byte, err: rt.Allocator_Error = .None)
{
    // size must be > 0, alignment must be > 0 and a power of two
    if size <= 0 || alignment <= 0 || intrin.count_ones(alignment) != 1 {
        err = .Invalid_Argument;
        return;
    }
    
    arena := transmute(^Type_Erased_Arena) rarena;
    switch mode {
        case .Alloc, .Alloc_Non_Zeroed: {
            // align
            arena.fill = u64((i64(arena.fill) + (i64(alignment) - 1)) & -(i64(alignment)));
            
            data = transmute([]byte) rt.Raw_Slice { data = rawptr(uintptr(&(arena.mem)) + uintptr(arena.fill)), len = size };
            arena.fill += u64(size);
            
            arena.max_fill = max(arena.max_fill, arena.fill);
            
            if mode == .Alloc {
                rt.mem_zero(raw_data(data), len(data));
            }
        }
        
        case .Free_All: {
            arena.fill = 0;
        }
        
        case .Query_Features: {
            set := transmute(^rt.Allocator_Mode_Set) old_memory;
            if set != nil {
                set^ = { .Alloc, .Alloc_Non_Zeroed, .Free_All, .Query_Features, .Query_Info };
            } else {
                err = .Invalid_Argument;
            }
        }
        
        case .Query_Info: {
            info := transmute(^rt.Allocator_Query_Info) old_memory;
            if info != nil && old_size >= size_of(rt.Allocator_Query_Info) {
                info.pointer = rarena;
                info.size = int(arena.max_fill);
                info.alignment = 4096;
                data = transmute([]byte) (rt.Raw_Slice { data = rarena, len = int(arena.max_fill) });
            } else {
                err = .Invalid_Argument;
            }
        }
        
        case .Free, .Resize, .Resize_Non_Zeroed: {
            err = .Mode_Not_Implemented;
        }
    }
    return;
}

make_arena_alloc_type_erased :: proc "contextless" (arena: ^Type_Erased_Arena) -> rt.Allocator {
    return rt.Allocator { procedure = arena_alloc_proc, data = arena };
}

make_arena_alloc_parapoly :: proc "contextless" (arena: ^Arena($SIZE)) -> rt.Allocator {
    return make_arena_alloc_type_erased(transmute(^Type_Erased_Arena) arena);
}

make_arena_alloc :: proc { make_arena_alloc_type_erased, make_arena_alloc_parapoly }

