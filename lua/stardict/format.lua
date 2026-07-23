--- Format raw dictionary definition data into Markdown for display.
--- Handles StarDict HTML (sametypesequence=h) and sdcv ANSI / plain text.
--- Adapted from blink-cmp-stardict for stardict.nvim.
--- @module stardict.format

local M = {}

--- Strip ANSI escape sequences (colors, styles)
--- @param s string
--- @return string
local function strip_ansi(s)
	return (s:gsub("\27%[[0-9;]*m", ""))
end

-- ── ANSI SGR → highlight spans ─────────────────────────────────

local ANSI_NS = nil

--- catppuccin-mocha-ish palette; groups use default=true so users can override
local ANSI_PALETTE = {
	"#45475a", -- 0 black
	"#f38ba8", -- 1 red
	"#a6e3a1", -- 2 green
	"#f9e2af", -- 3 yellow
	"#89b4fa", -- 4 blue
	"#f5c2e7", -- 5 magenta
	"#94e2d5", -- 6 cyan
	"#bac2de", -- 7 white
	"#585b70", -- 8 bright black
	"#f38ba8", -- 9 bright red
	"#a6e3a1", -- 10 bright green
	"#f9e2af", -- 11 bright yellow
	"#89b4fa", -- 12 bright blue
	"#f5c2e7", -- 13 bright magenta
	"#94e2d5", -- 14 bright cyan
	"#a6adc8", -- 15 bright white
}

local function define_ansi_highlights()
	if ANSI_NS then
		return
	end
	ANSI_NS = vim.api.nvim_create_namespace("stardict-ansi")
	for i = 0, 15 do
		vim.api.nvim_set_hl(0, "StardictAnsiFg" .. i, {
			fg = ANSI_PALETTE[i + 1],
			ctermfg = i,
			default = true,
		})
		vim.api.nvim_set_hl(0, "StardictAnsiBg" .. i, {
			bg = ANSI_PALETTE[i + 1],
			ctermbg = i,
			default = true,
		})
	end
	vim.api.nvim_set_hl(0, "StardictAnsiBold", { bold = true, default = true })
	vim.api.nvim_set_hl(0, "StardictAnsiItalic", { italic = true, default = true })
	vim.api.nvim_set_hl(0, "StardictAnsiUnderline", { underline = true, default = true })
	vim.api.nvim_set_hl(0, "StardictAnsiStrikethrough", { strikethrough = true, default = true })
end

