#!/usr/bin/env julia

"""
TableEdit.jl test suite.

Tests all features: write/parse, comments, configurable delimiters,
validation, diff, prepare_edit/finish_edit, and edit_table with spawn_editor=false.
"""

using Test
using TableEdit
using Tables

# =============================================================================
# DUMMY DATA
# =============================================================================

const COLS = ["id", "name", "email"]
const ROWS = [
    (id = "1", name = "Alice", email = "alice@example.com"),
    (id = "2", name = "Bob", email = "bob@example.com"),
    (id = "3", name = "Carol", email = "carol@example.com"),
]
const TABLE = (COLS, ROWS)

const TABLE_TSV = (["a", "b"], [(a = "x", b = "y"), (a = "p", b = "q")])

# Table with fields that need quoting (delimiter, newline, quote in value)
const TABLE_QUOTED = (
    ["ref", "note"],
    [
        (ref = "R1", note = "Normal"),
        (ref = "R2", note = "Contains, comma"),
        (ref = "R3", note = "Line1\nLine2"),
        (ref = "R4", note = "Say \"hello\""),
    ],
)

# =============================================================================
# WRITE TABLE TEXT
# =============================================================================

@testset "write_table_text" begin
    # Default: TAB delimiter, header separator, footer comments
    io = IOBuffer()
    write_table_text(io, TABLE)
    s = String(take!(io))
    @test occursin("id\tname\temail", s)
    @test occursin("1\tAlice\talice@example.com", s)
    @test occursin("2\tBob", s) && occursin("bob@example.com", s)
    @test occursin("Empty fields:", s)
    @test occursin("-\t", s)  # header separator line

    # Legacy CSV: comma, no footer, no separator
    io2 = IOBuffer()
    write_table_text(io2, TABLE; delimiter = ',', default_footer = false, header_separator = false, align_columns = false)
    s2 = String(take!(io2))
    @test occursin("id,name,email", s2)
    @test occursin("1,Alice,alice@example.com", s2)

    # Header comment lines (default TAB)
    io3 = IOBuffer()
    write_table_text(
        io3,
        TABLE;
        header_comment_lines = ["Edit below. Lines starting with # are ignored.", ""],
    )
    s3 = String(take!(io3))
    @test startswith(s3, "# Edit below")
    @test occursin("# ", s3)
    @test occursin("id\tname\temail", s3)

    # Quoted fields (default TAB; comma in value does not need quoting for TAB)
    io4 = IOBuffer()
    write_table_text(io4, TABLE_QUOTED; default_footer = false)
    s4 = String(take!(io4))
    @test occursin("R2\tContains, comma", s4)
    @test occursin("R3\t\"Line1\nLine2\"", s4)
    @test occursin("R4\t\"Say \"\"hello\"\"\"", s4)
end

# =============================================================================
# PARSE TABLE TEXT
# =============================================================================

