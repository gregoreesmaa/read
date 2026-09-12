# Syntax Highlighting

### Zig
```zig
const answer: i32 = 42; // the answer
pub fn add(a: i32, b: i32) i32 {
    return a + b; // no overflow here
}
const name = "zig";
```

### C
```c
int answer = 42; /* the answer */
const char *name = "c";
if (answer > 0) { return answer; }
while (answer) { answer--; }
printf("%d\n", answer);
```

### Python
```python
def add(a, b):  # the answer is 42
    name = "python"
    total = a + b + 1
    if total > 0:
        return total
```

### JavaScript
```js
const answer = 42; // the answer
const name = `js ${answer}`;
let total = answer + 1;
if (total > 0) { return name; }
else { return "none"; }
```

### Bash
```bash
# the answer is 42
answer=42
if [ $answer -gt 0 ]; then
  echo "bash $answer"
fi
```

### Diff
```diff
diff --git a/read.zig b/read.zig
index 123..456
@@ -1 +1 @@
-const answer = 41;
+const answer = 42;
```

### TypeScript
```ts
interface Named { name: string; }
const answer: number = 42; // the answer
function hi(n: Named): string {
  return `ts ${n.name}`;
}
```

### Rust
```rust
fn add(a: i32, b: i32) -> i32 {
    let answer = 42; // the answer
    let name = "rust";
    answer + b
}
```

### Go
```go
package main
func add(a int, b int) int {
    answer := 42 // the answer
    return answer + b
}
```

### Java
```java
public class Read {
    public static void main(String[] args) {
        int answer = 42; // the answer
        System.out.println("java " + answer);
    } // end main
```

### Ruby
```ruby
def add(a, b) # the answer is 42
  name = "ruby"
  total = a + b + 1
  return total unless total.nil?
end
```

### Swift
```swift
func add(_ a: Int, _ b: Int) -> Int {
    let answer = 42 // the answer
    guard answer > 0 else { return b }
    return answer + b
}
```

### Kotlin
```kotlin
fun add(a: Int, b: Int): Int {
    val answer = 42 // the answer
    val name = "kotlin"
    return answer + b
}
```

### PHP
```php
function add($a, $b) {
    $answer = 42; // the answer
    echo "php $answer";
    return $answer + $b;
}
```

### C++
```cpp
template <typename T>
T add(T a, T b) {
    int answer = 42; // the answer
    return a + b;
}
```

### CSharp
```csharp
using System;
namespace Read {
    class Demo {
        int answer = 42; // the answer
    } // end
```

### HTML
```html
<!-- the answer is 42 -->
<div class="demo">
  <p>Hello html</p>
  <a href="/">link</a>
</div>
```

### CSS
```css
/* the answer is 42 */
.demo {
  color: red;
  margin: 42px;
}
```

### SQL
```sql
-- the answer is 42
SELECT name FROM readers
WHERE answer = 42 AND name IS NOT NULL
ORDER BY name LIMIT 10;
DELETE FROM readers WHERE answer < 0;
```

### Lua
```lua
-- the answer is 42
function add(a, b)
  local answer = 42
  return answer + b
end
```
