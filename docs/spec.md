# Supported Markdown

Strictly CommonMark plus GFM tables/task lists (Daring Fireball syntax).
HTML rendering is intentionally unsupported. Numbers for speed and size live only in the
[README benchmark table](../README.md#benchmarks); nothing here restates them.

## Blocks

- ATX headings (`#`–`######`, optional closing `#`), Setext headings (`===` / `---`)
- Thematic breaks (`---`, `***`, `___`)
- Fenced code blocks (`` ``` `` and `~~~`) and indented code blocks
- Blockquotes, including nested (`>>`)
- Unordered (`*`, `-`, `+`), ordered (`1.`, `1)`), and task (`- [ ]`, `- [x]`) lists
- GFM tables with column measurement, cell alignment, and dividers

## Inlines

- Code spans, emphasis (`*`, `_`), strong (`**`, `__`), triple (`***`, `___`)
- Strikethrough (`~~`), inline links (`[text](url)`), autolinks (`<https://…>`, `<email>`), images
- Backslash escapes (`\*`, `\_`, …)

## Heavy features

Anything threatening the zero-allocation, microsecond-grade architecture
(multi-level recursive ASTs, large Unicode tables, …) needs discussion
BEFORE implementation — see [AGENTS.md](../AGENTS.md) §5.