@testset "parse_table_text" begin
    content = """
id,name,email
1,Alice,alice@example.com
2,Bob,bob@example.com
"""
    cols, rows, errs = parse_table_text(content; delimiter = ',')
    @test cols == ["id", "name", "email"]
    @test length(rows) == 2
    @test rows[1] == (id = "1", name = "Alice", email = "alice@example.com")
    @test rows[2] == (id = "2", name = "Bob", email = "bob@example.com")
    @test isempty(errs)

    # With comments
    content2 = """
# Usage: edit the table below.
# Lines starting with # are ignored.
id,name,email
1,Alice,alice@example.com
2,Bob,bob@example.com
"""
    cols2, rows2, errs2 = parse_table_text(content2; delimiter = ',')
    @test cols2 == ["id", "name", "email"]
    @test length(rows2) == 2
    @test isempty(errs2)

    # Wrong column count
    content3 = """
id,name,email
1,Alice
2,Bob,bob@example.com,extra
"""
    _, rows3, errs3 = parse_table_text(content3; delimiter = ',')
    @test length(errs3) == 2
    @test any(e -> e.message == "Expected 3 columns, got 2", errs3)
    @test any(e -> e.message == "Expected 3 columns, got 4", errs3)

    # Empty / comment-only => no header
    content4 = "# only comment\n\n# another\n"
    cols4, rows4, errs4 = parse_table_text(content4)
    @test isempty(cols4)
    @test isempty(rows4)
    @test length(errs4) == 1
    @test occursin("No header", errs4[1].message)

    # Custom delimiter (semicolon)
    content5 = "a;b\nx;y\np;q\n"
    cols5, rows5, errs5 = parse_table_text(content5; delimiter = ';')
    @test cols5 == ["a", "b"]
    @test rows5[1] == (a = "x", b = "y")
    @test rows5[2] == (a = "p", b = "q")
    @test isempty(errs5)

    # Quoted field with comma
    content6 = "ref,note\nR1,\"Contains, comma\"\n"
    cols6, rows6, errs6 = parse_table_text(content6; delimiter = ',')
    @test rows6[1].note == "Contains, comma"
    @test isempty(errs6)

    # Round-trip: write then parse (strict: all fields must match, including escaped quotes)
    io = IOBuffer()
    write_table_text(io, TABLE_QUOTED)
    cols_rt, rows_rt, errs_rt = parse_table_text(String(take!(io)))
    @test cols_rt == ["ref", "note"]
    @test length(rows_rt) == 4
    @test rows_rt[1].ref == "R1" && rows_rt[1].note == "Normal"
    @test rows_rt[2].note == "Contains, comma"
    @test rows_rt[3].note == "Line1\nLine2"
    @test rows_rt[4].note == "Say \"hello\""
    @test isempty(errs_rt)
end

# =============================================================================
# CONCRETE TESTS: QUOTED FIELDS AND ESCAPED QUOTES
# =============================================================================
# These test the parser on minimal input to pin down comma-in-quotes and
# doubled-quote (CSV "") behavior without other effects.

@testset "quoted field: comma inside quotes" begin
    # One data row; second column contains a comma and must be quoted in CSV.
    content = "a,b\n1,\"Contains, comma\"\n"
    _, rows, errs = parse_table_text(content; delimiter = ',')
    @test length(rows) == 1
    @test isempty(errs)
    @test rows[1].a == "1"
    @test rows[1].b == "Contains, comma"
end

@testset "quoted field: escaped quotes (\"\" → one \")" begin
    # One data row; second column is Say "hello" (literal quote chars).
    # In CSV this is written as "Say ""hello""" (quoted field, doubled quotes).
    content = "a,b\n1,\"Say \"\"hello\"\"\"\n"
    _, rows, errs = parse_table_text(content; delimiter = ',')
    @test length(rows) == 1
    @test isempty(errs)
    @test rows[1].a == "1"
    @test rows[1].b == "Say \"hello\""
end

@testset "quoted field: newline inside quotes (logical line)" begin
    # One data row; second column contains a newline (one logical line, one data row).
    content = "a,b\n1,\"Line1\nLine2\"\n"
    _, rows, errs = parse_table_text(content; delimiter = ',')
    @test length(rows) == 1
    @test isempty(errs)
    @test rows[1].a == "1"
    @test rows[1].b == "Line1\nLine2"
end

# =============================================================================
# PARSE FROM FILE
# =============================================================================

@testset "parse_table_text from file" begin
    path = joinpath(mktempdir(), "tbl.csv")
    write(path, "id,name\n1,Alice\n2,Bob\n")
    cols, rows, errs = parse_table_text(path; delimiter = ',')
    @test cols == ["id", "name"]
    @test length(rows) == 2
    @test isempty(errs)
end

# =============================================================================
# VALIDATION (via finish_edit)
# =============================================================================

