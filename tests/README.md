# Tests

The filter is a plain pandoc Lua filter — everything it uses from the `quarto`
global sits behind a `pcall`. So the tests run it with **pandoc alone**; no
quarto install needed. What they do need is `pandoc`, `go` and `goimports`,
plus a C compiler for the `race` case (the race detector is ThreadSanitizer)
and network access the first time, for the cases that pull `go.uber.org/goleak`
in (`require-external`, `require-external-run`, `go-get-unimported`) — after
that it comes from the module cache.

```sh
tests/run.sh                # every case
tests/run.sh noshow test-   # only cases whose name contains a pattern
tests/run.sh --update       # rewrite expected.txt from the actual capture
```

## How a case works

A case is a directory under `cases/` holding `input.qmd`. It is rendered with

```sh
pandoc --from=markdown --to=native --lua-filter=… input.qmd
```

in a throwaway `QUARTO_PROJECT_DIR`, so every case starts from an empty
`.quarto/go-cache`. Everything the run produced — exit code, cache state,
stdout, stderr — becomes one capture, normalised (`go test` durations, pointer
values, absolute paths) and compared against `expected.txt`. That is the only
assertion mechanism; there is nothing else to learn.

The output is pandoc's `native` AST, not markdown, so a golden pins the exact
`Attr` — identifier, classes, attributes — of every block. Markdown would hide
that: a `::: {.go-output}` div and the `CodeBlock` the filter replaces it with
both come out as a fence. Because the AST is verbose, the prose explaining each
case is written as an HTML comment (one `RawBlock`) rather than a paragraph,
which would explode into one node per word.

The `--- cache N result(s), M leftover dir(s)` line covers what stdout cannot
show: that `run_go` wrote one entry per distinct block, and removed its scratch
directory again afterwards.

## Adding a case

Write `input.qmd`, run `tests/run.sh --update <name>`, then **read the
generated `expected.txt`** — `--update` records whatever the filter does today,
right or wrong. It will just as happily record a case that no longer tests what
it was written for. Since the capture is exact, goldens also encode the current
Go version's compiler wording; a Go upgrade may need a reviewed `--update`.
