# count_stream FILE: print "lines words bytes name" for FILE ("-" is stdin).
count_stream() {
	if [ "$1" = "-" ]; then
		wc -lwc | awk '{printf "%7d %7d %7d %s\n", $1, $2, $3, "-"}'
	else
		wc -lwc <"$1" | awk -v n="$1" '{printf "%7d %7d %7d %s\n", $1, $2, $3, n}'
	fi
}
