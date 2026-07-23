--- StarDict dictionary discovery, in-memory index loading,
--- prefix search and definition reading.
--- Supports .ifo/.idx/.dict (StarDict, GoldenDict, sdcv) formats.
--- Adapted from blink-cmp-stardict for use as a standalone stardict.nvim backend.
--- @module stardict.dict

local M = {}

local TRAILER_LEN = 9 -- 1 NUL + 4 offset + 4 size
local PARSE_CHUNK = 100000 -- records per scheduled tick while loading

local function read_file(path)
	-- binary mode is required: on Windows, text mode reports inflated
	-- positions and would corrupt any offset arithmetic
	local f = io.open(path, "rb")
	if not f then
		return nil
	end
	local data = f:read("*a")
	f:close()
	return data
end

--- Parse the bookname and sametypesequence out of an .ifo file
--- @param ifo_path string
--- @return string? name, string? idx_path, string? sametypesequence
function M.parse_ifo(ifo_path)
	local content = read_file(ifo_path)
	if not content then
		return nil
	end
	local name = content:match("bookname=(.-)\r?\n") or content:match("bookname=(.*)$")
	if not name or name == "" then
		return nil
	end
	name = vim.trim(name)
	local idx_path = ifo_path:gsub("%.ifo$", ".idx")
	local sametypesequence = content:match("sametypesequence=(.-)\r?\n")
		or content:match("sametypesequence=(.*)$")
	if sametypesequence then
		sametypesequence = vim.trim(sametypesequence)
	end
	return name, idx_path, sametypesequence
end

--- Discover dictionaries under the given directories, scanning recursively.
--- @param dict_dirs string[]
--- @param filter? { include?: string[], exclude?: string[] } bookname filter;
---   include = only these booknames (nil = all), exclude = drop these booknames
--- @return table[] dict handles: { name, ifo_path, idx_path, dict_path, sametypesequence, status }
function M.discover(dict_dirs, filter)
	filter = filter or {}
	local include = filter.include
	if include and #include == 0 then
		include = nil
	end
	local exclude = nil
	if filter.exclude then
		exclude = {}
		for _, name in ipairs(filter.exclude) do
			exclude[name] = true
		end
	end

	local dicts = {}
	local seen_paths = {}
	for _, dir in ipairs(dict_dirs) do
		dir = vim.fn.expand(dir)
		for _, ifo in ipairs(vim.fn.glob(dir .. "/**/*.ifo", true, true)) do
			if not seen_paths[ifo] then
				seen_paths[ifo] = true
				local name, idx_path, sametypesequence = M.parse_ifo(ifo)
				if
					name
					and idx_path
					and (not include or vim.tbl_contains(include, name))
					and not (exclude and exclude[name])
				then
					table.insert(dicts, {
						name = name,
						ifo_path = ifo,
						idx_path = idx_path,
						dict_path = idx_path:gsub("%.idx$", ".dict"),
						sametypesequence = sametypesequence,
						status = "new", -- new | loading | ready | failed
					})
				end
			end
		end
	end
	return dicts
end

--- Parse the .idx blob into offset arrays. Yields periodically when used
--- inside a coroutine.
--- @param dict table dict handle (blob must be set)
local function parse_idx(dict)
	local blob = dict.blob
	local starts, lens = {}, {}
	local pos = 1
	local n = 0
	local since_yield = 0
	while pos <= #blob do
		local nul = blob:find("\0", pos, true)
		if not nul then
			break
		end
		n = n + 1
		starts[n] = pos
		lens[n] = nul - pos
		pos = nul + TRAILER_LEN
		since_yield = since_yield + 1
		if since_yield >= PARSE_CHUNK then
			since_yield = 0
			if coroutine.isyieldable() then
				coroutine.yield(false)
			end
		end
	end
	dict.starts = starts
	dict.lens = lens
	dict.n = n
end

--- Load a dictionary synchronously (used in tests and as fallback)
--- @param dict table
--- @return boolean ok
function M.load_sync(dict)
	dict.status = "loading"
	local blob = read_file(dict.idx_path)
	if not blob then
		dict.status = "failed"
		return false
	end
	dict.blob = blob
	-- parse_idx may yield; drain it in a dedicated coroutine so callers
	-- running inside another coroutine (e.g. plenary tests) are not disturbed
	local co = coroutine.create(parse_idx)
	local ok = coroutine.resume(co, dict)
	while ok and coroutine.status(co) ~= "dead" do
		ok = coroutine.resume(co)
	end
	dict.status = ok and "ready" or "failed"
	return ok
