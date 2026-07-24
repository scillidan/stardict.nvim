--- stardict.nvim — offline StarDict lookup in a floating window.
--- A native-Windows-friendly replacement for dict.nvim that reads
--- .ifo/.idx/.dict files directly (no external dict/dictd/sdcv binary).
--- @module stardict

local dict = require("stardict.dict")
local format = require("stardict.format")

local M = {}

---@class StardictUserOpts
---@field dict_dirs? string[] Directories scanned recursively for StarDict dictionaries
---@field include_dictionaries? string[] Only enable these booknames
---@field exclude_dictionaries? string[] Disable these booknames
---@field dictionary_order? string[] Fixed display order for dictionaries (by bookname)
---@field display_mode? "combined" | "split" Show all dictionaries at once or a switchable side list
---@field max_items? integer Maximum prefix suggestions shown when exact match fails
---@field ansi_colors? boolean Render ANSI colors as highlights
---@field window? { width?: integer, height?: integer, list_width?: integer }

---@type StardictUserOpts
M.opts = {
	dict_dirs = { "~/.stardict/dic", "/usr/share/stardict/dic" },
	include_dictionaries = nil,
	exclude_dictionaries = nil,
	dictionary_order = nil,
	display_mode = "split",
	max_items = 100,
	ansi_colors = true,
	window = {
		width = 120,
		list_width = 30,
	},
}

local _dicts = {}
local _combined_buf = nil
local _combined_win = nil
local _origin_win = nil
local _origin_word = nil
local _split_state = nil
local _suggest_state = nil

local function notify(msg, level)
	vim.notify(msg, level or vim.log.levels.INFO, { title = "stardict" })
end

local function warn(msg)
	notify(msg, vim.log.levels.WARN)
end

local function all_loaded()
	for _, d in ipairs(_dicts) do
		if d.status ~= "ready" and d.status ~= "failed" then
			return false
		end
	end
	return true
end

local function get_cword()
	local wcur = vim.api.nvim_win_get_cursor(0)
	local line = vim.api.nvim_buf_get_lines(0, wcur[1] - 1, wcur[1], true)[1]
	local cpos = wcur[2] + 1
	if type(line) ~= "string" then
		return nil
	end
	local cchar = string.sub(line, cpos, cpos)
	if cchar == "" or string.match(cchar, "%s") or string.match(cchar, "%p") then
		return nil
	end
	return vim.fn.expand("<cword>")
end

--- Sort dictionaries by the user-supplied order; unlisted items keep discovery order.
--- @param dicts table[]
--- @param order string[]
local function sort_dicts(dicts, order)
	if not order or #order == 0 then
		return
	end
	local rank = {}
	for i, name in ipairs(order) do
		rank[name:lower()] = i
	end
	local fallback = #order + 1
	-- preserve discovery order for unlisted dictionaries by tagging them first
	for i, d in ipairs(dicts) do
		d._discovered = i
	end
	table.sort(dicts, function(a, b)
		local ra = rank[a.name:lower()] or (fallback + a._discovered)
		local rb = rank[b.name:lower()] or (fallback + b._discovered)
		return ra < rb
	end)
	for _, d in ipairs(dicts) do
		d._discovered = nil
	end
end

--- Close all stardict windows.
function M.close()
	if _suggest_state then
		for _, win in ipairs({ _suggest_state.list_win, _suggest_state.def_win }) do
			if win and vim.api.nvim_win_is_valid(win) then
				vim.api.nvim_win_close(win, false)
			end
		end
		_suggest_state = nil
	end
	if _split_state then
		for _, win in ipairs({ _split_state.list_win, _split_state.def_win }) do
			if win and vim.api.nvim_win_is_valid(win) then
				vim.api.nvim_win_close(win, false)
			end
		end
		_split_state = nil
	end
	if _combined_win and vim.api.nvim_win_is_valid(_combined_win) then
		vim.api.nvim_win_close(_combined_win, false)
	end
	_combined_win = nil
end

