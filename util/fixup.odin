package util

import rt "base:runtime"

fixup_dynamic_array_allocator :: proc "contextless" (dynarray: ^[dynamic]$T, new_alloc: rt.Allocator) {
    raw_da := transmute(^rt.Raw_Dynamic_Array) dynarray;
    raw_da.allocator = new_alloc;
}

fixup_map_allocator :: proc "contextless" (m: ^map[$K]$V, new_alloc: rt.Allocator) {
    raw_m := transmute(^rt.Raw_Map) m;
    raw_m.allocator = new_alloc;
}