local fs = require("@lune/fs")
local stdio = require("@lune/stdio")

-- TODO: syntax highlighting

local GREEN = stdio.color("green")
local RED = stdio.color("red")
local RESET = stdio.style("reset")
local BOLD = stdio.style("bold")
local DIM = stdio.style("dim")
local BACKGROUND_RED = "\27[41m"
local WHITE = stdio.color("white")

--#region typedef
local test = {}
test.__index = test
export type test_inner = {
	ok: { boolean },
	msg: { string? },
	info: { { any } },
	len: number,
	within: { string },
	name: { string? },
	current_within: string,
} & typeof(test)
export type test = test_inner & (name: string) -> test & (...test) -> test
export type test_solve = test & {
	_last_within_tbl: { string },
	_indent: string,
	_last_within: string,
	--             path        lines
	_line_list: { [string]: { [number]: string } },
	_last_count_len: number,
	_depth: number,
}
--#endregion typedef

--#region test Class
local function merge(self: test, ...: test): test
	local args = table.pack(...)
	local ok = self.ok
	local msg = self.msg
	local info = self.info
	local within = self.within
	local name = self.name
	local current_within = self.current_within
	local len = self.len
	for idx = 1, args.n do
		local item = args[idx]
		for inner_idx = 1, item.len do
			len += 1
			ok[len] = item.ok[inner_idx]
			msg[len] = item.msg[inner_idx]
			info[len] = item.info[inner_idx]
			name[len] = item.name[inner_idx]
			within[len] = `{current_within}.{item.within[inner_idx]}`
		end
	end
	self.len = len
	return self
end

function test.__call(self: test, ...: any): test
	local name = ...
	if type(name) == "string" then
		self.name[self.len + 1] = name
	else
		merge(self, ...)
	end
	return self :: any
end

local function create_test(_, within: string): test
	return setmetatable({
		info = {},
		ok = {},
		msg = {},
		name = {},
		within = {},
		len = 0,
		current_within = within,
	}, test) :: any
end

local function push_case(self: test, ok: boolean, msg: string?): test
	local len = self.len + 1
	self.len = len
	self.ok[len] = ok
	self.info[len] = table.pack(debug.info(3, "sln"))
	self.msg[len] = msg
	self.within[len] = self.current_within
	return self :: any
end

function test.assume_equal(self: test, a: any, b: any): test
	return push_case(self, a == b, "A and B should be equal")
end

function test.assume(self: test, expect: boolean): test
	return push_case(self, expect, "A assertion failed")
end
--#endregion test Class

--#region Debug
-- debug.info ( (), "sln" )
-- { debug_path, line_defined, () }

--[=[
	Get path of test case
]=]
local function get_path(self: test_solve, idx: number): string
	local path = self.info[idx][1]

	path = string.gsub(path, '^%[string%s*"?', "")
	path = string.gsub(path, '"?%s*%]$', "")
	return path
end

--[=[
	Get line of test case
]=]
local function get_line(self: test_solve, idx: number): number
	return self.info[idx][2]
end

--[=[
	Change '\t' to '  '
]=]
local function transform_indent_inner(whitespaces)
	return string.gsub(whitespaces, "\t", "  ")
end
local function transform_indent(content: string): string
	-- stylua: ignore start
	return string.gsub(
		string.gsub(
			content,
			"\n[ \t]+",
			transform_indent_inner
		),
		"^[ \t]+",
		transform_indent_inner
	)
	-- stylua: ignore end
end

--[=[
	Convert raw file content to line list
]=]
local function file_to_line_list(content: string): { string }
	local line_list = {}
	content = transform_indent(content)
	for line in string.gmatch(content, "([^\n]*)\n") do
		table.insert(line_list, line)
	end
	return line_list
end

--[=[
	Get line list from file and cache to test_solve
]=]
local function get_line_list(test: test_solve, path: string): { string }
	local cache = test._line_list
	local cached_file = cache[path]
	if cached_file then
		return cached_file
	end
	if not fs.isFile(path) then
		error(`{path} is not a file`)
	end
	local result = file_to_line_list(fs.readFile(path))
	cache[path] = result
	return result
end

