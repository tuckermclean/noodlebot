# wrap_line <width>: fold standard input at spaces.
wrap_line() {
	awk -v w="$1" '{
		out = ""
		for (i = 1; i <= NF; i++) {
			if (out == "") out = $i
			else if (length(out) + 1 + length($i) <= w) out = out " " $i
			else { print out; out = $i }
		}
		print out
	}'
}
