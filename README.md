siopkgs
-------

This is an extra Odin packageset, largely intended for my own use.

# contents
| package name | description | status |
| ------------ | ----------- | ------ |
| `alloc` | a set of allocators, intended for use with (optionally provided from the outside) sections of virtual memory that are committed on demand to actual pages | mildly tested |
| `collections` | a ring buffer implementation | untested |
| `linux.io_uring` | the `io_uring(7)` interface | untested |
| `loader` | a handmade hero / Casey Muratori style program loader, supposed to facilitate runtime reloading of program code | mildly tested (Linux only at the moment, might work on Windows but who knows) |
| `util` | a few small utility functions, e.g. contextless memcpy/memset, fixing up allocators embedded in runtime structs | mildly tested |

# supported platforms
Only Linux, at the moment. Windows support would be reasonably easy to add (except for `io_uring`, of course, but that's obviously Linux-specific).

# the name
I'm bad at naming things, hence the name of the collection. If you can come up with a more descriptive name, let me know and I may rename this.

# license
BSD 3-clause, see LICENSE file. Intentionally the same license as Odin itself, should parts of this be included there.
