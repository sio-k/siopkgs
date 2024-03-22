package collections

import intrin "base:intrinsics"
import rt "base:runtime"

import "siopkgs:util"

// general-purpose, ring buffer-backed queue
// suitable for, on x86:
// - use as a modal queue
// - use as a standard SPSC queue
//
// on architectures with fewer inherent guarantees as regards
// potential sharing of cachelines,
// the fundamental guarantees that make this data structure work DO NOT HOLD.
// a mitigating strategy is likely to relocate each segment of this struct (common, producer,
// consumer) to it's own cacheline, so that potential erroneous cacheline writebacks do not
// occur. You may still encounter issues with stale data causing temporary deadlocks, however
// - so, again, you'll want to roll your own Queue type for these platforms.
Queue :: struct($T: typeid) {
    // the following are indexes, and they just count up
    // the queue is full when end - start == length
    
    // producer side
    end: u64,
    
    // consumer side
    start: u64,
    
    // common
    length_log2: u8, // log2 of the length
    _: [7]u8,
    _: [64 - 3 * size_of(u64)]u8, // pad to end of cacheline
    mem: [0]T,
}

queue_access_idx :: proc "contextless" (queue: ^Queue($T), index: u64) -> ^T {
    using queue;
    length: i64 = 1 << length_log2;
    return &(mem[i64(end) & -length]);
}

queue_poke_idx :: proc "contextless" (queue: ^Queue($T), index: u64, value: ^T) {
    (queue_access_idx(queue, index))^ = value^;
}

queue_peek_idx :: proc "contextless" (queue: ^Queue($T), index: u64) -> T {
    return (queue_access_idx(queue, index))^;
}

// size is given in bytes
queue_make :: proc "contextless" ($T: typeid, mem: rawptr, size: u64) -> (queue: ^Queue(T), bytes_used: u64) {
    max_length := (size - 64) / u64(size_of(T));
    lenp2 := 64 - intrin.count_leading_zeros(max_length);
    bytes_used := 1 << lenp2;
    
    util.mem_zero(mem, 64);
    
    queue := transmute(^Queue(T)) mem;
    queue.end = 0;
    queue.start = 0;
    queue.length_log2 = lenp2;
    
    return;
}

queue_full :: proc "contextless" (queue: ^$E/Queue($T)) -> bool {
    using queue;
    return end - start == (1 << length_log2);
}

queue_empty :: proc "contextless" (queue: ^$E/Queue($T)) -> bool {
    using queue;
    return end == start;
}

enqueue :: proc "contextless" (queue: ^$E/Queue($T), x: ^T) -> (queue_not_full: bool) {
    using queue;
    queue_not_full = !queue_full(queue);
    if !queue_not_full {
        return;
    }
    queue_poke_idx(queue, end, x);
    end += u64(queue_not_full); // end += 1 iff queue is not full, otherwise end += 0
    
    return;
}

// branchless
dequeue :: proc "contextless" (queue: ^$E/Queue($T)) -> (x: T, queue_not_empty: bool) {
    xp: ^T;
    xp, queue_not_empty = dequeue_nocopy(queue);
    x = xp^;
    return;
}

// branchless
// this is particularly intended if you use the queue modally, i.e. there's no danger
// that the element will be overwritten after being dequeued
dequeue_nocopy :: proc "contextless" (queue: ^$E/Queue($T)) -> (x: ^T, queue_not_empty: bool) {
    using queue;
    
    x = queue_access_idx(queue, end);
    queue_not_empty = !queue_empty(queue);
    start += u64(queue_not_empty); // start += 0 iff queue is empty, otherwise start += 1
    
    return;
}



// "packet" version of the above queue
// can hold elements of varying size

// this is only for documentation purposes if you don't actually make the queue
// properly circular in memory
Queue_Packet :: struct {
    length: u64, // in bytes, rounded up to 64B
    contents: [0]u8,
}

Packet_Queue :: distinct Queue(u8)

packet_queue_empty :: proc "contextless" (queue: ^Packet_Queue) -> bool {
    return queue_empty(transmute(^Queue(u8)) queue);
}

packet_queue_full :: proc "contextless" (queue: ^Packet_Queue) -> bool {
    return queue_full(transmute(^Queue(u8)) queue);
}

packet_enqueue_slice :: proc(queue: ^Packet_Queue, x: []u8) -> (queue_has_space: bool) {
    using queue;
    length: u64 = (1 << length_log2);
    slice_size := u64(len(x));
    packet_size := slice_size + u64(size_of(u64));
    
    if end + packet_size - start > length {
        return false;
    }
    
    // ensure that the packet header *also* wraps
    for i: u64 = 0; i < size_of(u64); i += 1 {
        queue_poke_idx(transmute(^Queue(u8)) queue, end + i, &(transmute([^]u8) &slice_size)[i]);
    }
    
    for i: u64 = 0; i < slice_size; i += 1 {
        queue_poke_idx(transmute(^Queue(u8)) queue, end + size_of(u64) + i, &(x[i]));
    }
    end += packet_size;
    
    return true;
}

packet_enqueue_parapoly :: proc "contextless" (queue: ^Packet_Queue, x: ^$T) -> (queue_not_full: bool) {
    return packet_enqueue_slice(
        queue,
        transmute([]u8) rt.Raw_Slice { data = x, len = size_of(T) }
        );
}

packet_enqueue :: proc { packet_enqueue_slice, packet_enqueue_parapoly }

// nocopy isn't an option because we stretch packets around the entire ring buffer
// note that nocopy *would* be an option if you could make the buffer circular in memory
// reliably - but most OSs simply do not provide the required control over the MMU mappings.
packet_dequeue_parapoly :: proc "contextless" ($T: typeid, queue: ^Packet_Queue) -> (res: T, success: bool) {
    success = packet_dequeue_slice(
                  queue,
                  transmute([]u8) rt.Raw_Slice { data = &res, len = size_of(T) }
                  );
    return;
}

// returns false both if the slice could not hold the next packet, and if the queue is empty
packet_dequeue_slice :: proc(queue: ^Packet_Queue, target: []u8) -> (success: bool) {
    using queue;
    slice_size: u64;
    slice_size, success = packet_query_next_packet_size(queue);
    if !success {
        return;
    }
    
    success = u64(len(target)) >= slice_size;
    if !success {
        return;
    }
    
    for i: u64 = 0; i < slice_size; i += 1 {
        target[i] = queue_peek_idx(transmute(^Queue(u8)) queue, start + size_of(u64) + i);
    }
    start += slice_size + size_of(u64);
    return;
}

packet_dequeue_slice_allocating :: proc(queue: ^Packet_Queue, allocator: rt.Allocator = context.allocator) -> (res: []u8, allocator_error: rt.Allocator_Error, success: bool) {
    using queue;
    slice_size: u64;
    slice_size, success = packet_query_next_packet_size(queue);
    if !success {
        return;
    }
    res, allocator_error = make([]u8, slice_size);
    if allocator_error != .None {
        success = false;
        return;
    }
    
    success = packet_dequeue_slice(queue, res);
    return;
}

packet_dequeue :: proc {
    packet_dequeue_slice,
    packet_dequeue_slice_allocating,
    packet_dequeue_parapoly
}

packet_query_next_packet_size :: proc "contextless" (queue: ^Packet_Queue) -> (size: u64, success: bool) {
    using queue;
    success = !packet_queue_empty(queue);
    for i: u64 = 0; i < size_of(u64); i += 1 {
        (transmute([^]u8) &size)[i] = queue_peek_idx(transmute(^Queue(u8)) queue, start + i);
    }
    return;
}
