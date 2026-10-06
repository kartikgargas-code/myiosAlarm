import io

p = r"D:\myiosAlarm\AlarmClock\SoundPickerView.swift"
text = io.open(p, encoding="utf-8").read()
lines = text.split("\n")

# Locate the Random section (1-based 159..182 -> 0-based 158..181)
start = next(i for i, l in enumerate(lines) if 'Section("Random from Playlist")' in l)
# find its closing brace: scan for the line that is exactly '                }' after start
end = start
brace_depth = 0
for i in range(start, len(lines)):
    brace_depth += lines[i].count("{") - lines[i].count("}")
    if i > start and brace_depth == 0:
        end = i  # first line after section closes where depth returns to 0 at section level
        break

block = lines[start:end + 1]
# remove block and the blank line right above it
del lines[start - 1:end + 1]

# find the Default section now; insert after the blank line above it
dflt = next(i for i, l in enumerate(lines) if 'Section("Default")' in l)
insert_at = dflt  # insert BEFORE the blank line above Default -> place block + blank
lines[insert_at:insert_at] = block + [""]

out = "\n".join(lines)
assert out.count('{') == out.count('}')
io.open(p, "w", encoding="utf-8", newline="\n").write(out)
print("moved ok; section count:", out.count('Section("'))