--- Replace the original word with the word currently under the cursor.
local function replace_word()
	local new_word = get_cword()
	M.close()
	if not new_word or not _origin_word then
		return
	end
	local ow = _origin_win
	if ow and vim.api.nvim_win_is_valid(ow) then
		vim.api.nvim_set_current_win(ow)
		vim.cmd("normal! ciw" .. new_word)
		vim.cmd("stopinsert")
	end
end

local function ensure_combined_buffer()
	if _combined_buf and vim.api.nvim_buf_is_valid(_combined_buf) then
		return _combined_buf
	end
	_combined_buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_set_option_value("buftype", "nofile", { scope = "local", buf = _combined_buf })
	vim.api.nvim_set_option_value("bufhidden", "hide", { scope = "local", buf = _combined_buf })
	vim.api.nvim_set_option_value("swapfile", false, { scope = "local", buf = _combined_buf })
	vim.api.nvim_set_option_value("undolevels", -1, { scope = "local", buf = _combined_buf })
	vim.api.nvim_set_option_value("filetype", "markdown", { scope = "local", buf = _combined_buf })
	vim.keymap.set("n", "q", M.close, { silent = true, buffer = _combined_buf })
	vim.keymap.set("n", "<Esc>", M.close, { silent = true, buffer = _combined_buf })
	vim.keymap.set("n", "<Enter>", replace_word, { silent = true, buffer = _combined_buf })
	return _combined_buf
end

local function open_combined_float(lines, spans)
	local buf = ensure_combined_buffer()
	vim.api.nvim_buf_set_lines(buf, 0, -1, true, lines)

	if spans and #spans > 0 then
		format.apply_ansi_spans(buf, spans)
	end

	if _combined_win and vim.api.nvim_win_is_valid(_combined_win) then
		vim.api.nvim_win_set_cursor(_combined_win, { 1, 0 })
		return
	end

	local nc = vim.o.columns
	local nr = vim.o.lines
	local width = M.opts.window.width or 120
	if width > nc - 4 then
		width = nc - 4
	end
	local col = math.floor((nc - width) / 2)

	local height = M.opts.window.height
	if not height then
		height = math.min(#lines, nr - 4)
	end
	height = math.max(15, math.min(height, nr - 4))
	local row = math.floor((nr - height) / 2) - 1

	_combined_win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		width = width,
		height = height,
		col = col,
		row = row,
		anchor = "NW",
		style = "minimal",
		border = "rounded",
	})
	vim.api.nvim_set_option_value("conceallevel", 2, { win = _combined_win })
	vim.api.nvim_set_option_value("wrap", true, { win = _combined_win })
	vim.api.nvim_win_set_cursor(_combined_win, { 1, 0 })

	vim.api.nvim_create_autocmd("WinClosed", {
		pattern = tostring(_combined_win),
		once = true,
		callback = function()
			_combined_win = nil
		end,
	})
end

local LIST_SELECT_NS = vim.api.nvim_create_namespace("stardict-list-select")

local function define_list_highlights()
	vim.api.nvim_set_hl(0, "StardictSelected", { link = "PmenuSel", default = true })
end

--- Highlight the selected row in the split dictionary list.
--- @param list_buf integer
--- @param idx integer
local function highlight_list_selection(list_buf, idx)
	vim.api.nvim_buf_clear_namespace(list_buf, LIST_SELECT_NS, 0, -1)
	vim.api.nvim_buf_set_extmark(list_buf, LIST_SELECT_NS, idx - 1, 0, {
		line_hl_group = "StardictSelected",
		priority = 200,
	})
end

