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

### Hanging Indent Continuations

1. Ordered lead with fence and paragraph:
   ```bash
   zig build test
   ```
   100% of continuation lines align under the lead text, never the marker.
   Lazy followers ride along at the same column.

- Bullet lead with a fence and paragraph:
  ```
  echo bullet
  ```
  Two-space continuations stay inside the bullet item.

### Multi-Level Indent: Text Paragraphs

- Level zero lead with a continuation line riding along
  under the lead text, never the marker.
  - Level one lead with its own continuation line riding
    along at the nested lead column.
    - Level two lead with a continuation line proving the
      third column holds its followers.
      - Level three lead with a continuation line at the
        fourth column, still inside the item.
        - Level four lead with a continuation line holding
          the fifth column alignment.
          - Level five lead with a continuation line at the
            deepest column of the chain.

1. Ordered level zero lead with a continuation line under
   the lead text, never the marker.
   1. Ordered level one lead with its continuation riding
      at the nested ordered column.
      1. Ordered level two lead with a continuation holding
         the deepest ordered column.

### Multi-Level Indent: Code Blocks

- Level zero item carrying a fence:
  ```
  echo zero
  ```
  trailing line stays at the level zero column.
  - Level one item carrying a fence:
    ```
    echo one
    ```
    trailing line stays at the level one column.
    - Level two item carrying a fence:
      ```
      echo two
      ```
      trailing line stays at the level two column.
      - Level three item carrying a fence:
        ```
        echo three
        ```
        trailing line stays at the level three column.
        - Level four item carrying a fence:
          ```
          echo four
          ```
          trailing line stays at the level four column.
          - Level five item carrying a fence:
            ```
            echo five
            ```
            trailing line stays at the level five column.