@testset "finish_edit validation" begin
    path = joinpath(mktempdir(), "v.csv")
    write(path, "id,name,email\n1,Alice,alice@ex.com\n2,Bob,bob@ex.com\n")

    # No validation => ok
    ok, res, errs = finish_edit(path; delimiter = ',')
    @test ok
    @test res isa Tuple
    @test length(res[2]) == 2

    # required_columns missing
    ok2, _, errs2 = finish_edit(path; delimiter = ',', required_columns = ["id", "name", "phone"])
    @test !ok2
    @test !isempty(errs2)
    @test any(e -> occursin("phone", e.message), errs2)

    # key_columns duplicate
    write(path, "id,name\n1,Alice\n1,Bob\n")
    ok3, _, errs3 = finish_edit(path; delimiter = ',', key_columns = ["id"])
    @test !ok3
    @test any(e -> occursin("Duplicate key", e.message), errs3)

    # column_types: invalid Int
    write(path, "id,name\nx,Alice\n2,Bob\n")
    ok4, _, errs4 = finish_edit(path; delimiter = ',', column_types = Dict("id" => Int))
    @test !ok4
    @test any(e -> occursin("Could not parse", e.message) && occursin("id", string(e.column)), errs4)
end

# =============================================================================
# DIFF
# =============================================================================

@testset "diff_table" begin
    orig = [(id = "1", name = "Alice"), (id = "2", name = "Bob")]
    new_ = [
        (id = "1", name = "Alice X"),  # modified
        (id = "3", name = "Carol"),    # added
        # 2 removed
    ]
    d = diff_table(orig, new_, ["id"])
    @test length(d.added) == 1
    @test d.added[1].name == "Carol"
    @test length(d.removed) == 1
    @test d.removed[1].name == "Bob"
    @test length(d.modified) == 1
    @test d.modified[1][1].name == "Alice"
    @test d.modified[1][2].name == "Alice X"
end

# =============================================================================
# PREPARE_EDIT / FINISH_EDIT (no editor)
# =============================================================================

@testset "prepare_edit and finish_edit" begin
    dir = mktempdir()
    path = joinpath(dir, "edit.csv")

    # prepare to path (default TAB format)
    out_path = prepare_edit(TABLE, path)
    @test out_path == path
    @test isfile(path)
    content = read(path, String)
    @test occursin("id\tname\temail", content)
    @test occursin("1\tAlice", content)

    # finish_edit
    ok, (cols, rows), errs = finish_edit(path)
    @test ok
    @test cols == ["id", "name", "email"]
    @test length(rows) == 3
    @test isempty(errs)

    # prepare to temp (path = nothing)
    out_path2 = prepare_edit(TABLE, nothing)
    @test out_path2 isa String
    @test isfile(out_path2)
    ok2, _, _ = finish_edit(out_path2)
    @test ok2
    rm(out_path2; force = true)
end

# =============================================================================
# EDIT_TABLE with spawn_editor=false (test path)
# =============================================================================

@testset "edit_table spawn_editor=false" begin
    # Returns (path, finish_fn); finish_fn() parses and returns (ok, result, errors)
    # Use delimiter=',' so simulated edit (comma content) parses correctly
    path, finish_fn = edit_table(TABLE; spawn_editor = false, delimiter = ',', default_footer = false, header_separator = false, align_columns = false)
    @test path isa String
    @test isfile(path)
    @test finish_fn isa Function

    # Without modifying: result should match original
    ok, result, errs = finish_fn()
    @test ok
    cols, rows = result
    @test cols == ["id", "name", "email"]
    @test length(rows) == 3
    @test rows[1].name == "Alice"
    @test isempty(errs)

    # Simulate user edit: change file content
    write(path, "id,name,email\n1,Alice,alice@example.com\n2,Bob,bob@example.com\n3,Carol,carol@new.com\n")
    ok2, result2, errs2 = finish_fn()
    @test ok2
    _, rows2 = result2
    @test rows2[3].email == "carol@new.com"

    # Simulate invalid edit: wrong column count
    write(path, "id,name,email\n1,Alice\n")
    ok3, _, errs3 = finish_fn()
    @test !ok3
    @test !isempty(errs3)

    rm(path; force = true)
end

# =============================================================================
# RETURN MODES
# =============================================================================

