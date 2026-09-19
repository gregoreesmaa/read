# Math gallery

A wider sweep of ZaTeX rendering: nested constructs, accents, delimiters,
and display blocks. Live render; anything the engine refuses stays
literal source text, never swallowed.

## Nesting

Nested fractions shrink to fit the row: $\frac{\frac{a}{b}}{\frac{c}{d}}$
right inline, and powers stack: $x^{2^3}$ with $a_{i_j}$ below.

Nested radicals join every vinculum: $\sqrt{\sqrt{x} + \sqrt[3]{y}}$ inline.

## Accents and lines

Accents center on their nuclei: $\tilde{x}$ and $\hat{y}$ with $\vec{v}$
and $\dot{z}$ beside them. Overline spans: $\overline{AB}$ and
$\underline{AB}$ underline below.

## Delimiters

Fences wrap tall content:

$$\left(\frac{a}{b}\right) + \left[ x^2 \right] + |z|$$

Binomial coefficients: $\binom{n}{k} = \frac{n!}{k!(n-k)!}$ inline.

## Display blocks

$$\sum_{k=1}^{n} k^2 = \frac{n(n+1)(2n+1)}{6}$$

$$\lim_{x \to 0} \frac{\sin x}{x} = 1 \qquad \int_0^\infty e^{-x^2}\,dx = \sqrt{\pi}$$

Greek soup: $\alpha\beta\gamma\Delta\Omega$ with $\pm \times \div$.

```math
\begin{matrix} a & b \\ c & d \end{matrix}
```
