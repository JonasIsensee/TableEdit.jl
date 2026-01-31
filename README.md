# TableEdit.jl

Edit tabular data in an external editor (e.g. `EDITOR`), similar to `git rebase -i`: dump a table to a delimited text file, then parse the edited file with validation and optional diff.

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

Run the interactive demo to see all features in action:

```bash
julia --project demo.jl
```

Or copy-paste this quick example:

```julia
using TableEdit

# Create a sample table
cols = ["id", "name", "email"]
rows = [
    (id = "1", name = "Alice", email = "alice@example.com"),
    (id = "2", name = "Bob", email = "bob@example.com"),
    (id = "3", name = "Carol", email = "carol@example.com"),
]
table = (cols, rows)

# Write to buffer (with header comments)
io = IOBuffer()
write_table_text(
    io,
    table;
    header_comment_lines = ["Edit the table below. Lines starting with # are ignored.", ""],
)
println(String(take!(io)))

# Parse from string or file
cols_parsed, rows_parsed, errs = parse_table_text(path_or_string)
@assert isempty(errs)

# Validation: required columns, unique keys, type checking
ok, result, errs = finish_edit(
    path;
    required_columns = ["id", "name"],
    key_columns = ["id"],  # must be unique
    column_types = Dict("id" => Int),
)

# Diff mode: see what changed
ok, diff, _ = finish_edit(
    path;
    original_table = orig,
    key_columns = ["id"],
    return_mode = :diff,  # or :changes_only
)
println("Added: ", length(diff.added))
println("Modified: ", length(diff.modified))
println("Removed: ", length(diff.removed))

# Simulate editor interaction
path_edit, finish_fn = edit_table(table; spawn_editor = false)
write(path_edit, "id,name,email\n1,Alice,new@example.com\n")
ok, result, errs = finish_fn()
```

## Development and testing

Clone the repo, then from the package directory:

```bash
julia --project -e 'using Pkg; Pkg.instantiate(); Pkg.test()'
```

The test suite includes reliability/adversarial cases: empty input, comment-only, comment prefix inside quoted fields, empty quoted fields, consecutive delimiters, newlines and CRLF inside quotes, escaped quotes, wrong column counts, quoted header names, and round-trips with tricky values.
