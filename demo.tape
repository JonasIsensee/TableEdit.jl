# VHS script for TableEdit.jl demo - shows actual REPL workflow

Output demo.gif

Set FontSize 18
Set Width 900
Set Height 600
Set Theme "Dracula"
Set TypingSpeed 40ms

# Start Julia REPL
Type "julia --project"
Enter
Sleep 1s

# Load TableEdit
Type "using TableEdit"
Enter
Sleep 1s

# Create a sample table
Type 'table = (id=[1,2,3], name=["Alice","Bob","Carol"], score=[85,92,78])'
Enter
Sleep 1s

# Call edit_table - this will open nano
Type "ok, result, errors = edit_table(table)"
Enter
Sleep 3s

# Now in nano editing the table
# Navigate to Alice's score and change 85 -> 90
Down 2
Sleep 300ms
Ctrl+E
Sleep 300ms
Backspace 2
Type "90"
Sleep 1500ms

# Delete Carol's row
Down 2
Sleep 300ms
Ctrl+K
Sleep 1500ms

# Add new row for Dave
Down 3
Type "4"
Tab
Type "Dave  "
Tab
Type "88"
Sleep 1500ms

# Save and exit nano
Ctrl+X
Sleep 500ms
Type "y"
Sleep 500ms
Enter
Sleep 2s

# Back in REPL - show results
Type "ok"
Enter
Sleep 1s

Type "rows = result[2]"
Enter
Sleep 3s