--- Render the currently selected split entry in the definition window.
--- @param idx integer
local function render_split_entry(idx)
	local state = _split_state
	if not state then
		return
	end
	local entry = state.entries[idx]
	state.selected = idx

	if state.list_win and vim.api.nvim_win_is_valid(state.list_win) then
		vim.api.nvim_win_set_cursor(state.list_win, { idx, 0 })
	end
	if state.list_buf and vim.api.nvim_buf_is_valid(state.list_buf) then
		highlight_list_selection(state.list_buf, idx)
	end

	local lines = vim.split(entry.definition, "\n", { plain = true })
	vim.api.nvim_buf_set_lines(state.def_buf, 0, -1, true, lines)

	-- clear previous ansi highlights and re-apply
	vim.api.nvim_buf_clear_namespace(state.def_buf, vim.api.nvim_create_namespace("stardict-ansi"), 0, -1)
	if entry.spans and #entry.spans > 0 then
		format.apply_ansi_spans(state.def_buf, entry.spans)
	end
end

--- Cycle the split dictionary list by delta entries.
--- @param delta integer
local function cycle_split(delta)
	local state = _split_state
	if not state then
		return
	end
	local n = #state.entries
	local idx = state.selected + delta
	if idx > n then
		idx = 1
	elseif idx < 1 then
		idx = n
	end
	render_split_entry(idx)
end

--- Open a side-by-side dictionary list + definition view.
--- @param entries table[] { name, definition, spans }
--- @param word string
local function open_split_view(entries, word)
	_origin_win = vim.api.nvim_get_current_win()
	_origin_word = word

	local list_buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_set_option_value("buftype", "nofile", { scope = "local", buf = list_buf })
	vim.api.nvim_set_option_value("bufhidden", "hide", { scope = "local", buf = list_buf })
	vim.api.nvim_set_option_value("swapfile", false, { scope = "local", buf = list_buf })
	vim.api.nvim_set_option_value("undolevels", -1, { scope = "local", buf = list_buf })
	vim.api.nvim_set_option_value("modifiable", true, { scope = "local", buf = list_buf })

	local names = {}
	for _, e in ipairs(entries) do
		table.insert(names, e.name)
	end
	vim.api.nvim_buf_set_lines(list_buf, 0, -1, true, names)
	vim.api.nvim_set_option_value("modifiable", false, { scope = "local", buf = list_buf })

	local def_buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_set_option_value("buftype", "nofile", { scope = "local", buf = def_buf })
	vim.api.nvim_set_option_value("bufhidden", "hide", { scope = "local", buf = def_buf })
	vim.api.nvim_set_option_value("swapfile", false, { scope = "local", buf = def_buf })
	vim.api.nvim_set_option_value("undolevels", -1, { scope = "local", buf = def_buf })
	vim.api.nvim_set_option_value("filetype", "markdown", { scope = "local", buf = def_buf })

	_split_state = {
		list_buf = list_buf,
		def_buf = def_buf,
		entries = entries,
		selected = 1,
		word = word,
	}

	local nc = vim.o.columns
	local nr = vim.o.lines
	local total_width = M.opts.window.width or 120
	if total_width > nc - 4 then
		total_width = nc - 4
	end
	local list_width = M.opts.window.list_width or 30
	list_width = math.min(list_width, math.floor(total_width / 2))
	local def_width = total_width - list_width - 1

	local height = M.opts.window.height
	if not height then
		height = math.floor(nr * 0.85)
	end
	height = math.max(20, math.min(height, nr - 4))

	local col = math.floor((nc - total_width) / 2)
	local row = math.floor((nr - height) / 2) - 1

	local list_win = vim.api.nvim_open_win(list_buf, false, {
		relative = "editor",
		width = list_width,
		height = height,
		col = col,
		row = row,
		anchor = "NW",
		style = "minimal",
		border = "rounded",
		title = " Dictionaries ",
		title_pos = "center",
	})
	vim.api.nvim_set_option_value("cursorline", true, { win = list_win })
	vim.api.nvim_set_option_value("number", false, { win = list_win })
	vim.api.nvim_set_option_value("relativenumber", false, { win = list_win })
	vim.api.nvim_set_option_value("wrap", false, { win = list_win })

	local def_win = vim.api.nvim_open_win(def_buf, true, {
		relative = "editor",
		width = def_width,
		height = height,
		col = col + list_width + 1,
		row = row,
		anchor = "NW",
		style = "minimal",
		border = "rounded",
		title = " " .. word .. " ",
		title_pos = "center",
	})
	vim.api.nvim_set_option_value("conceallevel", 2, { win = def_win })
	vim.api.nvim_set_option_value("wrap", true, { win = def_win })

	_split_state.list_win = list_win
	_split_state.def_win = def_win

	define_list_highlights()

	-- List window keymaps
	vim.keymap.set("n", "q", M.close, { silent = true, buffer = list_buf })
	vim.keymap.set("n", "<Esc>", M.close, { silent = true, buffer = list_buf })
	vim.keymap.set("n", "j", function()
		cycle_split(1)
	end, { silent = true, buffer = list_buf })
	vim.keymap.set("n", "k", function()
		cycle_split(-1)
	end, { silent = true, buffer = list_buf })
	vim.keymap.set("n", "<Tab>", function()
		cycle_split(1)
	end, { silent = true, buffer = list_buf })
	vim.keymap.set("n", "<S-Tab>", function()
		cycle_split(-1)
	end, { silent = true, buffer = list_buf })
	vim.keymap.set("n", "<Enter>", function()
		if _split_state and _split_state.def_win and vim.api.nvim_win_is_valid(_split_state.def_win) then
			vim.api.nvim_set_current_win(_split_state.def_win)
		end
	end, { silent = true, buffer = list_buf })
	vim.keymap.set("n", "<C-l>", function()
		if _split_state and _split_state.def_win and vim.api.nvim_win_is_valid(_split_state.def_win) then
			vim.api.nvim_set_current_win(_split_state.def_win)
		end
	end, { silent = true, buffer = list_buf })

	-- Definition window keymaps
	vim.keymap.set("n", "q", M.close, { silent = true, buffer = def_buf })
	vim.keymap.set("n", "<Esc>", M.close, { silent = true, buffer = def_buf })
	vim.keymap.set("n", "<Enter>", replace_word, { silent = true, buffer = def_buf })
	vim.keymap.set("n", "<Tab>", function()
		cycle_split(1)
	end, { silent = true, buffer = def_buf })
	vim.keymap.set("n", "<S-Tab>", function()
		cycle_split(-1)
	end, { silent = true, buffer = def_buf })
	vim.keymap.set("n", "<C-h>", function()
		if _split_state and _split_state.list_win and vim.api.nvim_win_is_valid(_split_state.list_win) then
			vim.api.nvim_set_current_win(_split_state.list_win)
		end
	end, { silent = true, buffer = def_buf })

	render_split_entry(1)

	-- Close the pair together when either window is closed.
	for _, win in ipairs({ list_win, def_win }) do
		vim.api.nvim_create_autocmd("WinClosed", {
			pattern = tostring(win),
			once = true,
			callback = function()
				M.close()
			end,
		})
	end
