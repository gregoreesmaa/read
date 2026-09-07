# Privacy: Remote Images

Remote images (`https://…`) load by default (per #45) so documents render
completely — but a tracking pixel would otherwise leak your IP and read
timing with zero indication. The policy:

- A visible indicator appears whenever the document contains remote
  content; press `i` to drop **all** remote images to placeholders (press
  again to re-allow).
- **HTTPS-only**: plain-`http://` image URLs are never fetched, even with
  remote images on. URLs with embedded credentials (`user:pass@host`)
  are never fetched either.
- **No credentials, cookies, or `Referer`** are stored or sent; image
  fetches are bare GETs. Redirects are capped at 3, fetches time out
  after 8s, and bodies over 8 MiB are rejected — a tarpit or bomb
  degrades to a placeholder, never a hang.
- Blocked URLs never reach the loader at all (gated before any fetch is
  kicked), so a malicious doc with 10k remote images costs layout only.

Enforced in `src/core/remote_policy.zig` (`blockedByPolicy`) and pinned
by its unit tests; the `i` binding is listed in [keys.md](keys.md).
