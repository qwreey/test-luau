local fs = require("@lune/fs")
local stdio = require("@lune/stdio")

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

local function push(self: test, ok: boolean, msg: string?): test
	local len = self.len + 1
	self.len = len
	self.ok[len] = ok
	self.info[len] = table.pack(debug.info(3, "sln"))
	self.msg[len] = msg
	self.within[len] = self.current_within
	return self :: any
end

function test.assume_equal(self: test, a: any, b: any): test
	return push(self, a == b, "A and B should be equal")
end

function test.assume(self: test, expect: boolean): test
	return push(self, expect, "A assertion failed")
end

export type test_solve = test & {
	_last_within_tbl: { string },
	_indent: string,
	_last_within: string,
	_file_cache: { string },
	_last_count_len: number,
	_depth: number,
}

local GREEN = stdio.color("green")
local RED = stdio.color("red")
local RESET = stdio.style("reset")
local BOLD = stdio.style("bold")

local PASS_TEXT = `{GREEN}{BOLD}PASS{RESET} - `
local FAIL_TEXT = `{RED}{BOLD}FAIL{RESET} - `
local FAIL_FOOTER = `       `
local function print_case(self: test_solve, idx: number)
	if self.ok[idx] then
		stdio.write(`{self._indent}{PASS_TEXT}{self.name[idx] or "Unnamed"}\n`)
	else
		print(self.info[idx])
		stdio.write(
			`{self._indent}{FAIL_TEXT} - {self.name[idx] or "Unnamed"}:\n{self._indent}{FAIL_FOOTER}In file: {self.info[idx]}\n`
		)
	end
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

local function get_trace(): string end

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

	(self :: test_solve)._file_cache = {}

	for idx = 1, len do
		print_within(self :: any, idx)
		print_case(self :: any, idx)
		print_footer(self :: any, idx)
	end
end

return (setmetatable({}, {
	__call = create_test,
}) :: unknown) :: (within: string) -> test
