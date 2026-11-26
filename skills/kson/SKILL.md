---
name: kson
description: Read, write, format, validate, and convert KSON (Kson Structured Object Notation, kson.org), a JSON superset with YAML-like plain syntax, comments, and embed blocks. Use when a repo has `.kson` files, when converting KSON to/from JSON or YAML, validating KSON against a JSON Schema, using the KSON libraries (Python `kson-lang`, npm `@kson_org/kson`, Rust `kson-rs`, JVM `org.kson`), or setting up KSON editor/CI tooling.
---

# KSON

KSON is a strict superset of JSON (RFC 8259, verified against JSONTestSuite). It adds an indentation-free YAML-like "plain" syntax, `#` comments, unquoted simple strings, and embed blocks for code. Every KSON document is one formatter pass from JSON. Verified against `kson-lang` 0.4.0 (released 2026-11-04).

- Site and playground: https://kson.org, https://kson.org/playground/
- Source: https://github.com/kson-org/kson (spec: `docs/readme.md`)
- Prebuilt native libs: https://github.com/kson-org/kson-binaries (releases `kson-lib-X.Y.Z`)

## Quick tool: `scripts/ksonctl.py`

No official CLI binary is published, so use the bundled wrapper. It is a `uv` inline-script over the Python bindings; first run downloads `kson-lang`.

```bash
K=skills/kson/scripts/ksonctl.py          # path from repo root (adjust if symlinked)
$K validate config.kson                   # parse errors and deceptive-indent errors, exit 1 on error
$K validate config.kson --schema schema.kson   # + JSON Schema Draft 7 (schema in KSON or JSON)
$K format config.kson                     # print formatted (plain style, 2 spaces)
$K format -w *.kson                       # rewrite in place
$K format --check *.kson                  # CI gate: exit 1 if unformatted
$K format --style delimited|compact|classic|plain [--indent 4|--tabs] FILE
$K json config.kson [--retain-tags]       # KSON to JSON
$K yaml config.kson [--retain-tags]       # KSON to YAML, comments preserved
cat data.json | $K format -               # JSON to KSON (any JSON is valid KSON)
```

Errors print as `file:line:col: SEVERITY: message`. Needs `uv` and Python 3.11+. Wheels exist only for Linux x86_64 (glibc 2.34+), macOS arm64, and Windows x86_64; elsewhere use the JS package.

Do not rename the script to `kson.py`: it would shadow the `kson` package.

## Syntax: what agents get wrong

**Whitespace never defines structure.** Parsing is greedy: a plain object absorbs every `key: value` it can, and a plain dash list absorbs every `- item` it can. Close them explicitly when needed:

- `.` (end-dot) ends a plain object.
- `=` (end-dash) ends a plain dash list.

```kson
server:
  host: localhost
  port: 8080
  .
logging: debug          # without the `.` above, this would join `server`
```

```kson
teams:
  - name: 'Team A'
    members:
      - Alice
      - Bob
      =                 # without `=`, the next item joins `members`
  - name: 'Team B'
```

KSON rejects "deceptive indentation" (layout that implies a different structure than the parse) as an ERROR. If you see `Deceptive indentation`, add the missing `.` or `=`; do not just re-indent.

Terminators are only needed when a later item belongs to an outer structure. A dash list as a property value ends at the next `key:` on its own. The formatter removes unneeded terminators.

**Strings.**
- Unquoted only if "simple": letters (any alphabet), digits, `_`, `-`; must not start with a digit or `-`.
- Must quote: spaces (`'Golden Ratio'`), dots (`'v1.2'`), leading digits (`'2020-01-01'`), URLs, paths. Unlike YAML, `name: Golden Ratio` is invalid.
- Bare `true`/`false`/`null` are literals; quote them to get strings.
- Single or double quotes; JSON escapes. Raw newlines are allowed inside quotes.
- No YAML implicit typing: no `yes`/`no`, no dates, no anchors/aliases, no `|`/`>` block scalars (use embed blocks).

**Numbers** are JSON numbers exactly (`5`, `-273.15`, `2.998e8`). No `0x`, no `inf`, no leading `+`.

**Lists**, three equivalent styles:
- Plain dash: `- a` lines (`- ` needs the space; `-5` is a number).
- Delimited dash: `< - a - b >`.
- Bracket: `[a b]` or `[a, b]`. Commas are optional everywhere and formatted away.
- Empty list: `[]` or `<>`. Empty object: `{}`.

**Objects**: plain `key: value` lines, or delimited `{ key: value }`. Keys follow the string rules.

**Comments**: `#` to end of line. Comments are preserved by the formatter and by YAML output. JSON output drops them.

**Embed blocks** hold multi-line text or code:

```kson
query: %sql
  SELECT *
  FROM users
  %%
```

- Opens with `%` plus an optional tag (rest of the line). Content starts on the next line and ends at the first `%%`.
- Minimum indent is stripped. The `%%` line counts toward that minimum.
- Escape a literal `%%` inside content as `%\%`. Or use the alternate delimiter `$tag ... $$`.
- In JSON/YAML: by default an embed becomes its content string. With `--retain-tags` / `retain_embed_tags=True`, it becomes `{embedTag, embedContent}`. An object with exactly those two string keys formats back into an embed block.

