# VHS script for TableEdit.jl demo - shows actual REPL workflow

Output demo.gif

Set FontSize 18
Set Width 900
Set Height 600
Set Theme "Dracula"
Set TypingSpeed 20ms

# Start Julia REPL - type fast
Type "julia --project"
Enter
Sleep 3s

# Load TableEdit - type fast
Type "using TableEdit"
Enter
Sleep 1s

# Create a sample table - type fast
Type 'table = (id=[1,2,3], name=["Alice","Bob","Carol"], score=[85,92,78])'
Enter
Sleep 1s

# Call edit_table - type fast
Type "ok, result, errors = edit_table(table)"
Enter
Sleep 3s

# Now in nano editing the table - SLOW DOWN
Set TypingSpeed 150ms

# Navigate to Alice's score and change 85 -> 90
Down 2
Sleep 800ms
Ctrl+E
Sleep 500ms
Backspace 2
Sleep 300ms
Type "90"
Sleep 2s

# Delete Carol's row
Down 2
Sleep 800ms
Ctrl+K
Sleep 2s

# Add new row for Dave RIGHT HERE (where Carol was)
Type "4"
Sleep 300ms
Tab
Sleep 300ms
Type "Dave  "
Sleep 300ms
Tab
Sleep 300ms
Type "88"
Sleep 2s

# Save and exit nano - back to fast
Set TypingSpeed 20ms
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
