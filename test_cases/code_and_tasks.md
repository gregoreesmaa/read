# Code Blocks and Interactive Tasks

```zig
const std = @import("std");

pub fn main() void {
    const stdout = std.io.getStdOut().writer();
    stdout.print("Zero dependencies. Microsecond speed. Distinct per-block horizontal scrolling with right-alignment clamping.\n", .{}) catch {};
}
```

### Task Lists & Checkboxes

- [x] Zero runtime dependencies
- [x] Branchless SIMD line scanning
- [x] Precise sub-pixel CoreText typography
- [ ] Multi-tab document switcher
- [ ] Live hot-reload watcher

### Ordered Roadmap

1. Memory map file zero-copy
2. Scan vector line breaks
3. Layout visible viewport elements
