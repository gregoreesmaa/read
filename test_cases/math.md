# Math via ZaTeX

Inline formulae like $E=mc^2$ and $\frac{a}{b}$ render natively; display
mathematics centers on its own rows:

$$\sum_{i=1}^{n} i = \frac{n(n+1)}{2}$$

Fenced mathematics renders as a display block with the `math` info
string; the `tex`, `latex`, and `katex` spellings stay LaTeX
syntax-highlighted source code:

```math
\sum_{i=1}^{n} i = \frac{n(n+1)}{2}
```

```tex
\sqrt{x^2 + y^2}
```

```latex
\int_0^1 x\,dx
```

```katex
\alpha + \beta = \gamma
```

Currency stays literal: $100 and $5.99 are prices, not formulae. Unclosed
dollars stay literal too: half $x + 1 renders as text. Code spans mask
mathematics: `$x$` is source code here. An invalid formula falls back to
its source text: $\badcmd{ stays readable, never swallowed.

## Display gallery

$$\frac{d}{dx} e^x = e^x$$

$$a^2 + b^2 = c^2$$

Display islands always center as blocks, even mid-line — the quadratic
$$x = \frac{-b \pm \sqrt{b^2 - 4ac}}{2a}$$ breaks the paragraph above and
below, and $$x$$ likewise takes its own rows.

## Literal gallery

Escaped dollars stay literal: \$x\$ renders as dollar-x-dollar. Backslash
paren forms keep CommonMark escape precedence: \(E=mc^2\) never becomes
math — write `$E=mc^2$` instead.
