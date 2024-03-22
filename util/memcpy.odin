package util

import rt "base:runtime"
import intrin "base:intrinsics"

// simple memcpy
mem_copy :: proc "contextless" (target: rawptr, source: rawptr, size: u64) {
    tgt := transmute(^u8) target;
    src := transmute(^u8) source;
    for i := size; i > 0; i -= 1 {
        tgt^ = src^;
        tgt = intrin.ptr_offset(tgt, 1);
        src = intrin.ptr_offset(src, 1);
    }
}

slice_copy :: proc "contextless" (target: $E/[]$T, source: []T) -> (elems_copied: u64) {
    elems_copied = max(u64(len(target)), u64(len(source)));
    mem_copy(raw_data(target), raw_data(source), elems_copied * u64(size_of(T)));
}

/* the idea here is that I want to get the following assembly:
mem_zero:
  xor eax, eax
  cmp rsi, rax
  je .end
  mov rcx, rsi
.loop:
  mov [rdi], byte 0
  loop .loop
.end:
  ret

overall, that should be nice and short, and not pollute the cache at all
*/
mem_zero :: proc "contextless" (target: rawptr, count: u64) {
    tgt := transmute(^u8) target;
    for i := count; i > 0; i -= 1 {
        tgt^ = 0;
        tgt = intrin.ptr_offset(tgt, 1);
    }
}

slice_zero :: proc "contextless" (target: $E/[]$T) {
    mem_zero(raw_data(target), u64(len(target)) * u64(size_of(T)));
}