end

--- Render the currently selected suggestion entry in the definition window.
--- The definition is always shown in combined mode (all dictionaries).
--- @param idx integer
local function render_suggestion_entry(idx)
	local state = _suggest_state
	if not state then
		return
	end
	local entry = state.entries[idx]
	state.selected = idx

	if state.list_win and vim.api.nvim_win_is_valid(state.list_win) then
		vim.api.nvim_win_set_cursor(state.list_win, { idx, 0 })
	end
	if state.list_buf and vim.api.nvim_buf_is_valid(state.list_buf) then
		highlight_list_selection(state.list_buf, idx)
	end

	-- Build a combined definition for the selected suggestion across all dictionaries.
	local dict_entries = {}
	for _, d in ipairs(_dicts) do
		if d.status == "ready" then
			local data = dict.get_definition(d, entry.name)
			if data then
				local md, spans = format.to_markdown(data, d.sametypesequence, {
					ansi_colors = M.opts.ansi_colors,
				})
				table.insert(dict_entries, { name = d.name, definition = md, spans = spans })
			end
		end
	end

	local text, spans
	if #dict_entries == 0 then
		text = "No definition found."
	else
		text, spans = format.combine(dict_entries)
	end

	local lines = vim.split(text, "\n", { plain = true })
	vim.api.nvim_buf_set_lines(state.def_buf, 0, -1, true, lines)

	vim.api.nvim_buf_clear_namespace(state.def_buf, vim.api.nvim_create_namespace("stardict-ansi"), 0, -1)
	if spans and #spans > 0 then
		format.apply_ansi_spans(state.def_buf, spans)
	end
