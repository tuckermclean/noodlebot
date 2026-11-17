# A word longer than the width is split to the width (not done yet: this test fails).
out=$(echo "abcdefghij" | sh bin/wrap -w 4 | head -n 1)
[ "$out" = "abcd" ]
