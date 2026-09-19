# LaTeX math in Read (rendered with ZaTeX)

Every formula on this page lays out through the ZaTeX engine. If the
engine is missing, each one falls back to its source text — nothing is
ever swallowed.

## Inline formulae

Einstein's $E=mc^2$ sits on the text baseline, as does $\frac{a}{b}$ and
a Greek sum $\sum_{i=1}^{n} i = \frac{n(n+1)}{2}$ mid-sentence.

## Display formulae

A whole-line `$$…$$` island centers on its own rows:

$$\sum_{i=1}^{n} i = \frac{n(n+1)}{2}$$

$$\int_0^1 x\,dx = \frac{1}{2}$$

A display island also works mid-line: the identity $$e^{i\pi} + 1 = 0$$
keeps display metrics right here in prose, never breaking the paragraph.

## Fenced blocks

The `math` fence routes to ZaTeX as a display block, while `tex`,
`latex`, and `katex` stay LaTeX syntax-highlighted source code.

```math
\sqrt{x^2 + y^2}
```

```tex
\lim_{x \to 0} \frac{\sin x}{x} = 1
```

```latex
\alpha^2 + \beta^2 = \gamma^2
```

```katex
x \neq y \;\; a \leq b \;\; p \pm \sqrt{\Delta}
```

## Stays literal

Prices are not formulae: $100 and $5.99 render as text. An unclosed
dollar stays literal too: half $x + 1 is just text. Code spans mask
mathematics: `$x^2$` is source code here. Backslash forms keep CommonMark
escape precedence, so \(x\) and \[y\] stay literal — write `$x$` and
`$$y$$` instead. An invalid formula falls back to its source, readable
as ever: $\badcmd{ never disappears.