end

--- Cycle the suggestion list by delta entries.
--- @param delta integer
local function cycle_suggestion(delta)
	local state = _suggest_state
	if not state then
		return
	end
	local n = #state.entries
	local idx = state.selected + delta
	if idx > n then
		idx = 1
	elseif idx < 1 then
		idx = n
	end
	render_suggestion_entry(idx)
end

--- Adopt the currently selected suggestion: replace the original word and close.
local function select_suggestion_and_replace()
	local state = _suggest_state
	if not state then
		return
	end
	local word = state.entries[state.selected].name
	local ow = _origin_win
	local owrd = _origin_word
	M.close()
	if owrd and ow and vim.api.nvim_win_is_valid(ow) then
		vim.api.nvim_set_current_win(ow)
		vim.cmd("normal! ciw" .. word)
		vim.cmd("stopinsert")
	end
end

--- Scroll the suggestion definition window by a number of lines.
--- @param lines integer negative = up, positive = down
local function scroll_definition_lines(lines)
	local state = _suggest_state
	if not state or not state.def_win or not vim.api.nvim_win_is_valid(state.def_win) then
		return
	end
	local win = state.def_win
	local buf = vim.api.nvim_win_get_buf(win)
	local line_count = vim.api.nvim_buf_line_count(buf)
	local cur = vim.api.nvim_win_get_cursor(win)
	local new_row = math.max(1, math.min(cur[1] + lines, line_count))
	vim.api.nvim_win_set_cursor(win, { new_row, cur[2] })
end

--- Scroll the suggestion definition window by a fraction of its height.
--- @param fraction number negative = up, positive = down (e.g. 0.5 or 1.0)
local function scroll_definition_page(fraction)
	local state = _suggest_state
	if not state or not state.def_win or not vim.api.nvim_win_is_valid(state.def_win) then
		return
	end
	local win = state.def_win
	local height = vim.api.nvim_win_get_height(win)
	scroll_definition_lines(math.max(1, math.floor(height * fraction)))
end

