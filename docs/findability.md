# Findability — applied GitHub settings

> Status: **applied**. Description, website, and all 14 topics below are live
> on the repo header. Kept for the record and for the social-preview step.

## 1. About → Description

```text
Ultra-minimalist zero-dependency Markdown reader in Zig — mmap + SIMD, microsecond rendering, native macOS CoreText
```

## 2. About → Website

```text
https://gregoreesmaa.github.io/read/
```

The docs site (`docs/site/`, published via GitHub Pages). Falls back to
`https://github.com/gregoreesmaa/read/blob/main/showcase.md` if Pages is off.

## 3. About → Topics (click "Add topics", one per line)

```text
zig
markdown-reader
markdown
zero-dependency
mmap
simd
core-text
macos
microsecond
performance
cocoatext
reader
minimalist
native
```

Why these: `zig`, `markdown-reader`, `zero-dependency`, `mmap`, `simd`, `core-text`,
`macos`, `microsecond` are the exact search keywords mirrored in the README pitch
paragraph, so GitHub search matches both topics and README text.

## 4. Social preview (About → Social preview → Upload)

- Use the README hero so the card matches the repo front page: `screenshots/text_wrapping.png`
  (1280×640 PNG; GitHub's recommended social-image size) with the one-line pitch from §1 as the headline.
- Suggested headline text on the image (no numbers here — the README comparison table is the
  single claims surface; never copy figures into discovery copy):

```text
Read — microsecond-grade Markdown in pure Zig.
```

## 5. After applying (verify)

- [x] Repo header shows description + website + topics.
- [x] `https://github.com/gregoreesmaa/read` search-matches "zig markdown reader mmap simd".
- [ ] Social card renders on the repo page and in link unfurls.
- [ ] CI badge in README is green (`.github/workflows/ci.yml` on default branch).