end

--- Load a dictionary in scheduled chunks so the UI never blocks
--- @param dict table
--- @param on_done? fun(ok: boolean)
function M.load_async(dict, on_done)
	dict.status = "loading"
	local co = coroutine.create(function()
		local blob = read_file(dict.idx_path)
		if not blob then
			error("cannot read " .. dict.idx_path)
		end
		dict.blob = blob
		parse_idx(dict)
		return true
	end)
	local function step()
		local ok, err = coroutine.resume(co)
		local dead = coroutine.status(co) == "dead"
		if not ok then
			dict.status = "failed"
			if on_done then
				on_done(false)
			end
			return
		end
		if dead then
			dict.status = "ready"
			if on_done then
				on_done(true)
			end
			return
		end
		vim.schedule(step)
	end
	vim.schedule(step)
end

--- Get the i-th word (1-based)
function M.word_at(dict, i)
	return dict.blob:sub(dict.starts[i], dict.starts[i] + dict.lens[i] - 1)
end

--- Get the byte offset and size of the i-th word's data in .dict
--- @param dict table
--- @param i integer
--- @return integer offset, integer size
local function entry_offset_size(dict, i)
	local pos = dict.starts[i] + dict.lens[i] + 1
	local blob = dict.blob
	local offset = blob:byte(pos) * 16777216 + blob:byte(pos + 1) * 65536 + blob:byte(pos + 2) * 256 + blob:byte(pos + 3)
	local size = blob:byte(pos + 4) * 16777216 + blob:byte(pos + 5) * 65536 + blob:byte(pos + 6) * 256
		+ blob:byte(pos + 7)
	return offset, size
end

--- Index of the first word whose lowercase form is >= target (1-based, may be n+1)
local function lower_bound(dict, target)
	local lo, hi = 1, dict.n
	local res = dict.n + 1
	while lo <= hi do
		local mid = math.floor((lo + hi) / 2)
		if M.word_at(dict, mid):lower() >= target then
			res = mid
			hi = mid - 1
		else
			lo = mid + 1
		end
	end
	return res
end

--- Case-insensitive prefix search over the sorted word index
--- @param dict table loaded dict handle (status == "ready")
--- @param prefix string
--- @param max_items integer
--- @return string[]
function M.prefix_search(dict, prefix, max_items)
	if dict.status ~= "ready" or dict.n == 0 then
		return {}
	end
	local target = prefix:lower()
	local out = {}
	local i = lower_bound(dict, target)
	while i <= dict.n and #out < max_items do
		local word = M.word_at(dict, i)
		if word:lower():sub(1, #target) ~= target then
			break
		end
		table.insert(out, word)
		i = i + 1
	end
	return out
end

--- Find the exact word in the index (case-insensitive). Returns the index or nil.
--- @param dict table
--- @param word string
--- @return integer? index
function M.exact_match(dict, word)
	if dict.status ~= "ready" or dict.n == 0 then
		return nil
	end
	local target = word:lower()
	local i = lower_bound(dict, target)
	if i <= dict.n and M.word_at(dict, i):lower() == target then
		return i
	end
	return nil
end

--- Read the raw definition data for the i-th index entry.
--- Reads from the .dict file on disk every time (keeps memory low).
--- @param dict table
--- @param i integer
--- @return string? data
function M.read_definition(dict, i)
	if dict.status ~= "ready" or i < 1 or i > dict.n then
		return nil
	end
	local f = io.open(dict.dict_path, "rb")
	if not f then
		return nil
	end
	local offset, size = entry_offset_size(dict, i)
	f:seek("set", offset)
	local data = f:read(size)
	f:close()
	return data
end

--- Read the raw definition data for an exact word match.
--- @param dict table
--- @param word string
--- @return string? data
function M.get_definition(dict, word)
	local i = M.exact_match(dict, word)
	if not i then
		return nil
	end
	return M.read_definition(dict, i)
end

return M
