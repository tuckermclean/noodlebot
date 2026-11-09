# tallyho

A tiny command-line tool that counts words, lines and bytes in text files and prints a tidy table.

## Usage

    bin/tallyho FILE...

Prints one row per file and a total row. Reads standard input when no file is given.

## Planned

- `--json` output for scripts.
- `--top N`: show the N most frequent words.
- Skip binary files instead of counting their bytes as text.
- Configuration file `~/.tallyhorc` for default flags.

## Development

    make test
