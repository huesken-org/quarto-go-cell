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
| `.vet`            | run `go vet` instead of `go run`, findings are output |
| `.race`           | add `-race`; needs cgo and a C compiler               |
| `.expect-failure` | invert the check: the block *must* fail               |
| `.show-cli`       | on `.test`/`.vet`, prefix the output with the command |
| `.hide-cli`       | with `args=`, suppress the `> go run .` line          |
| `.go-generate`    | run `go generate ./...` before the block runs         |

| attribute    | effect                                                                                                                        |
|--------------|-------------------------------------------------------------------------------------------------------------------------------|
| `template=`  | `full` (default, the block is the whole file), `main`, `mainfunc`, `test` — all but `full` get their imports from `goimports` |
| `args=`      | arguments for the program: `go run . <args>`                                                                                  |
| `go-get=`    | arguments for a `go get` after `go mod tidy`, to pin a version or add a module the code does not import                      |
| `module=`    | module path of the generated `go.mod`. Default `example.com/main`                                                             |
| `filename=`  | `.test`: name of the generated `*_test.go`; `.vet`: name of the vetted `*.go`                                                 |
| `test-args=` | flags for `go test`, e.g. `-v`                                                                                                |
| `vet-args=`  | flags for `go vet`, e.g. `-printf=false`                                                                                      |
| `output-id=` | name this output for a `.go-output` div                                                                                       |

A `.vet` block need not be `package main`. Any finding makes `go vet` exit
non-zero, so a block that shows findings carries `.expect-failure`. `go vet`
prints its findings in random order; the filter sorts them by position. To vet
a test file, give it a test file name — `.vet` does not combine with `.test` or
`.race`:

````markdown
```{.go .run .vet .output .expect-failure module="example.com/counter" filename="counter.go"}
package counter
...
```
````

Dependencies need no declaration — `go mod tidy` resolves whatever the block
imports. Use `go-get=` when the version matters.

`.go-generate` runs `go generate ./...` after `go mod tidy` and `go-get=`, so a
`//go:generate` line in the block can produce code the block needs — a gomock
mock, say. The tool comes in through `go-get="-tool …"`, and `mockgen` can read
the interface straight from the block's own file (`-source=` names it as
`filename=` does). The generated files are compiled, never shown:

````markdown
```{.go .run .test .output .go-generate module="example.com/rocket" filename="rocket_test.go" go-get="-tool go.uber.org/mock/mockgen@v0.6.0"}
package rocket

import (
	"testing"

	"go.uber.org/mock/gomock"
)

type Radio interface{ Send(msg string) error }

//go:generate go tool mockgen -source=rocket_test.go -destination=mock_test.go -package=rocket

func TestSend(t *testing.T) {
	radio := NewMockRadio(gomock.NewController(t))
	radio.EXPECT().Send("T-0").Return(nil)
	radio.Send("T-0")
}
```
````

Lines between `// <noshow>` and `// </noshow>` are compiled but not shown. Line
numbers in errors are mapped back onto the visible code.

A line `// exit: <name>` is never shown either. A `.go-output` div with
`exit="<name>"` shows the output of a run that ends with `os.Exit(0)` at that
marker — the lines after it stay in and are compiled, just not executed. Every
other output of the block runs the whole program:

````markdown
```{.go .run .output}
...
	fmt.Println("one")
	// exit: first
	fmt.Println("two")
...
```

::: {.go-output exit="first"}
:::
````

The exit run has to succeed; put `.expect-failure` on the div if it should
fail. It does not work on `.test` blocks.

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
