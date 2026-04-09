--- @sync entry

-- State: nil when inactive.
-- { pane=1|2, view="dual"|"zoom", tabs={tab1_idx, tab2_idx}, preview=bool }
-- All indices are 1-based (matching cx.tabs indexing).
local dp = nil
local saved = {} -- original Tab.layout / Tab.build / Header.cwd / Tabs.height

-- Derive the active pane from the real Yazi tab index.
-- Returns 1 if pane 1 is currently focused, 2 otherwise.
local function active_pane()
	return cx.tabs.idx == dp.tabs[2] and 2 or 1
end

local function other_pane()
	return active_pane() == 1 and 2 or 1
end

-- Helper component that renders arbitrary renderable elements as a child of Tab.
-- Must have _id (ui.redraw reads it unconditionally) and _area.
local Overlay = {}
function Overlay:new(id, area, elements)
	return setmetatable({ _id = id, _area = area, _elements = elements or {} }, { __index = self })
end
function Overlay:reflow() return {} end
function Overlay:redraw() return self._elements end

-- Marker has no reflow() method; add one so Tab:reflow() doesn't error on resize.
if not Marker.reflow then
	Marker.reflow = function() return {} end
end

local function apply_dual_tab_patch()
	Tab.layout = function(self)
		-- Enforce 2-tab minimum: create a companion tab if we have only one.
		if #cx.tabs < 2 and not dp.creating then
			dp.creating = true
			ya.emit("tab_create", { cx.active.current.cwd })
			dp.tabs = { 1, 2 }
		elseif #cx.tabs >= 2 then
			dp.creating = nil
		end

		-- Enforce 2-tab limit: close any tab not belonging to our two panes.
		if #cx.tabs > 2 then
			for i = #cx.tabs, 1, -1 do
				if i ~= dp.tabs[1] and i ~= dp.tabs[2] then
					ya.emit("tab_close", { i - 1 }) -- 0-based
					break -- close one per frame; next frame handles any remaining
				end
			end
		end

		-- Keep dp.pane in sync with the real active tab.
		local pane = active_pane()
		dp.pane = pane

		-- When preview is active, split vertically first: top for panes, bottom for preview.
		local pane_area = self._area
		if dp.preview then
			local vsplit = ui.Layout()
				:direction(ui.Layout.VERTICAL)
				:constraints({
					ui.Constraint.Fill(1),
					ui.Constraint.Fill(1),
				})
				:split(self._area)
			pane_area = vsplit[1]
			dp.preview_area = vsplit[2]
		else
			dp.preview_area = nil
		end

		if pane == 1 then
			-- Pane 1 active: hide parent, split current(fill)/preview(fill)
			self._chunks = ui.Layout()
				:direction(ui.Layout.HORIZONTAL)
				:constraints({
					ui.Constraint.Length(0),
					ui.Constraint.Fill(1),
					ui.Constraint.Fill(1),
				})
				:split(pane_area)
		else
			-- Pane 2 active: split parent(fill)/current(fill), hide preview
			self._chunks = ui.Layout()
				:direction(ui.Layout.HORIZONTAL)
				:constraints({
					ui.Constraint.Fill(1),
					ui.Constraint.Fill(1),
					ui.Constraint.Length(0),
				})
				:split(pane_area)
		end
	end

	Tab.build = function(self)
		-- Call the saved build first (may be full-border or the stock build).
		-- This draws any borders/base elements and pads self._chunks.
		-- When preview panel is active, temporarily shrink self._area to the
		-- pane region so borders don't bleed into the preview area below.
		local orig_area = self._area
		if dp.preview and dp.preview_area then
			local pa = dp.preview_area
			self._area = ui.Rect {
				x = orig_area.x, y = orig_area.y,
				w = orig_area.w, h = pa.y - orig_area.y,
			}
		end
		saved.tab_build(self)
		self._area = orig_area

		local c = self._chunks -- use (possibly padded) chunks from the above call
		local tab1 = cx.tabs[dp.tabs[1]]
		local tab2 = cx.tabs[dp.tabs[2]]

		-- Guard: second tab might not exist yet right after tab_create.
		if not tab1 or not tab2 then
			self._children = {}
			return
		end

		-- Replace whatever children were created by the saved build.
		-- Apply the same per-slot inset padding the stock Tab.build would use:
		--   parent slot → Pad.x(1),  current slot → none,  preview slot → Pad.x(1)
		-- This keeps content inside the borders drawn by full-border (or similar).
		if dp.pane == 1 then
			-- tab1 active → "current" slot (no extra padding).
			-- tab2 inactive → "preview" slot (Pad.x(1) + no cursor highlight).
			self._children = {
				Current:new(c[2], tab1),
				Current:new(c[3]:pad(ui.Pad.x(1)), tab2),
				Marker:new(c[2], tab1.current),
				Marker:new(c[3]:pad(ui.Pad.x(1)), tab2.current),
			}
		else
			-- tab1 inactive → "parent" slot (Pad.x(1) + no cursor highlight).
			-- tab2 active → "current" slot (no extra padding).
			self._children = {
				Current:new(c[1]:pad(ui.Pad.x(1)), tab1),
				Current:new(c[2], tab2),
				Marker:new(c[1]:pad(ui.Pad.x(1)), tab1.current),
				Marker:new(c[2], tab2.current),
			}
		end

		if dp.preview and dp.preview_area then
			-- Full-width preview panel at the bottom with a border.
			local pa = dp.preview_area
			self._children[#self._children + 1] = Overlay:new("border", pa, {
				ui.Border(ui.Edge.ALL):area(pa),
			})
			self._children[#self._children + 1] = Preview:new(pa:pad(ui.Pad(1, 1, 1, 1)), self._tab)
		else
			-- Set LAYOUT.preview to a zero-width rect so the Rust mgr::Preview
			-- widget won't render stale peek content from a previously closed panel.
			-- Height must stay non-zero because Folder::make uses it for window size.
			self._children[#self._children + 1] = Overlay:new("preview",
				ui.Rect { x = 0, y = 0, w = 0, h = self._area.h }, {})
		end
	end
end

local function apply_header_patch()
	Header.cwd = function(self)
		local w = self._area.w
		local mid = math.floor(w / 2) - 1

		local tab1 = cx.tabs[dp.tabs[1]]
		local tab2 = dp.tabs[2] and cx.tabs[dp.tabs[2]]
		local pane = dp.pane or 1

		if not tab1 then
			return ""
		end

		-- Only one pane ready yet.
		if not tab2 then
			local s = ya.readable_path(tostring(tab1.current.cwd))
			return ui.Span(ui.truncate(s, { max = w, rtl = true })):style(th.tabs.active)
		end

		-- Left path: truncate to `mid`, then space-pad to exactly `mid` columns
		-- so the " " separator always lands at the pane split point.
		local p1 = ya.readable_path(tostring(tab1.current.cwd))
		p1 = ui.truncate(p1, { max = mid, rtl = true })
		local pad = mid - #p1
		if pad > 0 then
			p1 = p1 .. string.rep(" ", pad)
		end

		-- Right path: space from mid+1 to right edge, minus the right widget.
		local right_avail = math.max(0, w - mid - 1 - (self._right_width or 0)) - 4
		local p2 = ya.readable_path(tostring(tab2.current.cwd))
		p2 = ui.truncate(p2, { max = right_avail, rtl = true })

		-- Active path uses the full active style (background highlight).
		-- Inactive path uses the inactive foreground only, background reset to transparent.
		local s_active   = th.tabs.active:patch(ui.Style():bg("reset"))
		local s_inactive = th.tabs.inactive:patch(ui.Style():bg("reset"))

		return ui.Line {
			ui.Span(p1):style(pane == 1 and s_active or s_inactive),
			ui.Span(" "),
			ui.Span(p2):style(pane == 2 and s_active or s_inactive),
		}
	end
end

local function restore_all()
	Tab.layout  = saved.tab_layout
	Tab.build   = saved.tab_build
	Header.cwd  = saved.header_cwd
	Tabs.height = saved.tabs_height
end

local function activate()
	if dp then
		return
	end

	-- Persist original methods before patching.
	saved.tab_layout  = Tab.layout
	saved.tab_build   = Tab.build
	saved.header_cwd  = Header.cwd
	saved.tabs_height = Tabs.height

	-- Hide the tab bar while dual-pane is active.
	Tabs.height = function() return 0 end

	local n = #cx.tabs
	local cur = cx.tabs.idx -- 1-based
	local tab2_idx

	if n >= 2 then
		-- Use the next tab (wraps to 1 if on the last tab).
		tab2_idx = (cur < n) and (cur + 1) or 1
	else
		-- Create a companion tab at the same directory.
		tab2_idx = 2
		ya.emit("tab_create", { cx.active.current.cwd })
	end

	dp = { pane = 1, view = "dual", tabs = { cur, tab2_idx }, creating = n < 2, preview = false }

	apply_dual_tab_patch()
	apply_header_patch()
	ui.render()
end

local function deactivate()
	if not dp then
		return
	end
	ya.emit("tab_close", { other_pane() - 1 })
	restore_all()
	dp = nil
	saved = {}
	ui.render()
end

local function spl_toggle()
	if dp then
		deactivate()
	else
		activate()
	end
end

local function spl_preview()
	if not dp then
		return
	end
	dp.preview = not dp.preview
	ui.render()
	if dp.preview then
		-- Force-trigger the peek system for the current file since
		-- it only auto-triggers on file change, not on area change.
		ya.emit("peek", { 0 })
	end
end

local function spl_switch_tab()
	if not dp then
		return
	end
	local op = other_pane()
	ya.emit("tab_switch", { dp.tabs[op] - 1 })
	ui.render()
end

local function entry(st, job)
	job = type(job) == "string" and { args = { job } } or job
	local act = job.args[1]
	local args = {}
	for i = 2, #job.args do
		args[#args + 1] = job.args[i]
	end

	if act == "spl_toggle" then
		spl_toggle()
	elseif act == "spl_switch_tab" then
		spl_switch_tab()
	elseif act == "spl_preview" then
		spl_preview()
	end
end

return { entry = entry }
