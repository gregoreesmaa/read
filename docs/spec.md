# Supported Markdown

Strictly CommonMark plus GFM tables/task lists (Daring Fireball syntax).
HTML rendering is intentionally unsupported. Numbers for speed and size live only in the
[README benchmark table](../README.md#benchmarks); nothing here restates them.

## Blocks

- ATX headings (`#`–`######`, optional closing `#`), Setext headings (`===` / `---`)
- Thematic breaks (`---`, `***`, `___`)
- Fenced code blocks (`` ``` `` and `~~~`) and indented code blocks
- Blockquotes, including nested (`>>`); GitHub alerts (`> [!NOTE]`/`TIP`/`IMPORTANT`/`WARNING`/`CAUTION`) tint the bar and label
- Unordered (`*`, `-`, `+`), ordered (`1.`, `1)`), and task (`- [ ]`, `- [x]`) lists
- GFM tables with column measurement, cell alignment, and dividers
- Plugin diagrams (mermaid, d2; cached async render, code fallback)
- YAML frontmatter (`---` … `---`/`...` at byte 0 with a `key: value` line): hidden, renders nothing

## Inlines

- Code spans, emphasis (`*`, `_`), strong (`**`, `__`), triple (`***`, `___`)
- Strikethrough (`~~`), inline links (`[text](url)`), autolinks (`<https://…>`, `<email>`), bare `http(s)://` URLs (GFM), images
- Backslash escapes (`\*`, `\_`, …)

## Heavy features

Anything threatening the zero-allocation, microsecond-grade architecture
(multi-level recursive ASTs, large Unicode tables, …) needs discussion
BEFORE implementation — see [AGENTS.md](../AGENTS.md) §5.
