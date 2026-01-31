"""
    TableEdit

Edit tabular data in an external editor (e.g. the EDITOR environment variable), similar to `git rebase -i`.
Dump a table to a text file (with configurable delimiter and comment lines), then parse
the edited file with validation and optional diff.

# Usage

- `prepare_edit(table, path; ...)` — write table to file (or temp file), return path (for tests: edit file manually, then call `finish_edit`).
- `finish_edit(path; ...)` — parse file, validate, return `(ok, result, errors)`.
- `edit_table(table; spawn_editor=true, ...)` — prepare → (optionally) run editor → finish. If `spawn_editor=false`, returns `(path, finish_callback)` so tests can edit the file and call the callback.

# Formats

- Delimited text (CSV/TSV/custom): configurable `delimiter`, `comment_prefix` (e.g. `#`).
- Comment lines are skipped when parsing; you can put usage instructions in the buffer.
"""
module TableEdit

using Dates
using Tables

export prepare_edit,
       finish_edit,
       edit_table,
       diff_table,
       write_table_text,
       parse_table_text,
       ParseError,
       TableDiff

# =============================================================================
# TYPES
# =============================================================================

"""
    ParseError(line, column, message)

A single validation/parse error: `line` (1-based), `column` (name or 1-based index), `message`.
"""
struct ParseError
    line::Int
    column::Union{Int, String}
    message::String
end

"""
    TableDiff(added, removed, modified)

Result of comparing original vs edited table by key columns.
- `added`: rows that appear only in the edited table
- `removed`: rows that appear only in the original
- `modified`: pairs `(old_row, new_row)` for rows with same key but different values
"""
struct TableDiff
    added::Vector{Any}
    removed::Vector{Any}
    modified::Vector{Tuple{Any, Any}}
end

# =============================================================================
# TABLE INPUT: NORMALIZE TO (COLUMNS, ROWS)
# =============================================================================
# Primary: Tables.jl interface (istable, rows, columnnames).
# Fallback: (columns, rows) tuple, or AbstractVector of NamedTuples.

"""
Normalize table-like input to (columns::Vector{String}, rows::Vector{<:NamedTuple}).
Accepts any Tables.jl table, (columns, rows), or AbstractVector of NamedTuples.
"""
function _normalize_table(table)
    # Dispatch: Tables.jl interface (primary)
    if Tables.istable(table)
        return _normalize_table_tables(table)
    end
    # Legacy: (columns, rows) tuple
    if table isa Tuple{<:AbstractVector, <:AbstractVector}
        return _normalize_table_tuple(table)
    end
    # Legacy: vector of NamedTuples
    if table isa AbstractVector && !isempty(table) && first(table) isa NamedTuple
        cols = string.(keys(first(table)))
        return cols, collect(table)
    end
    error("Table must be a Tables.jl table, (columns, rows), or a vector of NamedTuples")
end

function _normalize_table_tables(table)
    col_syms = Tables.columnnames(table)
    cols = string.(col_syms)
    nt_rows = [
        NamedTuple{Tuple(col_syms)}(tuple((Tables.getcolumn(row, nm) for nm in col_syms)...))
        for row in Tables.rows(table)
    ]
    return cols, nt_rows
end

function _normalize_table_tuple(table::Tuple{<:AbstractVector, <:AbstractVector})
    cols, rows = table
    col_names = string.(cols)
    nt_rows = map(rows) do r
        if r isa NamedTuple
            r
        else
            NamedTuple{Tuple(Symbol.(col_names))}(tuple((get(r, c, missing) for c in col_names)...))
        end
    end
    return col_names, nt_rows
end

# =============================================================================
# WRITE: TABLE → DELIMITED TEXT (WITH COMMENTS)
# =============================================================================

const DEFAULT_QUOTE = '"'
const DEFAULT_DELIMITER = '\t'
const DEFAULT_COMMENT_PREFIX = '#'

# Default footer lines (at bottom of file) explaining empty fields and usage
const DEFAULT_FOOTER_LINES = [
    "",
    "Empty fields: leave cell empty, or use \"\" inside quoted fields.",
    "Lines starting with # are ignored. Edit data rows above.",
]