--- Open a side-by-side suggestion list + definition view.
--- Left: suggested words. Right: combined definition of the selected suggestion.
--- @param suggestions string[]
--- @param word string original lookup word
local function open_suggestion_split_view(suggestions, word)
	_origin_win = vim.api.nvim_get_current_win()
	_origin_word = word

	local entries = {}
	for _, w in ipairs(suggestions) do
		table.insert(entries, { name = w })
	end

	local list_buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_set_option_value("buftype", "nofile", { scope = "local", buf = list_buf })
	vim.api.nvim_set_option_value("bufhidden", "hide", { scope = "local", buf = list_buf })
	vim.api.nvim_set_option_value("swapfile", false, { scope = "local", buf = list_buf })
	vim.api.nvim_set_option_value("undolevels", -1, { scope = "local", buf = list_buf })
	vim.api.nvim_set_option_value("modifiable", true, { scope = "local", buf = list_buf })

	local names = {}
	for _, e in ipairs(entries) do
		table.insert(names, e.name)
	end
	vim.api.nvim_buf_set_lines(list_buf, 0, -1, true, names)
	vim.api.nvim_set_option_value("modifiable", false, { scope = "local", buf = list_buf })

	local def_buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_set_option_value("buftype", "nofile", { scope = "local", buf = def_buf })
	vim.api.nvim_set_option_value("bufhidden", "hide", { scope = "local", buf = def_buf })
	vim.api.nvim_set_option_value("swapfile", false, { scope = "local", buf = def_buf })
	vim.api.nvim_set_option_value("undolevels", -1, { scope = "local", buf = def_buf })
	vim.api.nvim_set_option_value("filetype", "markdown", { scope = "local", buf = def_buf })

	_suggest_state = {
		list_buf = list_buf,
		def_buf = def_buf,
		entries = entries,
		selected = 1,
		word = word,
	}

	local nc = vim.o.columns
	local nr = vim.o.lines
	local total_width = M.opts.window.width or 120
	if total_width > nc - 4 then
		total_width = nc - 4
	end
	local list_width = M.opts.window.list_width or 30
	list_width = math.min(list_width, math.floor(total_width / 2))
	local def_width = total_width - list_width - 1

	local height = M.opts.window.height
	if not height then
		height = math.floor(nr * 0.85)
	end
	height = math.max(20, math.min(height, nr - 4))

	local col = math.floor((nc - total_width) / 2)
	local row = math.floor((nr - height) / 2) - 1

	local list_win = vim.api.nvim_open_win(list_buf, true, {
		relative = "editor",
		width = list_width,
		height = height,
		col = col,
		row = row,
		anchor = "NW",
		style = "minimal",
		border = "rounded",
		title = " Suggestions ",
		title_pos = "center",
	})
	vim.api.nvim_set_option_value("cursorline", true, { win = list_win })
	vim.api.nvim_set_option_value("number", false, { win = list_win })
	vim.api.nvim_set_option_value("relativenumber", false, { win = list_win })
	vim.api.nvim_set_option_value("wrap", false, { win = list_win })

	local def_win = vim.api.nvim_open_win(def_buf, false, {
		relative = "editor",
		width = def_width,
		height = height,
		col = col + list_width + 1,
		row = row,
		anchor = "NW",
		style = "minimal",
		border = "rounded",
		title = " " .. word .. " ",
		title_pos = "center",
	})
	vim.api.nvim_set_option_value("conceallevel", 2, { win = def_win })
	vim.api.nvim_set_option_value("wrap", true, { win = def_win })

	_suggest_state.list_win = list_win
	_suggest_state.def_win = def_win

	define_list_highlights()

	-- List window keymaps
	vim.keymap.set("n", "q", M.close, { silent = true, buffer = list_buf })
	vim.keymap.set("n", "<Esc>", M.close, { silent = true, buffer = list_buf })
	vim.keymap.set("n", "j", function()
		cycle_suggestion(1)
	end, { silent = true, buffer = list_buf })
	vim.keymap.set("n", "k", function()
		cycle_suggestion(-1)
	end, { silent = true, buffer = list_buf })
	vim.keymap.set("n", "<Tab>", function()
		cycle_suggestion(1)
	end, { silent = true, buffer = list_buf })
	vim.keymap.set("n", "<S-Tab>", function()
		cycle_suggestion(-1)
	end, { silent = true, buffer = list_buf })
	vim.keymap.set("n", "<Enter>", select_suggestion_and_replace, { silent = true, buffer = list_buf })
	vim.keymap.set("n", "<2-LeftMouse>", select_suggestion_and_replace, { silent = true, buffer = list_buf })

	-- Scroll the right definition pane without leaving the suggestion list.
	vim.keymap.set("n", "<C-e>", function()
		scroll_definition_lines(1)
	end, { silent = true, buffer = list_buf })
	vim.keymap.set("n", "<C-y>", function()
		scroll_definition_lines(-1)
	end, { silent = true, buffer = list_buf })
	vim.keymap.set("n", "<C-d>", function()
		scroll_definition_page(0.5)
	end, { silent = true, buffer = list_buf })
	vim.keymap.set("n", "<C-u>", function()
		scroll_definition_page(-0.5)
	end, { silent = true, buffer = list_buf })
	vim.keymap.set("n", "<C-f>", function()
		scroll_definition_page(1.0)
	end, { silent = true, buffer = list_buf })
	vim.keymap.set("n", "<C-b>", function()
		scroll_definition_page(-1.0)
	end, { silent = true, buffer = list_buf })

	-- Definition window keymaps
	vim.keymap.set("n", "q", M.close, { silent = true, buffer = def_buf })
	vim.keymap.set("n", "<Esc>", M.close, { silent = true, buffer = def_buf })

	-- Update preview when the cursor moves in the suggestion list (mouse click, j/k, etc.).
	vim.api.nvim_create_autocmd("CursorMoved", {
		buffer = list_buf,
		callback = function()
			local state = _suggest_state
			if not state then
				return
			end
			local row = vim.api.nvim_win_get_cursor(state.list_win)[1]
			if row ~= state.selected then
				render_suggestion_entry(row)
			end
		end,
	})

	render_suggestion_entry(1)

	-- Close the pair together when either window is closed.
	for _, win in ipairs({ list_win, def_win }) do
		vim.api.nvim_create_autocmd("WinClosed", {
			pattern = tostring(win),
			once = true,
			callback = function()
				M.close()
			end,
		})
	end
