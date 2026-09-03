# Go Cells

> **Disclaimer:** built with AI.

Pandoc/Quarto filter for showing Go code with its output, in a flexible way. The
code is compiled and run while the document renders, so the output on the slide
is real — if the code stops compiling, the render stops too.

> **Disclaimer:** built for my own presentations. Fit for that, not promised to
> fit anything else.

Needs `go` and `goimports` on the `PATH`.

## Usage

Mark a block `.go` and `.run`, then either add `.output` to put the output right
after the code:

````markdown
```{.go .run .output}
package main

import "fmt"

func main() {
	fmt.Println("hello")
}
```
````

or place a `.go-output` div wherever the output should appear — on the next
slide, say. Without an `output-id` it shows the last `.run` block's output:

````markdown
```{.go .run output-id="demo"}
...
```

::: {.go-output output-id="demo"}
:::
````

## Options

| class             | effect                                                |
|-------------------|-------------------------------------------------------|
| `.run`            | compile and run; a non-zero exit aborts the render    |
| `.output`         | append the output directly after the code             |
| `.test`           | run with `go test` instead of `go run`                |
| `.race`           | add `-race`; needs cgo and a C compiler               |
| `.expect-failure` | invert the check: the block *must* fail               |
| `.show-cli`       | on `.test`, prefix the output with the `go test` line |
| `.hide-cli`       | with `args=`, suppress the `> go run .` line          |

| attribute    | effect                                                                                                                        |
|--------------|-------------------------------------------------------------------------------------------------------------------------------|
| `template=`  | `full` (default, the block is the whole file), `main`, `mainfunc`, `test` — all but `full` get their imports from `goimports` |
| `args=`      | arguments for the program: `go run . <args>`                                                                                  |
| `go-get=`    | arguments for a `go get` after `go mod tidy`, to pin a version or add a module the code does not import                      |
| `module=`    | module path of the generated `go.mod`. Default `example.com/main`                                                             |
| `filename=`  | `.test` only: name of the generated `*_test.go`                                                                               |
| `test-args=` | flags for `go test`, e.g. `-v`                                                                                                |
| `output-id=` | name this output for a `.go-output` div                                                                                       |

Dependencies need no declaration — `go mod tidy` resolves whatever the block
imports. Use `go-get=` when the version matters.

Lines between `// <noshow>` and `// </noshow>` are compiled but not shown. Line
numbers in errors are mapped back onto the visible code.

## Testing

A test case is a directory under `tests/cases/` holding an `input.qmd`. It is
rendered with plain pandoc — the filter needs no Quarto — and everything the run
produced (exit code, cache state, stdout, stderr) is compared against the case's
`expected.txt`.

```sh
tests/run.sh              # all cases
tests/run.sh noshow       # only cases matching a pattern
tests/run.sh --update     # rewrite expected.txt from the actual output
```

`--update` records whatever the filter does today, right or wrong, so read the
diff before committing it. More detail in `tests/README.md`.