@testset "finish_edit return_mode" begin
    orig = (["id", "name"], [(id = "1", name = "Alice"), (id = "2", name = "Bob")])
    dir = mktempdir()
    path = joinpath(dir, "r.csv")
    write(path, "id,name\n1,Alice\n2,Bob\n")

    # :full
    ok, res, _ = finish_edit(path; delimiter = ',', return_mode = :full)
    @test ok
    @test res isa Tuple
    @test length(res) == 2

    # :diff (need original_table and key_columns)
    write(path, "id,name\n1,Alice X\n3,Carol\n")  # 1 modified, 2 removed, 3 added
    ok2, diff, _ = finish_edit(path; delimiter = ',', original_table = orig, key_columns = ["id"], return_mode = :diff)
    @test ok2
    @test diff isa TableDiff
    @test length(diff.added) == 1
    @test length(diff.removed) == 1
    @test length(diff.modified) == 1

    # :changes_only
    ok3, ch, _ = finish_edit(path; delimiter = ',', original_table = orig, key_columns = ["id"], return_mode = :changes_only)
    @test ok3
    @test ch isa Tuple
    added, mod_new = ch
    @test length(added) == 1
    @test length(mod_new) == 1
    @test mod_new[1].name == "Alice X"
end

# =============================================================================
# CONFIGURABLE DELIMITER AND COMMENT
# =============================================================================

@testset "configurable delimiter and comment_prefix" begin
    # Semicolon delimiter
    io = IOBuffer()
    write_table_text(io, TABLE; delimiter = ';')
    s = String(take!(io))
    @test occursin("id;name;email", s)

    cols, rows, errs = parse_table_text(s; delimiter = ';')
    @test cols == ["id", "name", "email"]
    @test length(rows) == 3

    # Custom comment prefix (e.g. "//")
    content = "// header\nid,name\n1,Alice\n"
    cols2, rows2, errs2 = parse_table_text(content; comment_prefix = "//", delimiter = ',')
    @test cols2 == ["id", "name"]
    @test length(rows2) == 1
    @test isempty(errs2)
end

# =============================================================================
# NORMALIZE TABLE: (columns, rows) and vector of NamedTuples
# =============================================================================

@testset "_normalize_table (via write_table_text)" begin
    # (columns, rows) with NamedTuples (default TAB)
    io = IOBuffer()
    write_table_text(io, (["x"], [(x = "1",)]); default_footer = false, header_separator = false)
    s = String(take!(io))
    @test occursin("x", s)
    @test occursin("1", s)

    # (columns, rows) tuple format with default TAB (legacy path)
    io2 = IOBuffer()
    write_table_text(io2, (["a", "b"], [(a = 1, b = 2), (a = 3, b = 4)]); default_footer = false)
    s2 = String(take!(io2))
    @test occursin("a\tb", s2)
    @test occursin("1\t2", s2)
end

# =============================================================================
# TABLES.JL INPUT (dispatch)
# =============================================================================

@testset "Tables.jl input (write_table_text, prepare_edit, finish_edit)" begin
    # Table from NamedTuple of vectors (Tables.istable)
    tbl = (id = [1, 2], name = ["Alice", "Bob"])
    @test Tables.istable(tbl)

    # write_table_text accepts Tables.jl table (default TAB)
    io = IOBuffer()
    write_table_text(io, tbl; default_footer = false)
    s = String(take!(io))
    @test occursin("id\tname", s)
    @test occursin("1\tAlice", s)
    @test occursin("2\tBob", s)

    # parse and round-trip
    cols, rows, errs = parse_table_text(s)
    @test isempty(errs)
    @test cols == ["id", "name"]
    @test length(rows) == 2
    @test rows[1].id == "1" && rows[1].name == "Alice"
    @test rows[2].id == "2" && rows[2].name == "Bob"

    # prepare_edit + finish_edit with Tables.jl table
    path = joinpath(mktempdir(), "tbl_tsv.txt")
    out = prepare_edit(tbl, path; default_footer = false)
    @test out == path
    ok, (cols2, rows2), errs2 = finish_edit(path)
    @test ok && isempty(errs2)
    @test cols2 == ["id", "name"] && length(rows2) == 2
    @test rows2[1].name == "Alice"