function _escape_cell(s::AbstractString, delimiter::Union{Char, String}, quotechar::Char)
    need_quote = occursin(delimiter, s) || occursin('\n', s) || occursin('\r', s) || occursin(quotechar, s)
    if need_quote
        escaped = replace(string(s), string(quotechar) => string(quotechar, quotechar))
        return string(quotechar, escaped, quotechar)
    end
    return string(s)
end

"""
    write_table_text(io, table; comment_prefix=DEFAULT_COMMENT_PREFIX, delimiter=DEFAULT_DELIMITER,
                    header_comment_lines=String[], footer_comment_lines=nothing, default_footer=true,
                    write_header=true, header_separator=true, align_columns=true, quotechar=DEFAULT_QUOTE)

Write table to `io` (path or `IO`) as delimited text.
- Default delimiter is TAB. Lines in `header_comment_lines` at top (each prefixed with `comment_prefix`).
- Then header row; if `header_separator` true, a line of dashes per column; then data rows.
- If `align_columns` true, pad cells so columns align. If `default_footer` true and `footer_comment_lines` is nothing,
  appends default usage lines at bottom (empty fields, comments). Otherwise `footer_comment_lines` (default empty) at bottom.
"""
function write_table_text(
    io,
    table;
    comment_prefix::Union{Char, String} = DEFAULT_COMMENT_PREFIX,
    delimiter::Union{Char, String} = DEFAULT_DELIMITER,
    header_comment_lines::Vector{<:AbstractString} = String[],
    footer_comment_lines::Union{Nothing, Vector{<:AbstractString}} = nothing,
    default_footer::Bool = true,
    write_header::Bool = true,
    header_separator::Bool = true,
    align_columns::Bool = true,
    quotechar::Char = DEFAULT_QUOTE,
)
    cols, rows = _normalize_table(table)
    cp = string(comment_prefix)
    delim_str = string(delimiter)
    for line in header_comment_lines
        println(io, cp, (isempty(line) ? "" : " " * line))
    end
    ncols = length(cols)
    if write_header
        header_cells = [_escape_cell(string(c), delim_str, quotechar) for c in cols]
        println(io, join(header_cells, delim_str))
    end
    # Build all data rows as strings
    row_cells = Vector{String}[]
    for r in rows
        cells = String[]
        for c in cols
            sym = Symbol(c)
            val = get(r, sym, missing)
            s = val === missing ? "" : string(val)
            push!(cells, _escape_cell(s, delim_str, quotechar))
        end
        push!(row_cells, cells)
    end
    # Optional column alignment: pad to max width per column (header + data)
    widths = fill(0, ncols)
    if align_columns && write_header && !isempty(row_cells)
        all_cells = [header_cells; row_cells]
        for i in 1:ncols
            widths[i] = maximum(i ≤ length(cells) ? textwidth(cells[i]) : 0 for cells in all_cells)
        end
        header_cells = [rpad(header_cells[i], widths[i]) for i in 1:ncols]
        row_cells = [[rpad(row_cells[j][i], widths[i]) for i in 1:ncols] for j in 1:length(row_cells)]
    end
    if write_header && header_separator
        sep_cells = [widths[i] > 0 ? rpad("", widths[i], "-") : "-" for i in 1:ncols]
        println(io, join(sep_cells, delim_str))
    end
    for cells in row_cells
        println(io, join(cells, delim_str))
    end
    # Footer comments (default usage at bottom)
    footer = footer_comment_lines !== nothing ? footer_comment_lines : (default_footer ? DEFAULT_FOOTER_LINES : String[])
    for line in footer
        println(io, cp, (isempty(line) ? "" : " " * line))
    end
    return nothing
end

# =============================================================================
# PARSE: DELIMITED TEXT → (COLUMNS, ROWS) + ERRORS
# =============================================================================