## Formatting styles

| Style | Use |
|---|---|
| `plain` | Default. YAML-like, for humans |
| `delimited` | `{}` and `<>` everywhere; safe for copy/paste and refactors |
| `compact` | Minified and lossless (keeps comments and embeds) |
| `classic` | Plain JSON formatting |

Write KSON by hand in plain style, then run `format -w`. The formatter output is canonical.

## Converting existing files

- **JSON to KSON**: rename `.json` to `.kson` and run `format -w`. Valid JSON is already valid KSON.
- **YAML to KSON**: no direct converter. Go YAML to JSON (e.g. `yq -o=json`), then JSON to KSON. Comments are lost; re-add them by hand.
- **KSON to YAML/JSON for consumers**: keep `.kson` as source of truth and generate the target in a build step (detekt in the KSON repo does this: `detekt.kson` to a gitignored `detekt.yml`). Commit generated files only if the consumer cannot run the step; then add a CI check that they match.

## Libraries

All are 0.4.0 and wrap the same Kotlin Multiplatform core. The API shape is the same everywhere: `Kson.toJson`, `Kson.toYaml`, `Kson.format`, `Kson.analyze`, `Kson.parseSchema`.

**Python** (`pip install kson-lang` or `uv add kson-lang`, import `kson`):

```python
from kson import Kson, TranspileOptions, Result, FormatOptions, IndentType, FormattingStyle, SchemaResult, KsonValue

r = Kson.to_json(src, TranspileOptions.Json(retain_embed_tags=False))
if isinstance(r, Result.Success):
    data = json.loads(r.output())        # simplest way to get Python dicts
else:
    for e in r.errors():                 # e.message(), e.start().line()/column() are 0-based
        ...

Kson.to_yaml(src, TranspileOptions.Yaml(retain_embed_tags=False))
Kson.format(src, FormatOptions(indent_type=IndentType.Spaces(2),
                               formatting_style=FormattingStyle.PLAIN, embed_block_rules=[]))

a = Kson.analyze(src, None, None)        # a.errors() (with .severity()), a.kson_value(), a.tokens()
sr = Kson.parse_schema(schema_src)
if isinstance(sr, SchemaResult.Success):
    errs = sr.schema_validator().validate(src, None)   # [] means valid
```

- `Kson.analyze` errors carry severity `ERROR` or `WARNING`. Schema violations come back as `WARNING`; treat any of them as a failure.
- Value tree: `KsonObject.properties()`, `KsonArray.elements()`, `KsonString/KsonBoolean.value()`, `KsonNumber.Integer/Decimal.value()`, `KsonEmbed.tag()/content()`. Each node has `.start()`/`.end()`.
- `EmbedRule.from_path_pattern("/scripts/*", "bash", 0)` makes the formatter render matching strings as embed blocks.

**JS/TS**: `npm i @kson_org/kson` (Kotlin/JS build, same API names in camelCase). Use this where Python wheels are unavailable.

**Rust**: crate `kson-rs`. **JVM**: `org.kson:kson-jvm`. **Kotlin Multiplatform**: `org.kson:kson`.

**Native/C**: `kson-org/kson-binaries` releases ship shared libraries (`kson-lib-shared-{amd64-linux,arm64-macos,amd64-windows}.tar.gz`) used by the Python and Rust bindings. Use them only for a new FFI binding:

```bash
gh release download kson-lib-0.4.0 -R kson-org/kson-binaries -p 'kson-lib-shared-arm64-macos.tar.gz'
```

## Editor and LSP

- VS Code: extension `kson.kson`. JetBrains: plugin 28510 "KSON Language". Others: the LSP under `tooling/language-server-protocol` in the source repo.
- Schema association in editors follows the JSON Schema tooling of each plugin. Check the plugin docs before hand-writing settings.

## Building the official CLI (rarely needed)

```bash
git clone https://github.com/kson-org/kson && cd kson
./gradlew :tooling:cli:buildNativeImage     # JDK is managed by the build
# binary: tooling/cli/build/native/nativeCompile/
```

Subcommands: `format`, `validate`, `json`, `yaml`. Shared flags: `-i/--input` (default stdin), `-o/--output`, `-s/--schema`. `format` has `--style`, `--indent-spaces`, `--indent-tabs`. `json`/`yaml` have `--retain-tags`. `validate` has `--show-tokens`. Prefer `ksonctl.py`; the native build takes minutes.

## CI recipe

```bash
skills/kson/scripts/ksonctl.py format --check $(git ls-files '*.kson')
skills/kson/scripts/ksonctl.py validate $(git ls-files '*.kson')
```

Run it in RWX like other checks (needs `uv`). Add `--schema` per file group where a schema exists.

## Troubleshooting

| Message | Fix |
|---|---|
| `Deceptive indentation...` | Add `.` / `=` where the nested structure should end, or use `{}` / `<>` |
| `Unexpected trailing content. The previous content parsed as a complete Kson document.` | Unquoted value with spaces (`y: 1 2`) or a second top-level value. Quote it or wrap it in a list |
| `ImportError: cannot import name ... from 'kson'` | A local file named `kson.py` shadows the package |
| pip falls back to sdist and fails | No wheel for this platform. Use `@kson_org/kson` (npm) |