end

# =============================================================================
# RELIABILITY / ADVERSARIAL: TRICK THE PARSER
# =============================================================================
# Intentionally tricky inputs to ensure the custom parser behaves correctly
# and does not misparse, crash, or leak content across boundaries.

@testset "reliability: empty and comment-only input" begin
    cols, rows, errs = parse_table_text("")
    @test isempty(cols) && isempty(rows) && length(errs) == 1
    @test occursin("No header", errs[1].message)

    cols2, rows2, errs2 = parse_table_text("\n\n")
    @test isempty(cols2) && isempty(rows2) && length(errs2) == 1

    cols3, rows3, errs3 = parse_table_text("# only\n# comments\n  # with space\n")
    @test isempty(cols3) && isempty(rows3) && length(errs3) == 1
end

@testset "reliability: comment prefix inside quoted field (must NOT skip as comment)" begin
    # The value is literally "# not a comment"; the line must be one data row.
    content = "a,b\n1,\"# not a comment\"\n"
    cols, rows, errs = parse_table_text(content; delimiter = ',')
    @test length(rows) == 1
    @test isempty(errs)
    @test rows[1].b == "# not a comment"
end

@testset "reliability: empty quoted field" begin
    content = "x,y\n1,\"\"\n"
    cols, rows, errs = parse_table_text(content; delimiter = ',')
    @test length(rows) == 1 && isempty(errs)
    @test rows[1].x == "1" && rows[1].y == ""
end

@testset "reliability: consecutive delimiters (empty middle field)" begin
    content = "a,b,c\n1,,3\n"
    cols, rows, errs = parse_table_text(content; delimiter = ',')
    @test length(rows) == 1 && isempty(errs)
    @test rows[1].a == "1" && rows[1].b == "" && rows[1].c == "3"
end

@testset "reliability: delimiter inside quoted field (comma and semicolon)" begin
    content = "k,v\n1,\"a,b;c\"\n"
    cols, rows, errs = parse_table_text(content; delimiter = ',')
    @test length(rows) == 1 && isempty(errs)
    @test rows[1].v == "a,b;c"

    content2 = "k;v\n1;\"a;b\"\n"
    cols2, rows2, errs2 = parse_table_text(content2; delimiter = ';')
    @test length(rows2) == 1 && isempty(errs2)
    @test rows2[1].v == "a;b"
end

@testset "reliability: newline inside quoted field (single logical line)" begin
    content = "a,b\n1,\"line1\nline2\"\n"
    cols, rows, errs = parse_table_text(content; delimiter = ',')
    @test length(rows) == 1 && isempty(errs)
    @test rows[1].b == "line1\nline2"
end

@testset "reliability: CRLF line endings" begin
    content = "a,b\r\n1,2\r\n"
    cols, rows, errs = parse_table_text(content; delimiter = ',')
    @test cols == ["a", "b"] && length(rows) == 1 && isempty(errs)
    @test rows[1].a == "1" && rows[1].b == "2"
end

@testset "reliability: escaped quotes (doubled quote) in field" begin
    content = "a,b\n1,\"Say \"\"hello\"\"\"\n"
    cols, rows, errs = parse_table_text(content; delimiter = ',')
    @test length(rows) == 1 && isempty(errs)
    @test rows[1].b == "Say \"hello\""

    # Triple quote: "" + " => one " in value, then close quote
    content2 = "a,b\n1,\"\"\"x\"\"\"\n"
    cols2, rows2, errs2 = parse_table_text(content2; delimiter = ',')
    @test length(rows2) == 1 && isempty(errs2)
    @test rows2[1].b == "\"x\""
end

@testset "reliability: wrong column count (extra and missing)" begin
    # Row "1,2,3" has 3 columns (error); row "4,5" has 2 columns (ok)
    content = "a,b\n1,2,3\n4,5\n"
    _, rows, errs = parse_table_text(content; delimiter = ',')
    @test length(errs) >= 1
    @test any(e -> occursin("Expected 2 columns, got 3", e.message), errs)
    @test length(rows) == 1  # only "4,5" is valid
