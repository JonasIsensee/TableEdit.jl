# VHS script for TableEdit.jl demo
# Generate with: vhs demo.tape

Output demo.gif

Set FontSize 18
Set Width 1600
Set Height 1000
Set Theme "Dracula"
Set TypingSpeed 80ms

Type "EDITOR=nano julia --project demo_interactive.jl"
Enter
Sleep 6s

# Now in nano. File shows:
# Line 1: idnamescore
# Line 2: -----------
# Line 3: 1Alice85
# Line 4: 2Bob  92
# Line 5: 3Carol78

# Navigate to Alice's row (line 3)
Down 2
Sleep 300ms

# Go to end of line and edit score
Ctrl+E
Sleep 300ms
Backspace 2
Type "90"
Sleep 1500ms

# Navigate to Carol's row (line 5)
Down 2
Sleep 300ms

# Delete Carol's entire row
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

# Save and exit
Ctrl+X
Sleep 500ms
Type "y"
Sleep 500ms
Enter
Sleep 5s
