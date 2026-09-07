# FINDABILITY — web-side GitHub settings (owner action, copy-paste)

These settings live in GitHub's web UI / API, not in git — a maintainer must apply them
at <https://github.com/gregoreesmaa/read/settings>. Everything below is copy-paste ready.

## 1. About → Description (1 line)

```text
Ultra-minimalist zero-dependency Markdown reader in Zig — mmap + SIMD, microsecond rendering, native macOS CoreText
```

## 2. About → Website

```text
https://github.com/gregoreesmaa/read/blob/main/showcase.md
```

(Use the repo URL until there is a real homepage; points visitors at the live demo doc.)

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

- [ ] Repo header shows description + website + topics.
- [ ] `https://github.com/gregoreesmaa/read` search-matches "zig markdown reader mmap simd".
- [ ] Social card renders on the repo page and in link unfurls.
- [ ] CI badge in README is green (`.github/workflows/ci.yml` on default branch).
