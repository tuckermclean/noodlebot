# A long line is folded at a space.
out=$(echo "one two three four five six" | sh bin/wrap -w 10 | head -n 1)
[ "$out" = "one two" ]
