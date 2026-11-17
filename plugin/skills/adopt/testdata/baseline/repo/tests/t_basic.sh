# A short line is printed unchanged.
out=$(echo "hello world" | sh bin/wrap)
[ "$out" = "hello world" ]
