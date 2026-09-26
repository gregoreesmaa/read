# Wide D2 Diagram

```d2
direction: right
in: Request In
auth: Auth Check
cache: Cache Lookup
deny: Deny
serve: Serve Hit
plan: Plan Layout
tok: Tokenize
idx: Index
bidi: Bidi Split
code: Code Spans
join: Join Runs
styles: Apply Styles
img: Images
paint: Paint
idle: Idle

in -> auth
auth -> cache: allow
auth -> deny: deny
cache -> serve: hit
cache -> plan: miss
plan -> tok
tok -> idx
idx -> bidi
bidi -> code
code -> join
join -> styles
styles -> img
img -> paint
paint -> idle
deny -> idle
serve -> idle
```
