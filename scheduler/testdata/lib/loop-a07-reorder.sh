# Shared by loop-a07-reorder.test.sh (source after loop-a07.sh): a graph whose areas are reordered.
#   a07o_reorder <name>   commit a graph on the fake forge's main with the same areas as kind "two", in the order two, one
a07o_reorder() {
	local fk=$G04/fk/$1 w=$A07/w.$1
	rm -rf "$w"; git clone -q "$fk/repo.git" "$w" 2>/dev/null
	mkdir -p "$w/docs"
	a07_graph two | awk '/name: one/ { held = $0; next } { print } /name: two/ { print held }' >"$w/docs/graph.yaml"
	git -C "$w" add -A
	git -C "$w" -c user.name=t -c user.email=t@t commit -q -m "graph reordered"
	git -C "$w" push -q origin HEAD:main
	rm -rf "$w"
}
