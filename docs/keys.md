# Keys, Selection & Scrolling

## Navigation

| Key | Action |
| :--- | :--- |
| `j` / `Down` | Scroll down (40px) |
| `k` / `Up` | Scroll up (40px) |
| `Space` | Page down (80% window height) |
| `h` / `l` | Scroll hovered code block or table horizontally (30px) |
| Trackpad swipe | Horizontal scroll on hovered code block or table |
| `t` | Toggle dark / light theme |
| `Cmd+C` | Copy selection to system clipboard |
| `Cmd+A` | Select all text in document |
| `q` | Quit |

## Selection & clipboard

- Drag selects across all block elements (headings, paragraphs, lists, tables, code).
- Double-click locks in a word; the following mouse-up never overwrites it.
- Triple-click selects the line. `Cmd+A` selects all.
- Copy via `Cmd+C` or the right-click context menu (Copy, Select All, open/copy link).
- Code blocks show a hover "Copy" button; links open in the browser on click.

## Per-block horizontal scrolling

Code blocks and tables scroll horizontally, each independently:

- **Hover-activated**: a block scrolls only while the cursor is over that block.
- **Independent**: scrolling one block never moves another.
- **Clamped**: max scroll aligns the content's right edge with the container
  (`max_scroll_x = @max(0.0, content_w - container_w)`).
