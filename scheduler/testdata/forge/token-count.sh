#!/bin/sh
# A counting fake of the token script: each run appends its arguments as one line to $TOKEN_COUNT_FILE and prints
# $TOKEN_VALUE (default ghs_G04distinctive0token). TOKEN_FAIL=1 makes it fail, TOKEN_EMPTY=1 print nothing.
echo "$*" >>"${TOKEN_COUNT_FILE:?}"
[ -z "${TOKEN_FAIL:-}" ] || { echo "token script: boom" >&2; exit 1; }
[ -z "${TOKEN_EMPTY:-}" ] || exit 0
echo "${TOKEN_VALUE:-ghs_G04distinctive0token}"
