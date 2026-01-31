#!/usr/bin/env julia
# Interactive demo script for VHS recording
# This sets up the table and waits for nano to edit it

using TableEdit

println("Starting TableEdit.jl demo...")
println()

# Create a sample table
println("Creating sample table:")
table = (id=[1,2,3], name=["Alice","Bob","Carol"], score=[85,92,78])
println(table)
println()

# Edit the table with nano
println("Opening table in nano for editing...")
println("  - Change Alice's score from 85 to 90")
println("  - Delete Carol's row")
println("  - Add a new row: 4, Dave, 88")
println()

ok, result, errors = edit_table(table; spawn_editor=true)

println()
if ok
    cols, rows = result
    println("✓ Edit successful!")
    println()
    println("Results:")
    for (i, row) in enumerate(rows)
        println("  Row $i: id=$(row.id), name=$(row.name), score=$(row.score)")
    end
else
    println("✗ Edit failed:")
    for err in errors
        println("  - ", err.message)
    end
end