"""
Split one line by delimiter, respecting double-quoted fields. Returns vector of strings.
Inside quoted fields, "" produces one literal quote character.
"""
function _split_delimited_line(line::AbstractString, delimiter::Union{Char, String}, quotechar::Char)
    delim_str = string(delimiter)
    q = quotechar
    parts = String[]
    current = IOBuffer()
    in_quote = false
    i = firstindex(line)
    n = lastindex(line)
    while i <= n
        c = line[i]
        if in_quote
            if c == q
                next_i = nextind(line, i)
                if next_i <= n && line[next_i] == q
                    # Escaped quote: emit one quote, consume both characters
                    write(current, q)
                    i = nextind(line, next_i)
                    continue
                else
                    in_quote = false
                end
            else
                write(current, c)
            end
            i = nextind(line, i)
        else
            if c == q
                in_quote = true
                i = nextind(line, i)
            elseif delim_str isa Char && c == delim_str
                push!(parts, String(take!(current)))
                i = nextind(line, i)
            elseif delim_str isa String && length(delim_str) >= 1
                # Check if we match the delimiter string (character-by-character for UTF-8 safety)
                match = true
                ii = i
                for ch in delim_str
                    if ii > n || line[ii] != ch
                        match = false
                        break
                    end
                    ii = nextind(line, ii)
                end
                if match
                    push!(parts, String(take!(current)))
                    i = ii
                    continue
                end
                write(current, c)
                i = nextind(line, i)
            else
                write(current, c)
                i = nextind(line, i)
            end
        end
    end
    push!(parts, String(take!(current)))
    return parts
end

"""
Split content into logical lines: newline ends a line only when outside a quoted field.
Quote characters are preserved so _split_delimited_line can parse correctly.
"""
function _split_into_logical_lines(content::AbstractString, quotechar::Char)
    content = replace(content, '\r' => "")
    lines = String[]
    current = IOBuffer()
    in_quote = false
    i = firstindex(content)
    n = lastindex(content)
    while i <= n
        c = content[i]
        if in_quote
            if c == quotechar
                next_i = nextind(content, i)
                if next_i <= n && content[next_i] == quotechar
                    # Escaped quote: pass both through so _split_delimited_line can interpret ""
                    write(current, quotechar)
                    write(current, quotechar)
                    i = nextind(content, next_i)
                    continue
                else
                    write(current, quotechar)
                    in_quote = false
                end
            else
                write(current, c)
            end
            i = nextind(content, i)
        else
            if c == quotechar
                write(current, quotechar)
                in_quote = true
                i = nextind(content, i)
            elseif c == '\n'
                push!(lines, String(take!(current)))
                i = nextind(content, i)
            else
                write(current, c)
                i = nextind(content, i)
            end
        end
    end
    push!(lines, String(take!(current)))
    return lines
end

function _parse_table_content(
    content::AbstractString;
    comment_prefix::Union{Char, String} = DEFAULT_COMMENT_PREFIX,
    delimiter::Union{Char, String} = DEFAULT_DELIMITER,
    quotechar::Char = DEFAULT_QUOTE,
)
    cp = string(comment_prefix)
    errors = ParseError[]
    lines = _split_into_logical_lines(content, quotechar)
    header_line = nothing
    data_start = 0
    for (idx, line) in enumerate(lines)
        stripped = lstrip(line)
        if startswith(stripped, cp) || isempty(stripped)
            continue
        end
        header_line = line
        data_start = idx + 1
        break
    end
    if header_line === nothing
        return String[], [], [ParseError(1, 1, "No header line found (only comments or empty lines)")]
    end
    columns = _split_delimited_line(header_line, delimiter, quotechar)
    columns = [strip(c) for c in columns]
    ncols = length(columns)
    rows = []
    for (idx, line) in enumerate(lines[data_start:end])
        line_num = data_start + idx - 1
        stripped = lstrip(line)
        if startswith(stripped, cp) || isempty(stripped)
            continue
        end
        parts = _split_delimited_line(line, delimiter, quotechar)
        if length(parts) != ncols
            push!(errors, ParseError(line_num, 1, "Expected $ncols columns, got $(length(parts))"))
            continue
        end
        # Skip separator line (dashes only, same column count as header)
        if all(p -> isempty(strip(p)) || all(c -> c == '-', strip(p)), parts)
            continue
        end
        vals = (strip(p) for p in parts)
        nt = NamedTuple{Tuple(Symbol.(columns))}(tuple(vals...))
        push!(rows, nt)
    end
    return columns, rows, errors
end