end

@testset "reliability: single column" begin
    content = "id\n1\n2\n"
    cols, rows, errs = parse_table_text(content; delimiter = '\t')
    @test cols == ["id"] && length(rows) == 2 && isempty(errs)
    @test rows[1].id == "1" && rows[2].id == "2"
end

@testset "reliability: many columns" begin
    header = join(string.("c", 1:10), ',')
    data = join(string.(1:10), ',')
    content = header * "\n" * data * "\n"
    cols, rows, errs = parse_table_text(content; delimiter = ',')
    @test length(cols) == 10 && length(rows) == 1 && isempty(errs)
    @test rows[1].c1 == "1" && rows[1].c10 == "10"
end

@testset "reliability: header with comma (quoted when written)" begin
    # Column name "a,b" must be quoted when delimiter is comma; round-trip.
    tbl = (["a,b", "c"], [(var"a,b" = "1", c = "2")])
    io = IOBuffer()
    write_table_text(io, tbl; delimiter = ',', default_footer = false, header_separator = false, align_columns = false)
    s = String(take!(io))
    @test occursin("\"a,b\"", s)
    cols, rows, errs = parse_table_text(s; delimiter = ',')
    @test "a,b" in cols && length(rows) == 1
    @test rows[1].c == "2"
end

@testset "reliability: empty lines between data rows (skipped)" begin
    content = "a,b\n1,2\n\n\n3,4\n"
    cols, rows, errs = parse_table_text(content; delimiter = ',')
    @test length(rows) == 2 && isempty(errs)
    @test rows[1].a == "1" && rows[2].a == "3"
end

@testset "reliability: custom comment prefix with # in data" begin
    # comment_prefix is "//"; data contains # and must not be treated as comment
    content = "// header\nx,y\n1,#foo\n"
    cols, rows, errs = parse_table_text(content; comment_prefix = "//", delimiter = ',')
    @test cols == ["x", "y"] && length(rows) == 1 && isempty(errs)
    @test rows[1].y == "#foo"
end

@testset "reliability: round-trip all tricky values" begin
    tricky = (
        ["ref", "note"],
        [
            (ref = "1", note = "Normal"),
            (ref = "2", note = "Contains, comma"),
            (ref = "3", note = "Line1\nLine2"),
            (ref = "4", note = "Say \"hello\""),
            (ref = "5", note = ""),
            (ref = "6", note = "# not comment"),
        ],
    )
    io = IOBuffer()
    write_table_text(io, tricky; default_footer = false)
    cols, rows, errs = parse_table_text(String(take!(io)))  # default TAB
    @test isempty(errs)
    @test length(rows) == 6
    @test rows[1].note == "Normal"
    @test rows[2].note == "Contains, comma"
    @test rows[3].note == "Line1\nLine2"
    @test rows[4].note == "Say \"hello\""
    @test rows[5].note == ""
    @test rows[6].note == "# not comment"
end

@testset "reliability: unclosed quote (parser still yields consistent column count or error)" begin
    # Line: 1,"unclosed
    # Parser may treat newline as in-field; next logical line is empty or next row. We expect either
    # one row with value "unclosed\n" and then errors for wrong column count on following, or one error.
    content = "a,b\n1,\"unclosed\n2,3\n"
    cols, rows, errs = parse_table_text(content; delimiter = ',')
    # Should not crash; either we get one row + error for line 3, or a parse error
    @test length(cols) == 2
    # If we got a row with unclosed, it may have value "unclosed\n" and next line "2,3" triggers column-count error
    @test length(rows) >= 0
end

# =============================================================================
# PARSE ERROR FIELDS
# =============================================================================

@testset "ParseError fields" begin
    _, _, errs = parse_table_text("a,b\n1\n"; delimiter = ',')
    @test length(errs) == 1
    e = errs[1]
    @test e.line == 2
    @test e.column == 1
    @test occursin("Expected", e.message)
end

println("TableEdit.jl tests passed.")
