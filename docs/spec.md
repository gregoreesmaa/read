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
- Plugin diagrams (mermaid; cached async render, code fallback)
- YAML frontmatter (`---` … `---`/`...` at byte 0 with a `key: value` line): hidden, renders nothing
- Math blocks via ZaTeX: fenced `math`, and whole-line `$$...$$`
  display formulae (single line; multi-line display uses fences).
  `tex`/`latex`/`katex` fences stay LaTeX syntax-highlighted code blocks

## Inlines

- Code spans, emphasis (`*`, `_`), strong (`**`, `__`), triple (`***`, `___`)
- Strikethrough (`~~`), inline links (`[text](url)`), autolinks (`<https://…>`, `<email>`), bare `http(s)://` URLs (GFM), images
- Math islands via ZaTeX (`$...$` inline on the baseline; whole-line
  `$$...$$` centers as a block, mid-line keeps display metrics in the
  text flow). Currency guards: `$100`, `$5.99`, `$ `, and unclosed dollars
  stay literal; code spans mask islands; backslash forms stay literal
  (CommonMark escape precedence)
- Backslash escapes (`\*`, `\_`, …)

## Math rendering (ZaTeX plugin)

All formulae lay out through the ZaTeX engine, loaded at runtime from
`libzatex.dylib` (app-bundle `Resources/` or `/usr/local/lib`) via `dlopen`
— never linked, so the binary keeps its budgets with the engine absent.
Metrics come from the system STIX Two Math font; MATH-table italic
corrections are supplied so accents center on slanted nuclei, while the
remaining refinements (taller delimiter variants, kerning corrections)
stay unwired in v1. The frozen C surface drops per-run color (ambient paint)
and skips diagonal strikes (never misdrawn).

Fallback is sourcetelling, never silent: engine absent or refusing (invalid
input, over 64 KiB, too deep, expansion limit) renders fences as plain code
cards and islands as literal text, byte-identical to the pre-math reader.
True glyph extents feed the engine over the v4 C surface (sqrt junction
included; ink bounds stay NULL — measured 2px shy of full overlap);
MATH-table italic corrections are supplied (accent centering); taller
delimiter variants and kerning corrections stay unwired in v1.
v1 limits: inline boxes taller than one row shrink to fit it
(mid-line display included — never an overlap, never a paragraph
break); math is not selectable, not
find-highlighted, and not copyable; math inside link text, headings,
and block code stays literal; display delimiters spanning source lines
need fence form. Fixture: `test_cases/math.md`.

## Heavy features

Anything threatening the zero-allocation, microsecond-grade architecture
(multi-level recursive ASTs, large Unicode tables, …) needs discussion
BEFORE implementation — see [AGENTS.md](../AGENTS.md) §5.