--- @param style table
--- @return string[]? hl groups (nil when style is empty)
local function style_groups(style)
	local groups = {}
	if style.fg then
		groups[#groups + 1] = "StardictAnsiFg" .. style.fg
	end
	if style.bg then
		groups[#groups + 1] = "StardictAnsiBg" .. style.bg
	end
	if style.bold then
		groups[#groups + 1] = "StardictAnsiBold"
	end
	if style.italic then
		groups[#groups + 1] = "StardictAnsiItalic"
	end
	if style.underline then
		groups[#groups + 1] = "StardictAnsiUnderline"
	end
	if style.strike then
		groups[#groups + 1] = "StardictAnsiStrikethrough"
	end
	if #groups == 0 then
		return nil
	end
	return groups
end

--- Apply one SGR parameter list to the style state
local function apply_sgr(style, params)
	if params == "" then
		params = "0"
	end
	for param in params:gmatch("[^;]+") do
		local n = tonumber(param) or 0
		if n == 0 then
			for k in pairs(style) do
				style[k] = nil
			end
		elseif n == 1 then
			style.bold = true
		elseif n == 3 then
			style.italic = true
		elseif n == 4 then
			style.underline = true
		elseif n == 9 then
			style.strike = true
		elseif n == 22 then
			style.bold = nil
		elseif n == 23 then
			style.italic = nil
		elseif n == 24 then
			style.underline = nil
		elseif n == 29 then
			style.strike = nil
		elseif n >= 30 and n <= 37 then
			style.fg = n - 30
		elseif n == 39 then
			style.fg = nil
		elseif n >= 40 and n <= 47 then
			style.bg = n - 40
		elseif n == 49 then
			style.bg = nil
		elseif n >= 90 and n <= 97 then
			style.fg = n - 90 + 8
		elseif n >= 100 and n <= 107 then
			style.bg = n - 100 + 8
		end
	end
end

--- Split text with ANSI SGR codes into plain text and styled spans.
--- Span rows/cols are 0-based byte offsets into the returned plain text.
--- @param data string
--- @return string text, table[] spans { { row, col_start, col_end, groups } }
function M.extract_ansi(data)
	local out = {}
	local spans = {}
	local style = {}
	local row, col = 0, 0
	local pos = 1

	while true do
		local esc_start, esc_end, params = data:find("\27%[([0-9;]*)m", pos)
		local chunk_end = esc_start and (esc_start - 1) or #data
		if chunk_end >= pos then
			local chunk = data:sub(pos, chunk_end)
			out[#out + 1] = chunk
			local groups = style_groups(style)
			-- record the chunk as spans, split per line
			local line_start = 1
			while true do
				local nl = chunk:find("\n", line_start, true)
				local line_end = nl and (nl - 1) or #chunk
				if groups and line_end >= line_start then
					spans[#spans + 1] = {
						row = row,
						col_start = col,
						col_end = col + (line_end - line_start + 1),
						groups = groups,
					}
				end
				if not nl then
					col = col + (#chunk - line_start + 1)
					break
				end
				row = row + 1
				col = 0
				line_start = nl + 1
			end
		end
		if not esc_start then
			break
		end
		apply_sgr(style, params)
		pos = esc_end + 1
	end

	return table.concat(out), spans
end

--- Highlight a buffer from spans produced by extract_ansi.
--- @param bufnr integer
--- @param spans table[]
function M.apply_ansi_spans(bufnr, spans)
	define_ansi_highlights()
	vim.api.nvim_buf_clear_namespace(bufnr, ANSI_NS, 0, -1)
	for _, span in ipairs(spans) do
		pcall(vim.api.nvim_buf_set_extmark, bufnr, ANSI_NS, span.row, span.col_start, {
			end_col = span.col_end,
			hl_group = span.groups,
			priority = 200,
		})
	end
end

--- Convert a small subset of HTML tags to Markdown equivalents.
--- StarDict HTML is simple: <br>, <b>, <i>, <small>, <span>, <a>, <font>.
--- @param s string
--- @return string
local function html_to_markdown(s)
	-- <br> -> newline
	s = s:gsub("<br%s*/?>", "\n")
	-- <b>bold</b> -> **bold**
	s = s:gsub("<b>(.-)</b>", "**%1**")
	-- <i>italic</i> -> *italic*
	s = s:gsub("<i>(.-)</i>", "*%1*")
	-- <small> -> plain (keep text, no special formatting)
	s = s:gsub("<small>(.-)</small>", "%1")
	-- <span ...>text</span> -> text (keep inner text)
	s = s:gsub("<span[^>]*>(.-)</span>", "%1")
	-- <font ...>text</font> -> text
	s = s:gsub("<font[^>]*>(.-)</font>", "%1")
	-- <a href="...">text</a> -> text
	s = s:gsub('<a%s+href="[^"]*"[^>]*>(.-)</a>', "%1")
	-- strip any remaining tags
	s = s:gsub("<[^>]+>", "")
	-- collapse multiple newlines
	s = s:gsub("\n\n+", "\n\n")
	return s
end

--- Format a raw definition blob as Markdown.
--- @param data string raw bytes from .dict
--- @param sametypesequence? string e.g. "h", "m", "g"
--- @param opts table|nil { ansi_colors = boolean, html = boolean }
--- @return string markdown, table[]? spans
function M.to_markdown(data, sametypesequence, opts)
	opts = opts or {}
	local ansi_colors = opts.ansi_colors or false
	local html = opts.html
	if html == nil then
		html = sametypesequence == "h"
	end

	local s = data

	if html then
		s = html_to_markdown(s)
	end

	local spans = nil
	if ansi_colors then
		s, spans = M.extract_ansi(s)
	else
		s = strip_ansi(s)
	end

	-- Ensure hard line breaks so preformatted dictionary text keeps layout
	s = s:gsub("\n", "  \n")
	return s, spans
end

--- Format multiple dictionary definitions into one Markdown document.
--- Entries are grouped under `## <bookname>` headings.
--- Entries may carry highlight spans (from to_markdown with ansi_colors);
--- they are re-offset to their position in the combined document.
--- @param entries table[] { { name = string, definition = string, spans?: table[] } }
--- @return string text, table[]? spans
function M.combine(entries)
	local lines = {}
	local spans = nil
	local row_offset = 0
	for _, entry in ipairs(entries) do
		table.insert(lines, "## " .. entry.name)
		table.insert(lines, "")
		local def_lines = 1 + select(2, entry.definition:gsub("\n", ""))
		if entry.spans then
			spans = spans or {}
			for _, span in ipairs(entry.spans) do
				spans[#spans + 1] = {
					row = span.row + row_offset + 2,
					col_start = span.col_start,
					col_end = span.col_end,
					groups = span.groups,
				}
			end
		end
		table.insert(lines, entry.definition)
		table.insert(lines, "")
		row_offset = row_offset + 3 + def_lines
	end
	return table.concat(lines, "\n"), spans
end

return M
