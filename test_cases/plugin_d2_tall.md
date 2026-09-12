# Tall D2 Diagram

```d2
direction: down
reader: Reader Opens Document
mmap: Memory Map File
scan: Scan Line Breaks
lines: Index Lines
blocks: Classify Blocks
fence: Fenced Code
table: GFM Tables
quote: Block Quotes
list: Bullet Lists
para: Paragraph Flow
spans: Inline Spans
emph: Emphasis Pairs
links: Links Autolinks
code: Code Spans
image: Image Placeholders
layout: Layout Viewport
view: Virtualized Window
paint: Paint Commands
scroll: Scroll Position
find: Find Matches
select: Selection Range
copy: Copy To Clipboard
idle: Idle Await Input

reader -> mmap: zero-copy open
mmap -> scan: byte window
scan -> lines: break offsets
lines -> blocks: line records
blocks -> fence: code fences
blocks -> table: table rows
blocks -> quote: quote lines
blocks -> list: list markers
fence -> para: other lines
table -> para: cell text
quote -> para: quoted text
list -> para: item text
para -> spans: text runs
spans -> emph: star runs
spans -> links: bare urls
spans -> code: backticks
emph -> image: styled runs
links -> image: linked runs
code -> image: pill runs
image -> layout: sized boxes
layout -> view: visible slice
view -> paint: draw list
paint -> scroll: new offset
scroll -> find: query text
find -> select: match range
select -> copy: copy bytes
copy -> idle: await input
```