end

--- Collect prefix suggestions across all ready dictionaries.
--- @param word string
--- @return string[] suggestions
local function suggest_words(word)
	local per_dict = {}
	for _, d in ipairs(_dicts) do
		if d.status == "ready" then
			per_dict[#per_dict + 1] = dict.prefix_search(d, word, M.opts.max_items)
		end
	end

	local seen = { [word:lower()] = true }
	local out = {}
	local i = 1
	local added = true
	while added and #out < M.opts.max_items do
		added = false
		for _, words in ipairs(per_dict) do
			local w = words[i]
			if w then
				added = true
				local key = w:lower()
				if not seen[key] then
					seen[key] = true
					table.insert(out, w)
					if #out >= M.opts.max_items then
						break
					end
				end
			end
		end
		i = i + 1
	end
	return out
end

--- Look up a word and show the definition in a floating window.
--- @param word? string Word to look up; defaults to the word under the cursor.
function M.lookup(word)
	if not all_loaded() then
		warn("Dictionaries are still loading; please retry in a moment.")
		return
	end

	if not word then
		word = get_cword()
		if not word then
			return
		end
	end

	local entries = {}
	for _, d in ipairs(_dicts) do
		if d.status == "ready" then
			local data = dict.get_definition(d, word)
			if data then
				local md, spans = format.to_markdown(data, d.sametypesequence, {
					ansi_colors = M.opts.ansi_colors,
				})
				table.insert(entries, { name = d.name, definition = md, spans = spans })
			end
		end
	end

	if #entries == 0 then
		_origin_win = vim.api.nvim_get_current_win()
		_origin_word = word
		local suggestions = suggest_words(word)
		if #suggestions == 0 then
			local lines = { "# " .. word, "", "No definitions found." }
			open_combined_float(lines, nil)
		else
			open_suggestion_split_view(suggestions, word)
		end
		return
	end

	if M.opts.display_mode == "split" and #entries > 1 then
		open_split_view(entries, word)
	else
		_origin_win = vim.api.nvim_get_current_win()
		_origin_word = word
		local text, spans = format.combine(entries)
		local lines = vim.split(text, "\n", { plain = true })
		open_combined_float(lines, spans)
	end
end

--- Setup stardict.nvim.
--- @param config? StardictUserOpts
function M.setup(config)
	if config then
		M.opts = vim.tbl_deep_extend("force", M.opts, config)
	end

	local dirs = M.opts.dict_dirs or { "~/.stardict/dic", "/usr/share/stardict/dic" }
	_dicts = dict.discover(dirs, {
		include = M.opts.include_dictionaries,
		exclude = M.opts.exclude_dictionaries,
	})

	sort_dicts(_dicts, M.opts.dictionary_order)

	if #_dicts == 0 then
		warn("No StarDict dictionaries found in " .. table.concat(dirs, ", "))
		return
	end

	local remaining = #_dicts
	for _, d in ipairs(_dicts) do
		dict.load_async(d, function()
			remaining = remaining - 1
			if remaining == 0 then
				notify("Loaded " .. #_dicts .. " dictionary(s).")
			end
		end)
	end
end

return M