"""
    parse_table_text(
        source::AbstractString;
        comment_prefix=DEFAULT_COMMENT_PREFIX,
        delimiter=DEFAULT_DELIMITER,
        quotechar=DEFAULT_QUOTE,
    ) -> (columns::Vector{String}, rows::Vector{NamedTuple}, errors::Vector{ParseError})

Parse delimited text from a string or from a file path.
- If `source` is the path to an existing file, the file is read and parsed.
- Otherwise `source` is treated as the raw text content.

Lines starting with `comment_prefix` (after optional leading whitespace) are skipped.
First non-comment line is the header; remaining non-empty non-comment lines are data rows.
Returns parsed columns and rows (rows as NamedTuples), and a list of parse errors.
"""
function parse_table_text(
    source::AbstractString;
    comment_prefix::Union{Char, String} = DEFAULT_COMMENT_PREFIX,
    delimiter::Union{Char, String} = DEFAULT_DELIMITER,
    quotechar::Char = DEFAULT_QUOTE,
)
    content = (ispath(source) && isfile(source)) ? read(source, String) : source
    return _parse_table_content(content; comment_prefix = comment_prefix, delimiter = delimiter, quotechar = quotechar)
end

# =============================================================================
# VALIDATION
# =============================================================================

"""
Run validators on parsed (columns, rows). Returns additional ParseErrors.
- required_columns: all must be in columns
- key_columns: must be unique across rows (duplicate key → error)
- column_types: Dict(col => Type); try to parse and add error on failure
"""
function _validate(
    columns::AbstractVector{<:AbstractString},
    rows::AbstractVector,
    required_columns::Union{Nothing, AbstractVector{<:AbstractString}},
    key_columns::Union{Nothing, AbstractVector{<:AbstractString}},
    column_types::Union{Nothing, AbstractDict},
)
    errors = ParseError[]
    cols_set = Set(string.(columns))
    if required_columns !== nothing
        for c in required_columns
            if c ∉ cols_set
                push!(errors, ParseError(1, c, "Required column missing: $c"))
            end
        end
    end
    if key_columns !== nothing && !isempty(key_columns)
        seen = Dict{Any, Int}()
        for (row_idx, row) in enumerate(rows)
            key_vals = tuple((get(row, Symbol(c), missing) for c in key_columns)...)
            if haskey(seen, key_vals)
                push!(errors, ParseError(row_idx + 1, 1, "Duplicate key $(key_vals) (first at row $(seen[key_vals]+1))"))
            else
                seen[key_vals] = row_idx
            end
        end
    end
    if column_types !== nothing
        for (col, T) in column_types
            col_sym = col isa Symbol ? col : Symbol(col)
            for (row_idx, row) in enumerate(rows)
                val = get(row, col_sym, missing)
                val_str = val === missing ? "" : string(val)
                if isempty(val_str) && T !== String
                    continue  # empty often allowed as missing
                end
                try
                    if T == Int
                        parse(Int, val_str)
                    elseif T == Float64
                        parse(Float64, replace(val_str, ',' => '.'))
                    elseif T == Bool
                        v = lowercase(strip(val_str))
                        v in ("true", "1", "yes", "ja") || v in ("false", "0", "no", "nein") || error("not bool")
                    elseif T == String
                        # always ok
                    else
                        T(val)
                    end
                catch
                    push!(errors, ParseError(row_idx + 1, string(col), "Could not parse \"$val_str\" as $T"))
                end
            end
        end
    end
    return errors
end

# =============================================================================
# DIFF
# =============================================================================

"""
    diff_table(original_rows, parsed_rows, key_columns::Vector{<:AbstractString})

Compare original and parsed rows by key. Returns `TableDiff(added, removed, modified)`.
- added: rows in parsed_rows whose key is not in original
- removed: rows in original whose key is not in parsed
- modified: (old, new) for rows with same key but different values
"""
function diff_table(
    original_rows::AbstractVector,
    parsed_rows::AbstractVector,
    key_columns::Vector{<:AbstractString},
)
    key_cols_sym = Tuple(Symbol.(key_columns))
    key_of(row) = getindex(row, key_cols_sym)
    orig_by_key = Dict(key_of(r) => r for r in original_rows)
    parsed_by_key = Dict(key_of(r) => r for r in parsed_rows)
    added = Any[]
    removed = Any[]
    modified = Tuple{Any, Any}[]
    for k in keys(parsed_by_key)
        if !haskey(orig_by_key, k)
            push!(added, parsed_by_key[k])
        elseif orig_by_key[k] != parsed_by_key[k]
            push!(modified, (orig_by_key[k], parsed_by_key[k]))
        end
    end
    for k in keys(orig_by_key)
        if !haskey(parsed_by_key, k)
            push!(removed, orig_by_key[k])
        end
    end
    return TableDiff(added, removed, modified)
