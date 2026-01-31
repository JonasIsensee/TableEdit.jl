# TableEdit.jl

Edit tabular data in an external editor (e.g. `EDITOR`), similar to `git rebase -i`: dump a table to a delimited text file, then parse the edited file with validation and optional diff.

![TableEdit.jl Demo](demo.gif)

## Install

From the Julia REPL:

```julia
using Pkg
Pkg.add(url="https://github.com/JonasIsensee/TableEdit.jl")
```

## Usage

- **`prepare_edit(table, path; ...)`** — Write table to a file (or a temp file if `path` is `nothing`). Return the path. For tests: edit the file manually, then call `finish_edit(path; ...)`.
- **`finish_edit(path; ...)`** — Parse the file, run validators, return `(ok, result, errors)`.
- **`edit_table(table; spawn_editor=true, ...)`** — Prepare → (optionally) run the editor → finish. If `spawn_editor=false`, returns `(path, finish_callback)` so tests can modify the file and call the callback.

**Table input**: Any [Tables.jl](https://github.com/JuliaData/Tables.jl) table (e.g. `(id=[1,2], name=["A","B"])`), a `(columns, rows)` tuple, or a vector of NamedTuples. Tables.jl is the primary interface; the others are supported via dispatch.

## Format

- **Delimited text**: default **TAB** delimiter (easier to read); configurable `delimiter`, `comment_prefix` (default `'#'`).
- **Default layout**: header row → separator line (dashes) → data rows (column-aligned) → **footer comment lines** at the bottom explaining empty fields and that lines starting with `#` are ignored.
- **Comment lines** are skipped when parsing; you can put usage instructions in the buffer.
- **Quoting**: Fields that contain the delimiter, newline, or quote character are written in double quotes; internal `"` are doubled (`""` → one `"`). The parser respects the same rules.
- **Empty fields**: leave cell empty, or use `""` inside quoted fields. Footer documents this.

## Parser behavior (custom implementation)

- **Logical lines**: Newline ends a line only when outside a quoted field. Newlines inside quoted fields are preserved.
- **Escaped quotes**: Inside a quoted field, `""` is one literal `"`.
- **CRLF**: `\r` is stripped before parsing so `\r\n` is treated as line break.
- **Comments**: Lines that start with `comment_prefix` (after optional leading whitespace) are skipped. The comment prefix is not treated as comment inside a quoted field.
- **Column count**: First non-comment line is the header; its column count is required for every data row. Rows with wrong column count produce a parse error and are skipped.
- **Empty / comment-only input**: Yields “No header line found”.

## Options

- `delimiter` (default `'\t'`), `comment_prefix`, `quotechar` — Format.
- `header_comment_lines` — Lines written at the top, each prefixed with `comment_prefix`.
- `footer_comment_lines`, `default_footer` (default `true`) — Footer at bottom; when `default_footer` is true, appends usage (empty fields, comments).
- `header_separator` (default `true`), `align_columns` (default `true`) — Visual structure: separator line under header, column alignment.
- `required_columns` — All must appear in the header.
- `key_columns` — Must be unique across rows (duplicate key → validation error).
- `column_types` — `Dict(col => Type)`; parse and validate (e.g. `Int`, `Float64`, `Bool`).
- `return_mode` — `:full` (default) → `(columns, rows)`; `:diff` → `TableDiff`; `:changes_only` → `(added, modified_new_rows)`. For `:diff` / `:changes_only` you must pass `original_table` and `key_columns`.

## Demo

### Quick example: Interactive editing workflow

```julia
using TableEdit

# Start with a table (any Tables.jl compatible format)
table = (id=[1,2,3], name=["Alice","Bob","Carol"], score=[85,92,78])

# Open in editor - this creates a formatted text file and opens $EDITOR
edit_table(table)
```

**What you see in your editor:**
```
# Empty fields can be left blank or use "". Lines starting with # are ignored.

id	name	score
---	----	-----
1	Alice	85
2	Bob	92
3	Carol	78
```

**Make your edits:**
```
# Empty fields can be left blank or use "". Lines starting with # are ignored.

id	name	score
---	----	-----
1	Alice	90      # Changed score from 85 to 90
2	Bob	92
3	Carol	78
4	Dave	88      # Added new row
# Removed Carol's row above, added Dave
```

**After saving and closing the editor:**
```julia
# Returns: (ok, result, errors)
# ok = true
# result = (["id","name","score"], [(id="1",name="Alice",score="90"), ...])
```

### Advanced: Validation and diff tracking

```julia
# Track changes with validation
ok, diff, errs = edit_table(
    original_table,
    key_columns = ["id"],           # IDs must be unique
    column_types = Dict("score" => Int),  # Score must be an integer
    return_mode = :diff             # Get structured diff
)

# diff contains:
#   diff.added     - new rows (Dave)
#   diff.modified  - [(old_row, new_row), ...] (Alice: 85→90)
#   diff.removed   - deleted rows (Carol)
```

### More examples

Run the interactive demo script:
```bash
julia --project demo.jl
```

This demonstrates parsing, validation, type checking, and programmatic usage without spawning an editor.

## Development and testing

Clone the repo, then from the package directory:

```bash
julia --project -e 'using Pkg; Pkg.instantiate(); Pkg.test()'
```

The test suite includes reliability/adversarial cases: empty input, comment-only, comment prefix inside quoted fields, empty quoted fields, consecutive delimiters, newlines and CRLF inside quotes, escaped quotes, wrong column counts, quoted header names, and round-trips with tricky values.
