# wrapit

wrapit folds lines of text to a width: `bin/wrap [-w N] [file]` reads a file or standard input and prints
each line broken at spaces so that no line is longer than N characters (default 20).

Run the tests with `make test`.

Known gap: a word longer than the width is not split (see `tests/t_narrow.sh`).