end

# =============================================================================
# PREPARE / FINISH / EDIT (EDITOR WORKFLOW)
# =============================================================================

"""
    prepare_edit(table, path::Union{String, Nothing}=nothing;
                 comment_prefix=DEFAULT_COMMENT_PREFIX,
                 delimiter=DEFAULT_DELIMITER,
                 header_comment_lines=String[],
                 footer_comment_lines=nothing,
                 default_footer=true,
                 write_header=true,
                 header_separator=true,
                 align_columns=true,
                 quotechar=DEFAULT_QUOTE,
                 ) -> String

Write table to a file. If `path === nothing`, write to a temporary file and return its path.
Otherwise write to `path` and return `path`. Use this for tests: write to path, then modify file, then call `finish_edit(path; ...)`.
"""
function prepare_edit(
    table,
    path::Union{String, Nothing} = nothing;
    comment_prefix::Union{Char, String} = DEFAULT_COMMENT_PREFIX,
    delimiter::Union{Char, String} = DEFAULT_DELIMITER,
    header_comment_lines::Vector{<:AbstractString} = String[],
    footer_comment_lines::Union{Nothing, Vector{<:AbstractString}} = nothing,
    default_footer::Bool = true,
    write_header::Bool = true,
    header_separator::Bool = true,
    align_columns::Bool = true,
    quotechar::Char = DEFAULT_QUOTE,
    kwargs...,
)
    if path === nothing || path == ""
        (path, io) = mktemp()
        close(io)
    end
    open(path, "w") do io
        write_table_text(
            io,
            table;
            comment_prefix = comment_prefix,
            delimiter = delimiter,
            header_comment_lines = header_comment_lines,
            footer_comment_lines = footer_comment_lines,
            default_footer = default_footer,
            write_header = write_header,
            header_separator = header_separator,
            align_columns = align_columns,
            quotechar = quotechar,
            kwargs...,
        )
    end
    return path
end

"""
    finish_edit(path::AbstractString;
                comment_prefix=DEFAULT_COMMENT_PREFIX,
                delimiter=DEFAULT_DELIMITER,
                quotechar=DEFAULT_QUOTE,
                required_columns=nothing,
                key_columns=nothing,
                column_types=nothing,
                original_table=nothing,
                return_mode=:full,
                ) -> (ok::Bool, result, errors::Vector{ParseError})

Parse and validate the file at `path`.
- `return_mode`:
  - `:full` — result is `(columns, rows)` (parsed table).
  - `:diff` — result is `TableDiff(added, removed, modified)`; requires `original_table` and `key_columns`.
  - `:changes_only` — result is `(added, modified_new_rows)` (only new/changed data); requires `original_table` and `key_columns`.
- If validation fails, `ok` is false, `result` is undefined, `errors` is non-empty.
"""
function finish_edit(
    path::AbstractString;
    comment_prefix::Union{Char, String} = DEFAULT_COMMENT_PREFIX,
    delimiter::Union{Char, String} = DEFAULT_DELIMITER,
    quotechar::Char = DEFAULT_QUOTE,
    required_columns::Union{Nothing, AbstractVector{<:AbstractString}} = nothing,
    key_columns::Union{Nothing, AbstractVector{<:AbstractString}} = nothing,
    column_types::Union{Nothing, AbstractDict} = nothing,
    original_table = nothing,
    return_mode::Symbol = :full,
)
    columns, rows, parse_errors = parse_table_text(path; comment_prefix = comment_prefix, delimiter = delimiter, quotechar = quotechar)
    if !isempty(parse_errors)
        return false, nothing, parse_errors
    end
    val_errors = _validate(columns, rows, required_columns, key_columns, column_types)
    if !isempty(val_errors)
        return false, nothing, val_errors
    end
    if return_mode == :full
        return true, (columns, rows), ParseError[]
    end
    if return_mode in (:diff, :changes_only)
        if original_table === nothing || key_columns === nothing
            return false, nothing, [ParseError(0, 1, "return_mode $(return_mode) requires original_table and key_columns")]
        end
        _, orig_rows = _normalize_table(original_table)
        diff = diff_table(orig_rows, rows, key_columns)
        if return_mode == :diff
            return true, diff, ParseError[]
        end
        # :changes_only => (added, modified_new_rows)
        mod_new = [d[2] for d in diff.modified]
        return true, (diff.added, mod_new), ParseError[]
    end
    return false, nothing, [ParseError(0, 1, "Unknown return_mode: $(return_mode)")]
