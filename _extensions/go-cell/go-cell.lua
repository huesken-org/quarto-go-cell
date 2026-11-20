local outputs = {}
local output_classes = {}
-- Anchor the cache in the project root (not the per-file working dir), so caches
-- don't get scattered next to every source file.
local project_dir = os.getenv("QUARTO_PROJECT_DIR")
local CACHE_DIR = (project_dir and project_dir .. "/" or "") .. ".quarto/go-cache"

local DEFAULT_MODULE = "example.com/main"

-- Shell-quote a string for safe interpolation into a command.
local function shq(s)
	return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

-- Escape Lua pattern magic characters, so we can use things like module paths
-- in `gsub`/`match`.
local function lua_esc(s)
	return (s:gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1"))
end

-- Runs a command in `dir`, returning its combined output and exit code. The exit
-- code travels in a marker because `pipe:close()` reports it differently
-- depending on the Lua version.
local function run_in(dir, cmd)
	local pipe = io.popen("cd " .. shq(dir) .. " && " .. cmd .. " 2>&1; echo \"__GOCELL_EXIT:$?\"")
	local out = pipe:read("*all")
	pipe:close()
	local code = tonumber(out:match("__GOCELL_EXIT:(%d+)%s*$") or "") or 0
	return (out:gsub("__GOCELL_EXIT:%d+%s*$", "")), code
end

-- Go version to use for `go.mod`.
-- Cache it, assuming the Go version does not change while a document is compiled.
local go_minor = nil
local function go_mod_version()
	if go_minor == nil then
		local p = io.popen("go env GOVERSION 2>/dev/null")
		local v = p and p:read("*l") or nil
		if p then
			p:close()
		end
		go_minor = (v or ""):match("^go(%d+%.%d+)") or "1.21"
	end
	return go_minor
end

-- Configuration of a `{.go .run}` block. Every block gets a synthetic `go.mod`,
-- so these apply to `go run`, `go test` and `go vet` blocks alike.
--   module=    module path of the synthetic `go.mod`; its last segment becomes
--              the package name and so shows up in the `ok …` line
--   filename=  supplies (as a basename) the name of the source file, so the file
--              names in the output match the slide header. `.test` blocks: must
--              end in `_test.go` (`go test` finds tests only there). `.vet`
--              blocks: any `*.go`, so a test file can be vetted too. A `go run`
--              block is always `main.go`
--   test-args= flags for `go test` (not to be confused with `args`, which means
--              arguments passed to a program started by `go run`)
--   vet-args=  flags for `go vet`, e.g. `-printf=false`
--   go-get=    arguments for a `go get` run after `go mod tidy`, to pin a version
--              (`go.uber.org/goleak@v1.3.0`) or to add a module the code does not
--              import itself — `tidy` would drop that one again, which is why the
--              `go get` comes after it
--   .go-generate run `go generate ./...` after `tidy` and `go get`, so a
--              `//go:generate` line in the block (e.g. `mockgen`) produces the
--              files the build needs
local function block_config(el, is_test)
	local is_vet = el.classes:includes("vet")
	local module = el.attributes["module"]
	if module == nil or module == "" then
		module = DEFAULT_MODULE
	end
	local file = is_test and "main_test.go" or "main.go"
	local fn = el.attributes["filename"]
	if (is_test or is_vet) and fn ~= nil and fn ~= "" then
		local base = fn:match("([^/]+)$")
		local wanted = is_test and "_test%.go$" or "%.go$"
		if base ~= nil and base:match(wanted) then
			file = base
		end
	end
	return {
		module = module,
		pkg = module:match("([^/]+)$") or module,
		file = file,
		flags = el.attributes["test-args"] or "",
		vet_flags = el.attributes["vet-args"] or "",
		go_get = el.attributes["go-get"] or "",
		go_generate = el.classes:includes("go-generate"),
	}
end

-- Tidies up the output of `go run`, `go test` and `go vet`:
--   * drop the `# <module>` header lines in front of compiler/vet errors
--   * cut path prefixes off the source file (`./board_test.go` -> `board_test.go`)
-- Durations stay as `go test` reports them.
local function normalize_output(output, cfg)
	local esc_file = lua_esc(cfg.file)
	local out = {}
	for line in (output .. "\n"):gmatch("([^\n]*)\n") do
		local is_pkg_header = line:match("^# ") ~= nil and line:find(cfg.module, 1, true) ~= nil
		if not is_pkg_header then
			table.insert(out, (line:gsub("[^%s]*/" .. esc_file, cfg.file)))
		end
	end
	return table.concat(out, "\n")
end

-- `go vet` runs its analyzers in parallel and prints their findings in whatever
-- order they finish — a different one on every run. Sort them by position
-- (file, line, column), so the slide and the cache stay stable. Only when every
-- non-empty line is a `file:line:col: message` finding; anything else (a compile
-- error, say) is left as it is. The sort is stable for equal positions.
local function sort_findings(output)
	local items = {}
	for line in (output .. "\n"):gmatch("([^\n]*)\n") do
		if line ~= "" then
			local file, ln, col = line:match("^([^:%s]+):(%d+):(%d+): ")
			if file == nil then
				return output
			end
			table.insert(items, { line = line, file = file, ln = tonumber(ln), col = tonumber(col), i = #items })
		end
	end
	table.sort(items, function(a, b)
		if a.file ~= b.file then
			return a.file < b.file
		end
		if a.ln ~= b.ln then
			return a.ln < b.ln
		end
		if a.col ~= b.col then
			return a.col < b.col
		end
		return a.i < b.i
	end)
	local out = {}
	for _, it in ipairs(items) do
		table.insert(out, it.line)
	end
	if #out == 0 then
		return output
	end
	return table.concat(out, "\n") .. "\n"
end

-- `// exit: <name>` on a line of its own marks where a `.go-output exit="<name>"`
-- div cuts the program off. Returns the name, or nil.
local function exit_marker(line)
	return line:match("^%s*//%s*exit:%s*(%S+)%s*$")
end

-- The function an exit marker is replaced with. It lives in a file of its own
-- (`EXIT_FILE`), so the block's source needs no `os` import — adding one would
-- shift the line numbers of a `full` block.
local EXIT_FUNC = "_goCellExit"
local EXIT_FILE = "gocell_exit.go"

-- Replaces every `// exit: <name>` marker with a call to `EXIT_FUNC`, in place:
-- the line count stays, so line numbers need no extra mapping. Everything after
-- the marker stays too, so the code still compiles. Also returns whether a
-- marker was found.
local function insert_exit(code, name)
	local out = {}
	local found = false
	for line in (code .. "\n"):gmatch("([^\n]*)\n") do
		if exit_marker(line) == name then
			line = line:match("^(%s*)") .. EXIT_FUNC .. "()"
			found = true
		end
		table.insert(out, line)
	end
	return table.concat(out, "\n"), found
end

-- Splits the block content in a single pass into
--   1. the displayed code — everything outside `// <noshow>` … `// </noshow>`
--      and without `// exit: <name>` markers (all markers count as hidden)
--   2. the mapping "line number in the original -> line number in the displayed
--      code"; hidden lines have no entry
--   3. the number of hidden lines
-- `run_go` still compiles the full source and needs (2) to map line numbers from
-- the output back onto the visible code.
local function split_noshow(code)
	local out = {}
	local line_map = {}
	local hidden = 0
	local in_noshow = false
	local n = 0
	for line in (code .. "\n"):gmatch("([^\n]*)\n") do
		n = n + 1
		if not in_noshow and line:match("^%s*//%s*<noshow>%s*$") then
			in_noshow = true
			hidden = hidden + 1
		elseif in_noshow and line:match("^%s*//%s*</noshow>%s*$") then
			in_noshow = false
			hidden = hidden + 1
		elseif not in_noshow and exit_marker(line) then
			hidden = hidden + 1
		elseif not in_noshow then
			table.insert(out, line)
			line_map[n] = #out
		else
			hidden = hidden + 1
		end
	end
	return table.concat(out, "\n"), line_map, hidden
end

local function cli_prefix(output, el)
	-- Vet blocks, like test blocks: the invocation line only on request.
	if el.classes:includes("vet") then
		if not el.classes:includes("show-cli") then
			return output
		end
		local cfg = block_config(el, false)
		local cmd = "> go vet"
		if cfg.vet_flags ~= "" then
			cmd = cmd .. " " .. cfg.vet_flags
		end
		return cmd .. " ./" .. cfg.pkg .. "\n" .. output
	end
	-- Test blocks: show the invocation line only on request. Most slides already
	-- show the command in a `{.bash}` block of their own above it.
	if el.classes:includes("test") then
		if not el.classes:includes("show-cli") then
			return output
		end
		local cfg = block_config(el, true)
		local cmd = "> go test"
		if cfg.flags ~= "" then
			cmd = cmd .. " " .. cfg.flags
		end
		return cmd .. " ./" .. cfg.pkg .. "\n" .. output
	end
	local args = el.attributes["args"] or ""
	if args ~= "" and not el.classes:includes("hide-cli") then
		return "> go run . " .. args .. "\n" .. output
	end
	return output
end

-- Where are we? Best effort, only for the error message.
local function input_file()
	local ok, f = pcall(function()
		return quarto.doc.input_file
	end)
	if ok and f ~= nil and f ~= "" then
		return f
	end
	if PANDOC_STATE ~= nil and PANDOC_STATE.input_files ~= nil and #PANDOC_STATE.input_files > 0 then
		return PANDOC_STATE.input_files[1]
	end
	return "<unknown file>"
end

-- Aborts the render with a readable message.
local function fail(el, exit_code, output, reason, hint)
	local first_line = (el.text:match("^%s*([^\n]+)") or ""):match("^%s*(.-)%s*$")
	local lines = {}
	for line in (output .. "\n"):gmatch("([^\n]*)\n") do
		table.insert(lines, line)
	end
	io.stderr:write("\n")
	io.stderr:write("=== go-cell: " .. reason .. " ===\n")
	io.stderr:write("  File       : " .. input_file() .. "\n")
	io.stderr:write("  Code block : " .. first_line .. "\n")
	io.stderr:write("  Exit code  : " .. tostring(exit_code) .. "\n")
	io.stderr:write("  Output     :\n")
	for i = 1, math.min(#lines, 12) do
		if lines[i] ~= "" or i < #lines then
			io.stderr:write("    | " .. lines[i] .. "\n")
		end
	end
	if #lines > 12 then
		io.stderr:write("    | … (" .. (#lines - 12) .. " more lines)\n")
	end
	io.stderr:write("\n  " .. hint .. "\n\n")
	os.exit(1)
end

-- A warning that does not abort the render: a line number from the output points
-- into a `<noshow>` block and so has no counterpart in the visible code. The
-- number is then left unchanged — inventing some visible line would be worse than
-- a number that is recognisably foreign.
--
-- On `quarto.log.warning` instead of `io.stderr`: this filter runs `at: pre-ast`,
-- and from that pass Quarto does not hand stderr through to the console. `fail()`
-- only gets through because it ends the process with `os.exit`.
local function warn_hidden_line(el, file, line_num)
	local first_line = (el.text:match("^%s*([^\n]+)") or ""):match("^%s*(.-)%s*$")
	local msg = "go-cell: " .. file .. ":" .. line_num .. " points into a <noshow> block." ..
		" The number is left unchanged and therefore does not match the visible code.\n" ..
		"  File      : " .. input_file() .. "\n" ..
		"  Code block: " .. first_line
	local ok = pcall(function()
		quarto.log.warning(msg)
	end)
	if not ok then
		io.stderr:write("\n" .. msg .. "\n\n")
	end
end

-- Checks the exit code against what the block expects.
--   default               -> must end with 0
--   {.expect-failure}     -> must end with != 0
local function check_exit(el, exit_code, output)
	local expects_failure = el.classes:includes("expect-failure")
	if expects_failure and exit_code == 0 then
		fail(el, exit_code, output,
			"Block is marked .expect-failure but ran without errors",
			"Either the error has been fixed since — then remove `.expect-failure` —\n" ..
			"  or the example no longer demonstrates what it is meant to.")
	end
	if not expects_failure and exit_code ~= 0 then
		fail(el, exit_code, output,
			"Go code did not run without errors",
			"Is the failure intended (compile-error demo, panic example, quiz answer\n" ..
			"  \"compile error\")? Then mark the code block with `.expect-failure`:\n" ..
			"      ```{.go .run .expect-failure}\n" ..
			"  Otherwise it is a real error on the slide.")
	end
end

-- Is a command on the PATH? Check once, remember the result.
local cmd_present = {}
local function has_cmd(name)
	if cmd_present[name] == nil then
		cmd_present[name] = os.execute("command -v " .. name .. " >/dev/null 2>&1") and true or false
	end
	return cmd_present[name]
end

-- Environment for a `.race` block. The race detector is ThreadSanitizer, so C
-- code: without `CGO_ENABLED=1` Go aborts with "-race requires cgo".
--   * `GORACE=halt_on_error=1` — stop after the first report. Without it, 100
--     goroutines report the same race dozens of times and the slide overflows.
--   * `CC` — Go's default is "gcc". Where only `cc` exists (Nix profiles, BSDs),
--     the build would otherwise fail over a compiler that is in fact there.
local function race_env()
	local env = "CGO_ENABLED=1 GORACE=halt_on_error=1 "
	if not has_cmd("gcc") and has_cmd("cc") then
		env = env .. "CC=cc "
	end
	return env
end

-- `exit_name` (optional) runs the variant cut off at the `// exit: <name>`
-- markers, for a `.go-output exit="<name>"` div.
local function run_go(el, exit_name)
	local code = el.text
	-- `.test` runs the block with `go test` instead of `go run`.
	local is_test = el.classes:includes("test")
	-- `.race` switches the race detector on (`-race`, see `race_env`).
	local is_race = el.classes:includes("race")
	-- `.vet` runs `go vet` instead: the block need not be `package main`, and the
	-- findings are the output. Any finding makes `go vet` exit non-zero, so such
	-- a block carries `.expect-failure`.
	local is_vet = el.classes:includes("vet")
	local cfg = block_config(el, is_test)

	-- Checked before anything touches the disk, so no cleanup is needed.
	if is_vet and (is_test or is_race) then
		fail(el, 0, "",
			"`.vet` cannot be combined with `." .. (is_test and "test" or "race") .. "`",
			"A `.vet` block runs `go vet` and nothing else. To vet a test file, give it a\n" ..
			"  test file name instead:\n" ..
			"      ```{.go .run .vet filename=\"board_test.go\"}")
	end
	-- Without a directive `go generate` silently does nothing, and the build would
	-- fail later over whatever was meant to be generated.
	if cfg.go_generate and not code:match("//go:generate ") then
		fail(el, 0, "",
			"`.go-generate` without a `//go:generate` line",
			"`.go-generate` runs `go generate ./...`, which only acts on directives in\n" ..
			"  the block. Add one (it may sit inside `// <noshow>`):\n" ..
			"      //go:generate go tool mockgen -source=main_test.go -destination=mock_test.go -package=main")
	end
	if is_vet and exit_name ~= nil then
		fail(el, 0, "",
			"exit=\"" .. exit_name .. "\" does not work with `.vet` blocks",
			"`go vet` does not run the program, so there is nothing to cut off.")
	end

	-- The default is `full` everywhere, `.test` included: the author writes the
	-- file exactly as it is. A test example often *shows* the package clause on
	-- purpose (`package model_test`) — if `test` kicked in automatically, a second
	-- one would stand in front of it and `goimports` would fail over that.
	local template = "full"
	if el.attributes["template"] ~= nil then
		template = el.attributes["template"]
	end
	-- Command-line arguments passed to the program via `go run . <args>`.
	local args = el.attributes["args"] or ""

	local tmp = os.tmpname()
	local src_dir = CACHE_DIR .. "/" .. tmp:match("[^/]+$")

	os.execute("mkdir -p " .. src_dir)

	-- The source file name matters: `go test` only finds tests in `*_test.go`.
	local src = src_dir .. "/" .. cfg.file
	-- Always clear away the whole directory, not just the source file: in test
	-- mode the `go.mod` lives there too, and the `go run` branch used to leave an
	-- empty directory behind in the cache on every run.
	local function cleanup()
		os.execute("rm -rf " .. shq(src_dir))
	end

	-- Every block gets a `go.mod`, `go run` blocks included: it is what lets
	-- `go mod tidy` resolve external imports, and without one the output says
	-- `command-line-arguments` instead of a real package name. It starts out with
	-- no requires at all — `go mod tidy` and any `go-get=` fill those in.
	local gm = io.open(src_dir .. "/go.mod", "w")
	gm:write("module " .. cfg.module .. "\n\ngo " .. go_mod_version() .. "\n")
	gm:close()

	-- `template="test"` prepends the package clause derived from `module=`, and
	-- only a `.test` block has that config. Without this guard the block dies in
	-- `cfg.pkg` with a bare Lua traceback naming neither slide nor code block.
	if template == "test" and not (is_test or is_vet) then
		cleanup()
		fail(el, 0, "",
			"template=\"test\" works only on `.test` and `.vet` blocks",
			"The package clause it adds is derived from `module=`, and a `go run` block\n" ..
			"  is always `package main`. Mark the block with `.test` (or `.vet`) as well:\n" ..
			"      ```{.go .run .test template=\"test\"}")
	end

	-- What gets compiled: the block content, with the exit markers of `exit_name`
	-- turned into calls. `code` itself stays untouched — `split_noshow` needs the
	-- markers in it to map line numbers.
	local src_code = code
	if exit_name ~= nil then
		-- `go test` reports an `os.Exit(0)` during a test as a failure of its own.
		if is_test then
			cleanup()
			fail(el, 0, "",
				"exit=\"" .. exit_name .. "\" does not work with `.test` blocks",
				"`go test` treats a call to `os.Exit` during a test as a failure. Cut the\n" ..
				"  test short with `t.SkipNow()` or a `return` instead.")
		end
		local found
		src_code, found = insert_exit(code, exit_name)
		if not found then
			cleanup()
			fail(el, 0, "",
				"No `// exit: " .. exit_name .. "` marker in the code block",
				"A `.go-output exit=\"" .. exit_name .. "\"` div needs a line\n" ..
				"      // exit: " .. exit_name .. "\n" ..
				"  in the block whose output it shows, where the program is to stop.")
		end
		local xf = io.open(src_dir .. "/" .. EXIT_FILE, "w")
		xf:write("package main\n\nimport \"os\"\n\nfunc " .. EXIT_FUNC .. "() {\n\tos.Exit(0)\n}\n")
		xf:close()
	end

	local f = io.open(src, "w")

	-- write the code according to template
	if template == "full" then
		f:write(src_code)
	elseif template == "test" then
		f:write("package " .. cfg.pkg .. "\n\n" .. src_code .. "\n")
	elseif template == "main" then
		f:write([[package main

    ]] .. src_code .. [[
    ]])
	elseif template == "mainfunc" then
		f:write([[package main

	  func main() {

    ]] .. src_code .. [[

	  }
    ]])
	else
		f:close()
		cleanup()
		fail(el, 0, "",
			"Unknown template=\"" .. template .. "\"",
			"Known are `full` (the default: the block is the whole file, written as it\n" ..
			"  is), `main` (adds the package clause), `mainfunc` (adds package clause and\n" ..
			"  `func main`) and `test` (adds the package clause, for `.test` blocks).\n" ..
			"  Except for `full`, the imports are filled in by `goimports`.")
	end
	f:close()

	-- hash source file (plus any run args) for cache key, so the same code with
	-- different args caches separately. Module path, file name and `go-get=` go
	-- in as well — they all end up in the generated `go.mod` and so can change the
	-- output on their own — plus `test-args` and the mode, because the same code
	-- would otherwise yield the same key whether run or tested.
	local key_extra = "go-mod|" .. cfg.module .. "|" .. cfg.file .. "|" .. cfg.go_get
	if is_test then
		key_extra = key_extra .. "|go-test|" .. cfg.flags
	end
	-- The output differs with and without the detector; without the extra, toggling
	-- it would bring the old cache entry back.
	if is_race then
		key_extra = key_extra .. "|race"
	end
	if is_vet then
		key_extra = key_extra .. "|go-vet|" .. cfg.vet_flags
	end
	-- The source already differs by the inserted call; this covers `EXIT_FILE`.
	if exit_name ~= nil then
		key_extra = key_extra .. "|exit"
	end
	-- What `go generate` produces depends on the tool versions from `go-get=`
	-- (already in the key) and the code; the extra only separates it from a run
	-- without generating.
	if cfg.go_generate then
		key_extra = key_extra .. "|go-generate"
	end
	local hp = io.popen("{ cat " .. src .. "; printf '%s' " .. shq(args) .. " " .. shq(key_extra) ..
		"; } | sha256sum | cut -c1-16")
	local key = hp:read("*l")
	hp:close()

	local cache_file = CACHE_DIR .. "/" .. key .. ".txt"
	local exit_file = CACHE_DIR .. "/" .. key .. ".exit"
	local cf = io.open(cache_file, "r")
	local ef = io.open(exit_file, "r")
	if cf and ef then
		local cached = cf:read("*all")
		local cached_exit = tonumber(ef:read("*l") or "")
		cf:close()
		ef:close()
		cleanup()
		-- The expectation is checked on a cache hit too: the `.expect-failure` class
		-- can have changed without the code changing.
		check_exit(el, cached_exit or 0, cached)
		return cached
	end
	if cf then
		cf:close()
	end
	if ef then
		ef:close()
	end

	-- run goimports for main template
	if template == "main" or template == "mainfunc" or template == "test" then
		-- If goimports does not run, the imports are missing and the block fails
		-- later with a misleading "undefined: fmt" — so abort hard here.
		local gi_output, gi_exit = run_in(src_dir, "goimports -w " .. cfg.file)
		-- `goimports` has to parse the code to add imports. With a deliberate syntax
		-- error (`.expect-failure`) it inevitably fails — that is not a setup problem.
		-- Let it carry on, `go run` delivers the real compiler error in a moment.
		if gi_exit ~= 0 and el.classes:includes("expect-failure") and has_cmd("goimports") then
			gi_exit = 0
		end
		if gi_exit ~= 0 then
			cleanup()
			fail(el, gi_exit, gi_output,
				"goimports failed",
				"The block uses template=\"" .. template .. "\", so the imports are added by\n" ..
				"  `goimports`. Is `goimports` installed on the PATH?\n" ..
				"      go install golang.org/x/tools/cmd/goimports@latest")
		end
	end

	-- `go mod tidy` turns the imports actually present in the source into requires,
	-- so a block just imports what it needs. It runs after `goimports`, which is
	-- what puts those imports there in the first place.
	--
	-- A setup failure here must not reach the slide: a block carrying
	-- `.expect-failure` (the compile error *is* the point) would otherwise show
	-- "cannot find module providing package" instead of the error it means to show.
	local tidy_out, tidy_exit = run_in(src_dir, "go mod tidy")
	if tidy_exit ~= 0 then
		cleanup()
		fail(el, tidy_exit, tidy_out,
			"`go mod tidy` failed",
			"The imports of the block are resolved by `tidy`; the first render of a new\n" ..
			"  dependency needs network. Otherwise: is the import path spelled right?\n" ..
			"  A module the code does not import itself needs `go-get=`.")
	end

	-- `go get` after `tidy`, never before: `tidy` drops every require nothing
	-- imports, so a module added first would be gone again. Pinning a version works
	-- either way round, adding an unimported module only in this order.
	--
	-- Then `tidy` and `go get` once more. Pinning an imported module to an older
	-- version than the one the first `tidy` picked (a downgrade) leaves `go.sum`
	-- without the entries for that version's own dependencies — the build then
	-- stops with "missing go.sum entry". The second `tidy` fills them in and keeps
	-- the pinned version (it never upgrades); it drops an unimported module again,
	-- which the second `go get` brings back.
	if cfg.go_get ~= "" then
		local function go_get()
			local get_out, get_exit = run_in(src_dir, "go get " .. cfg.go_get)
			if get_exit ~= 0 then
				cleanup()
				fail(el, get_exit, get_out,
					"`go get` failed",
					"go-get=\"" .. cfg.go_get .. "\" is passed to `go get` as it stands. Expected\n" ..
					"  are module paths, with a version where it matters:\n" ..
					"      go-get=\"go.uber.org/goleak@v1.3.0\"")
			end
		end
		go_get()
		local tidy2_out, tidy2_exit = run_in(src_dir, "go mod tidy")
		if tidy2_exit ~= 0 then
			cleanup()
			fail(el, tidy2_exit, tidy2_out,
				"`go mod tidy` after `go get` failed",
				"The versions from go-get=\"" .. cfg.go_get .. "\" do not fit together with\n" ..
				"  the imports of the block. Check the pinned versions.")
		end
		go_get()
	end

	-- `go generate` last, once `go.mod` is complete: a directive like
	-- `go tool mockgen` needs the tool that `go-get="-tool …"` added. The generated
	-- files only live in the scratch directory, the slide shows just the block.
	if cfg.go_generate then
		local gen_out, gen_exit = run_in(src_dir, "go generate ./...")
		if gen_exit ~= 0 then
			cleanup()
			fail(el, gen_exit, gen_out,
				"`go generate` failed",
				"A tool called by `//go:generate` has to be available in the module, e.g.\n" ..
				"      go-get=\"-tool go.uber.org/mock/mockgen@v0.6.0\"\n" ..
				"  together with `//go:generate go tool mockgen ...`. `-source=` names the\n" ..
				"  file as `filename=` does.")
		end
	end

	-- find how many boilerplate lines precede user code (for adjusting compiler error line numbers)
	local line_offset = 0
	if template ~= "full" then
		local first_line = src_code:match("^%s*([^\n]+)")
		if first_line then
			first_line = first_line:match("^%s*(.-)%s*$")
			local n = 0
			for line in io.lines(src) do
				n = n + 1
				if line:match("^%s*(.-)%s*$") == first_line then
					line_offset = n - 1
					break
				end
			end
		end
	end

	local env = is_race and race_env() or "CGO_ENABLED=0 "
	local race_flag = is_race and " -race" or ""
	local run_cmd
	if is_vet then
		run_cmd = env .. "go vet"
		if cfg.vet_flags ~= "" then
			run_cmd = run_cmd .. " " .. cfg.vet_flags
		end
		run_cmd = run_cmd .. " ."
	elseif is_test then
		-- `-count=1` disables Go's own test cache; otherwise the second run would put
		-- `(cached)` on the slide instead of a duration.
		run_cmd = env .. "go test -count=1" .. race_flag
		if cfg.flags ~= "" then
			run_cmd = run_cmd .. " " .. cfg.flags
		end
		run_cmd = run_cmd .. " ."
	else
		-- `go run .` rather than `go run <file>`: a single file is compiled outside
		-- the module, and the imports `go mod tidy` just resolved would go unused.
		run_cmd = env .. "go run" .. race_flag .. " ."
		if args ~= "" then
			run_cmd = run_cmd .. " " .. args
		end
	end
	local output, exit_code = run_in(src_dir, run_cmd)
	cleanup()

	-- A `.race` block deliberately ends with exit code != 0 and therefore carries
	-- `.expect-failure`. That would let a *setup* error slip through silently and
	-- land on the slide instead of the race report — we catch it here, before it
	-- reaches the cache.
	if is_race and (output:match("requires cgo") or output:match("C compiler")) then
		fail(el, exit_code, output,
			"The race detector could not be built",
			"`.race` needs cgo and a C compiler (the detector is ThreadSanitizer).\n" ..
			"  On Debian/Ubuntu: `apt install build-essential`. If only `cc` is there and\n" ..
			"  no `gcc`, the filter sets `CC=cc` itself — then the compiler really is missing.")
	end


	local wf = io.open(cache_file, "w")

	output = normalize_output(output, cfg)
	if is_vet then
		output = sort_findings(output)
	end
	local shown_file = cfg.file
	-- Map line numbers back onto the visible code. Two shifts overlap: the template
	-- boilerplate *above* the user code (constant `line_offset`, determined above)
	-- and the `<noshow>` blocks cut out of the *middle* — their offset is not
	-- constant, which is what the mapping from `split_noshow` is for.
	local _, line_map, hidden = split_noshow(code)
	if line_offset > 0 or hidden > 0 then
		-- Only match and replace `<file>:<number>` — whatever follows stays untouched,
		-- because `gsub` swaps out the match alone. After the number a ":" can follow
		-- (compiler error, the column before it), a space (panic stack trace, the
		-- offset "+0x56" before it) or nothing — the latter for inlined frames, which
		-- would otherwise have slipped through.
		local esc = lua_esc(shown_file)
		-- The same hidden line shows up any number of times in a loop — warn once.
		local warned = {}
		output = output:gsub(esc .. ":(%d+)", function(line_num)
			-- number in the generated file -> number in the block content …
			local in_code = tonumber(line_num) - line_offset
			if hidden == 0 then
				return shown_file .. ":" .. in_code
			end
			-- … -> number in the displayed code
			local shown = line_map[in_code]
			if shown == nil then
				if not warned[line_num] then
					warned[line_num] = true
					warn_hidden_line(el, shown_file, line_num)
				end
				return nil
			end
			return shown_file .. ":" .. shown
		end)
	end
	wf:write(output)
	wf:close()

	local ewf = io.open(exit_file, "w")
	ewf:write(tostring(exit_code) .. "\n")
	ewf:close()

	check_exit(el, exit_code, output)

	return output
end

-- class for styling output:
-- If it is go output, style it using go-output
-- If it is test or vet output, style it using bash-output
local function output_class(el)
	return (el.classes:includes("test") or el.classes:includes("vet")) and "bash-output" or "go-output"
end

-- The block as a `.go-output exit=` div runs it. Whether that run has to fail is
-- up to the div (`.expect-failure` on the div), not the block: a block that
-- panics at its end may well be cut off before the panic.
local function exit_run_block(block, div)
	local b = block:clone()
	b.classes = b.classes:filter(function(c)
		return c ~= "expect-failure"
	end)
	if div.classes:includes("expect-failure") then
		b.classes:insert("expect-failure")
	end
	return b
end

function Pandoc(doc)
	-- the original blocks by output-id, for `.go-output exit=` divs that run them again
	local blocks = {}

	-- Pass 1: execute all {.go .run} blocks, that have an "output-id" and collect outputs by id (output-id)
	doc.blocks:walk({
		CodeBlock = function(el)
			if el.classes:includes("go") and el.classes:includes("run") and el.attributes["output-id"] ~= nil then
				local output = cli_prefix(run_go(el), el)
				local identifier = el.attributes["output-id"]
				outputs[identifier] = output
				output_classes[identifier] = output_class(el)
				blocks[identifier] = el:clone()
			end
		end,
	})

	-- Pass 2: replace code blocks (inline output) and .go-output divs
	local last_go_output = nil -- remember the last output, for output without id
	local last_go_output_class = "go-output"
	local last_go_block = nil
	doc.blocks = doc.blocks:walk({
		CodeBlock = function(el)
			if not el.classes:includes("go") then
				return nil
			end

			if el.classes:includes("run") then
				-- remember the last output (run_go uses the original text with noshow blocks).
				-- A block with output-id already ran in pass 1 — reuse that result.
				local id = el.attributes["output-id"]
				local output = id and outputs[id] or cli_prefix(run_go(el), el)
				last_go_output = output
				last_go_output_class = output_class(el)
				-- a copy with the markers still in it; el.text loses them just below
				last_go_block = el:clone()

				el.text = (split_noshow(el.text))

				if el.classes:includes("output") then
					-- element with inline output
					return { el, pandoc.CodeBlock(last_go_output, { class = last_go_output_class }) }
				end
				return el
			end

			-- Non-.run go block: still hide noshow sections from the slide.
			el.text = (split_noshow(el.text))
			return el
		end,
		Div = function(el)
			if el.classes:includes("go-output") then
				-- use last go output as default
				local output = last_go_output
				local cls = last_go_output_class
				local block = last_go_block
				if el.attributes["output-id"] ~= nil then
					output = outputs[el.attributes["output-id"]]
					cls = output_classes[el.attributes["output-id"]] or "go-output"
					block = blocks[el.attributes["output-id"]]
				end
				-- `exit="<name>"`: not the block's own output, but that of a run cut
				-- off at its `// exit: <name>` markers
				local exit_name = el.attributes["exit"]
				if exit_name ~= nil and block ~= nil then
					output = cli_prefix(run_go(exit_run_block(block, el), exit_name), block)
				end
				if output ~= nil then
					-- keep the `go-output` class as a stable styling hook — for `.test`
					-- blocks it is replaced by `bash-output`
					local classes = el.classes:map(function(c)
						return c == "go-output" and cls or c
					end)
					local attr = pandoc.Attr(el.identifier, classes, el.attributes)
					return pandoc.CodeBlock(output, attr)
				end
			end
		end,
	})

	return doc
end
