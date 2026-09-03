#!/usr/bin/env bash
#
# Golden-file tests for the go-cell filter.
#
# A case is a directory under tests/cases/ holding `input.qmd`. Rendering it
# produces one capture — exit code, cache state, stdout, stderr — which is
# compared against `expected.txt`.
#
# Besides pandoc, go and goimports, the full suite needs a C compiler (the
# `race` case) and the go.uber.org/goleak module in the module cache or network
# access to fetch it (the `require-external` case).
#
# The filter only touches `quarto.*` inside pcall, so plain pandoc is enough —
# no quarto install needed to run these.
#
#   tests/run.sh                  all cases
#   tests/run.sh noshow test-     only cases whose name contains a pattern
#   tests/run.sh --update         rewrite expected.txt from the actual capture
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
FILTER="$HERE/../_extensions/go-cell/go-cell.lua"

update=0 patterns=()
for arg in "$@"; do
	case "$arg" in
	--update) update=1 ;;
	-*)
		sed -n '3,19p' "$0" | sed 's/^# \{0,1\}//'
		exit 2
		;;
	*) patterns+=("$arg") ;;
	esac
done

pass=0 fail=0 failed=()

for dir in "$HERE"/cases/*/; do
	dir=${dir%/}
	name=${dir##*/}

	if [[ ${#patterns[@]} -gt 0 ]]; then
		hit=0
		for p in "${patterns[@]}"; do [[ "$name" == *"$p"* ]] && hit=1; done
		[[ $hit == 1 ]] || continue
	fi
	work=$(mktemp -d)
	mkdir -p "$work/project"
	QUARTO_PROJECT_DIR="$work/project" pandoc \
		--from=markdown --to=native \
		--lua-filter="$FILTER" "$dir/input.qmd" >"$work/out" 2>"$work/err"
	rc=$?

	# Cache state stands in for what a golden cannot show: that run_go wrote one
	# entry per distinct block and removed its scratch directory again.
	cache="$work/project/.quarto/go-cache"
	{
		printf -- '--- exit %d\n' "$rc"
		printf -- '--- cache %d result(s), %d leftover dir(s)\n' \
			"$(find "$cache" -maxdepth 1 -name '*.txt' 2>/dev/null | wc -l)" \
			"$(find "$cache" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)"
		printf -- '--- stdout\n'
		cat "$work/out"
		printf -- '--- stderr\n'
		cat "$work/err"
	} | sed -E \
		-e 's/[0-9]+\.[0-9]+s/0.000s/g' \
		-e 's/0x[0-9a-f]+/0xADDR/g' \
		-e "s#$work#TMP#g" \
		-e "s#$HERE#TESTS#g" >"$work/actual"

	[[ $update == 1 ]] && cp "$work/actual" "$dir/expected.txt"

	if diff -u "$dir/expected.txt" "$work/actual" >"$work/diff" 2>&1; then
		printf 'PASS %s\n' "$name"
		pass=$((pass + 1))
	else
		printf 'FAIL %s\n' "$name"
		sed 's/^/     /' "$work/diff"
		fail=$((fail + 1))
		failed+=("$name")
	fi
	rm -rf "$work"
done

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ $fail == 0 ]] || {
	printf 'failed: %s\n' "${failed[*]}"
	exit 1
}