end

"""
    run_editor(path::AbstractString; editor=nothing)

Run the system editor on `path`. Blocks until the editor exits.
`editor` defaults to `get(ENV, "EDITOR", "vi")`; can be a string (split on spaces) or a vector of strings.
"""
function run_editor(path::AbstractString; editor = nothing)
    ed = editor === nothing ? get(ENV, "EDITOR", "vi") : editor
    cmd_parts = ed isa AbstractVector ? ed : split(string(ed), ' ')
    run(pipeline(Cmd([cmd_parts..., path]), stdin = stdin, stdout = stdout, stderr = stderr))
    return nothing
end

"""
    edit_table(table;
               path::Union{String, Nothing}=nothing,
               editor=nothing,
               spawn_editor::Bool=true,
               header_comment_lines=String[],
               comment_prefix=DEFAULT_COMMENT_PREFIX,
               delimiter=DEFAULT_DELIMITER,
               quotechar=DEFAULT_QUOTE,
               required_columns=nothing,
               key_columns=nothing,
               column_types=nothing,
               original_table=nothing,
               return_mode=:full,
               kwargs...)

Edit table in an external editor (git rebase -i style).

- If `spawn_editor === true`: writes table to file, runs editor, then parses and returns `(ok, result, errors)`.
- If `spawn_editor === false`: writes table to file and returns `(path, finish_fn)` where `finish_fn()` calls `finish_edit(path; ...)` and returns `(ok, result, errors)`. Use this in tests: edit the file on disk, then call `finish_fn()`.

All other keyword arguments are passed through to `prepare_edit` and `finish_edit`.
"""
function edit_table(
    table;
    path::Union{String, Nothing} = nothing,
    editor = nothing,
    spawn_editor::Bool = true,
    header_comment_lines::Vector{<:AbstractString} = String[],
    footer_comment_lines::Union{Nothing, Vector{<:AbstractString}} = nothing,
    default_footer::Bool = true,
    header_separator::Bool = true,
    align_columns::Bool = true,
    comment_prefix::Union{Char, String} = DEFAULT_COMMENT_PREFIX,
    delimiter::Union{Char, String} = DEFAULT_DELIMITER,
    quotechar::Char = DEFAULT_QUOTE,
    required_columns::Union{Nothing, AbstractVector{<:AbstractString}} = nothing,
    key_columns::Union{Nothing, AbstractVector{<:AbstractString}} = nothing,
    column_types::Union{Nothing, AbstractDict} = nothing,
    original_table = nothing,
    return_mode::Symbol = :full,
    kwargs...,
)
    file_path = prepare_edit(
        table,
        path;
        comment_prefix = comment_prefix,
        delimiter = delimiter,
        header_comment_lines = header_comment_lines,
        footer_comment_lines = footer_comment_lines,
        default_footer = default_footer,
        header_separator = header_separator,
        align_columns = align_columns,
        kwargs...,
    )
    finish_fn() = finish_edit(
        file_path;
        comment_prefix = comment_prefix,
        delimiter = delimiter,
        quotechar = quotechar,
        required_columns = required_columns,
        key_columns = key_columns,
        column_types = column_types,
        original_table = original_table,
        return_mode = return_mode,
    )
    if !spawn_editor
        return (file_path, finish_fn)
    end
    run_editor(file_path; editor = editor)
    return finish_fn()
end

end # module