--[=[
	Show 5 lines above, below
]=]
local function get_trace_lines(target_line: number, line_list: { string }): string
	local startAt = math.max(target_line - 5, 1)
	local endAt = math.min(#line_list, target_line + 5)

	local lines = endAt - startAt + 1
	local lines_buffer = table.create(lines)
	for no = startAt, endAt do
		local background = if no == target_line then BACKGROUND_RED else ""
		table.insert(lines_buffer, `{WHITE}{background}{DIM}[{no}]:{RESET}{WHITE}{background} {line_list[no]}{RESET}`)
	end
	return table.concat(lines_buffer, "\n", 1, lines)
end

--[=[
	Get trace lines (with test index)
]=]
local TRACE_INDENT_FIRST = "     ╭ "
local TRACE_INDENT = "     │ "
local TRACE_INDENT_LAST = "     ╰ "
local function replace_trace_last_line(indents)
	return string.gsub(indents, TRACE_INDENT, TRACE_INDENT_LAST)
end
local function get_trace(self: test_solve, idx: number): string
	local path = get_path(self, idx)
	local line = get_line(self, idx)
	local indent = `{self._indent}{DIM}{TRACE_INDENT}{RESET}`

	local line_list = get_line_list(self, path)
	local trace = get_trace_lines(line, line_list)
	local indented_trace = `{indent}{string.gsub(trace, "\n", `\n{indent}`)}`
	indented_trace = string.gsub(indented_trace, "%s*$", "")
	indented_trace = string.gsub(indented_trace, "┃[^\n]-$", replace_trace_last_line)
	return `{self._indent}{DIM}{TRACE_INDENT_FIRST}{RESET}{path}:{line}\n{indented_trace}`
end
--#endregion Debug

--#region test solver
local PASS_TEXT = `{GREEN}{BOLD}PASS{RESET} {DIM}-{RESET} ` -- no...
local FAIL_TEXT = `{RED}{BOLD}FAIL{RESET} {DIM}-{RESET} `
local function print_case(self: test_solve, idx: number)
	local case_name = self.name[idx] or "Unnamed"
	-- stylua: ignore start
	if self.ok[idx] then
		stdio.write(`{
			self._indent
		}{
			PASS_TEXT
		}{
			case_name
		}\n`)
	else
		stdio.write(`{
			self._indent
		}{
			FAIL_TEXT
		}{
			case_name
		}:\n{
			get_trace(self, idx)
		}\n`)
	end
	-- stylua: ignore end
end

local COUNT_SEP = `{RESET}{BOLD} : {RESET}`
local function count_pass(self: test_solve, idx: number): string
	local within = self.within
	local ok = self.ok
	local first = self.within[idx]
	local pass = if ok[idx] then 1 else 0
	local fail = if ok[idx] then 0 else 1

	for after = idx + 1, self.len do
		if within[after] ~= first then
			break
		end
		if ok[after] then
			pass += 1
		else
			fail += 1
		end
	end

	local has_pass = pass ~= 0
	local has_fail = fail ~= 0
	local pass_str = if has_pass then tostring(pass) else ""
	local fail_str = if has_fail then tostring(fail) else ""

	local count_len = 2 + #pass_str + #fail_str
	if has_pass and has_fail then
		count_len += 3
	end
	self._last_count_len = count_len

	-- stylua: ignore start
	return `{BOLD}[{
		if has_pass then GREEN else ""
	}{pass_str}{
		if has_pass and has_fail then COUNT_SEP else ""
	}{
		if has_fail then RED else ""
	}{fail_str}{RESET}{BOLD}]{RESET}`
	-- stylua: ignore end
end

local INDENT_BASE = `{BOLD}┃{RESET} `
local function print_within(self: test_solve, idx: number)
	local last_within = self._last_within or ""
	local within = self.within[idx]
	if within == last_within then
		return
	end

	local depth = 0
	local within_tbl = {}
	for id in string.gmatch(within, "[^%.]+") do
		depth += 1
		table.insert(within_tbl, id)
	end

	self._depth = depth
	self._indent = string.rep(INDENT_BASE, depth)
	self._last_within = within
	self._last_within_tbl = within_tbl

	-- stylua: ignore start
	stdio.write(`{
		string.rep(INDENT_BASE, depth - 1)
	}┏━{
		count_pass(self, idx)
	}{BOLD}: {RESET}{
		self.within[idx]
	}\n`)
	-- stylua: ignore end
end

local function print_footer(self: test_solve, idx: number)
	if self._last_within == self.within[idx + 1] then
		return
	end
	stdio.write(`{string.rep(INDENT_BASE, self._depth - 1)}┗━{string.rep("━", self._last_count_len)}━\n`)
end

function test.solve(self: test)
	local len = self.len;

	(self :: test_solve)._line_list = {}

	for idx = 1, len do
		print_within(self :: any, idx)
		print_case(self :: any, idx)
		print_footer(self :: any, idx)
	end
end
--#endregion test solver

return (setmetatable({}, {
	__call = create_test,
}) :: unknown) :: (within: string) -> test
