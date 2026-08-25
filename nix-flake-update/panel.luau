--!nonstrict
-- nix-flake-update / panel.luau
-- Detailed panel showing per-input update status and controls.

local function cfg(key)
	return noctalia.getConfig(key)
end

local function tr(key)
	return noctalia.tr(key)
end

local function getState(key)
	return noctalia.state.get(key)
end

local function setState(key, val)
	noctalia.state.set(key, val)
end

local function watchState(key, cb)
	noctalia.state.watch(key, cb)
end

-- ---------------------------------------------------------------------------
-- UI helpers
-- ---------------------------------------------------------------------------

local function cardBg()
	local color   = cfg("panel_card_color")
	local opacity = cfg("panel_card_opacity") / 100
	return `{color}/{opacity}`
end

-- Status metadata
local STATUS_COLOR = {
	update      = "#ff5757",
	up_to_date  = "#57ff57",
	["local"]   = "on_surface_variant",
	tarball     = "on_surface_variant",
	indirect    = "on_surface_variant",
	unsupported = "on_surface_variant",
	error       = "#ff9900",
	timeout     = "#ff9900",
	unknown     = "on_surface_variant",
}

local STATUS_LABEL = {
	update      = "update",
	up_to_date  = "up to date",
	["local"]   = "local",
	tarball     = "tarball",
	indirect    = "indirect",
	unsupported = "n/a",
	error       = "error",
	timeout     = "timeout",
	unknown     = "?",
}

-- Dot glyphs signal status at a glance on the left edge
local STATUS_DOT = {
	update     = "point-filled",
	up_to_date = "point-filled",
	error      = "point-filled",
	timeout    = "point-filled",
}

-- Sort order: updates first, errors second, up-to-date third, others last
local STATUS_SORT = {
	update      = 1,
	error       = 2,
	timeout     = 2,
	up_to_date  = 3,
	unknown     = 4,
	["local"]   = 5,
	tarball     = 5,
	indirect    = 5,
	unsupported = 5,
}

local function sortInputs(inputs)
	local copy = {}
	for _, v in ipairs(inputs) do
		table.insert(copy, v)
	end
	table.sort(copy, function(a, b)
		local sa = STATUS_SORT[a.status or "unknown"] or 9
		local sb = STATUS_SORT[b.status or "unknown"] or 9
		if sa ~= sb then return sa < sb end
		return (a.name or "") < (b.name or "")
	end)
	return copy
end

-- Column-header row (muted labels, matches inputRow layout)
local function columnHeader()
	return ui.row({
		paddingV  = 2,
		paddingH  = 10,
		align     = "center",
		justify   = "space_between",
		gap       = 8,
	}, {
		-- spacer matching the dot glyph width
		ui.label({ text = " ", fontSize = 10, minWidth = 14 }),
		ui.label({
			text       = "INPUT",
			fontSize   = 10,
			fontWeight = "medium",
			color      = "on_surface_variant",
			flexGrow   = 1,
		}),
		ui.row({ gap = 18, align = "center" }, {
			ui.label({ text = "COMMITS",  fontSize = 10, fontWeight = "medium", color = "on_surface_variant", minWidth = 52 }),
			ui.label({ text = "REVISION", fontSize = 10, fontWeight = "medium", color = "on_surface_variant", minWidth = 90 }),
			ui.label({ text = "STATUS",   fontSize = 10, fontWeight = "medium", color = "on_surface_variant", minWidth = 60 }),
		}),
	})
end

-- One row per flake input
local function inputRow(inp)
	local name        = inp.name         or "?"
	local lockedRev   = inp.locked_rev   or ""
	local newRev      = inp.new_rev      or ""
	local status      = inp.status       or "unknown"
	local commitCount = inp.commit_count -- number or nil

	local statusColor = STATUS_COLOR[status]  or "on_surface_variant"
	local statusLabel = STATUS_LABEL[status]  or status

	-- Left dot indicator
	local dotGlyph = STATUS_DOT[status]
	local dotEl
	if dotGlyph then
		dotEl = ui.glyph({ name = dotGlyph, size = 8, color = statusColor, minWidth = 14 })
	else
		dotEl = ui.label({ text = " ", fontSize = 10, minWidth = 14 })
	end

	-- Revision text
	local revText
	if status == "update" and lockedRev ~= "" and newRev ~= "" then
		revText = lockedRev .. " → " .. newRev
	elseif lockedRev ~= "" then
		revText = lockedRev
	else
		revText = "—"
	end

	-- Commit count (only meaningful for GitHub inputs with a known count)
	local countEl
	if status == "update" and type(commitCount) == "number" and commitCount > 0 then
		countEl = ui.label({
			text      = "+" .. tostring(commitCount),
			fontSize  = 11,
			fontWeight = "semibold",
			color     = "#ffaa33",
			minWidth  = 52,
		})
	else
		countEl = ui.label({ text = "", fontSize = 11, minWidth = 52 })
	end

	return ui.row({
		fill     = cardBg(),
		radius   = 6,
		paddingV = 6,
		paddingH = 10,
		align    = "center",
		justify  = "space_between",
		gap      = 8,
	}, {
		dotEl,
		ui.label({
			text       = name,
			fontSize   = 13,
			fontWeight = "semibold",
			flexGrow   = 1,
		}),
		ui.row({ gap = 18, align = "center" }, {
			countEl,
			ui.label({
				text     = revText,
				fontSize = 11,
				color    = "on_surface_variant",
				minWidth = 90,
			}),
			ui.label({
				text       = statusLabel,
				fontSize   = 11,
				fontWeight = "bold",
				color      = statusColor,
				minWidth   = 60,
			}),
		}),
	})
end

-- Summary card with a glyph appropriate to the current state
local function summaryCard(isChecking, anyUpdates, totalUpdates, errMsg, flakeFound, inputCount)
	local glyph, glyphColor, text

	if isChecking then
		glyph      = "loader-3"
		glyphColor = "#ffeb57"
		text       = tr("panel.checking")
	elseif errMsg ~= "" then
		glyph      = "alert-circle"
		glyphColor = "#ff9900"
		text       = tr("panel.error") .. ": " .. errMsg
	elseif not flakeFound then
		glyph      = "file-unknown"
		glyphColor = "on_surface_variant"
		text       = tr("panel.no_flake")
	elseif anyUpdates then
		glyph      = "cloud-download"
		glyphColor = "#ff5757"
		text       = tostring(totalUpdates) .. " " .. tr("panel.inputs_have_updates")
	elseif inputCount > 0 then
		glyph      = "rosette-discount-check"
		glyphColor = "#57ff57"
		text       = tr("panel.all_up_to_date")
	else
		glyph      = "help-circle"
		glyphColor = "on_surface_variant"
		text       = tr("panel.no_data")
	end

	return ui.row({
		fill     = cardBg(),
		radius   = 8,
		paddingV = 8,
		paddingH = 12,
		align    = "center",
		gap      = 10,
	}, {
		ui.glyph({ name = glyph, size = 18, color = glyphColor }),
		ui.label({ text = text, fontSize = 13, fontWeight = "medium" }),
	})
end

-- ---------------------------------------------------------------------------
-- Render
-- ---------------------------------------------------------------------------

local function render()
	local isChecking   = getState("isChecking")
	local flakeFound   = getState("flakeFound")
	local flakePath    = getState("flakePath") or ""
	local lastChecked  = getState("lastCheckTimeStr") or tr("panel.never")
	local errMsg       = getState("error") or ""
	local totalUpdates = getState("totalUpdates") or 0
	local anyUpdates   = getState("anyUpdates")

	-- Parse the inputs JSON (may fail if the state is mid-update)
	local inputs = {}
	local rawInputs = getState("inputs") or "[]"
	local ok, decoded = pcall(function()
		return noctalia.json.decode(rawInputs)
	end)
	if ok and type(decoded) == "table" then
		inputs = decoded
	end

	-- ---- Header ----
	local children = {
		ui.row({
			align   = "center",
			justify = "space_between",
		}, {
			ui.column({ gap = 2 }, {
				ui.label({ text = tr("panel.title"), fontSize = 16, fontWeight = "bold" }),
				flakePath ~= "" and ui.label({
					text     = flakePath,
					fontSize = 11,
					color    = "on_surface_variant",
				}) or ui.label({ text = "" }),
			}),
		}),
		ui.separator({ thickness = 2, orientation = "horizontal", spacing = 4 }),

		-- Summary card
		summaryCard(isChecking, anyUpdates, totalUpdates, errMsg, flakeFound, #inputs),
		ui.separator({ thickness = 1, orientation = "horizontal", spacing = 2 }),
	}

	-- ---- Input rows (with header if we have data) ----
	local sorted = sortInputs(inputs)

	if #sorted > 0 then
		table.insert(children, columnHeader())
		for _, inp in ipairs(sorted) do
			table.insert(children, inputRow(inp))
		end
	elseif isChecking then
		-- First-ever check in progress — show a spinner-style label
		table.insert(children, ui.row({
			align   = "center",
			justify = "center",
			paddingV = 12,
		}, {
			ui.glyph({ name = "loader-3", size = 20, color = "#ffeb57" }),
			ui.label({ text = "  " .. tr("panel.checking"), fontSize = 12, color = "on_surface_variant" }),
		}))
	end

	-- ---- Footer ----
	table.insert(children, ui.separator({ thickness = 1, orientation = "horizontal", spacing = 2 }))
	table.insert(children, ui.row({
		align   = "center",
		justify = "space_between",
	}, {
		ui.label({
			text     = tr("panel.last_checked") .. ": " .. lastChecked,
			fontSize = 11,
			color    = "on_surface_variant",
		}),
		isChecking
			and ui.button({
				text    = tr("panel.cancel"),
				glyph   = "cancel",
				variant = "destructive",
				onClick = "onCancelClicked",
			})
			or ui.button({
				text    = tr("panel.check"),
				glyph   = "search",
				variant = "outline",
				onClick = "onCheckClicked",
			}),
	}))

	panel.render(ui.column({ gap = 6 }, children))
end

-- ---------------------------------------------------------------------------
-- State watchers → re-render on any relevant change
-- ---------------------------------------------------------------------------

watchState("isChecking",       render)
watchState("inputs",           render)
watchState("error",            render)
watchState("flakeFound",       render)
watchState("lastCheckTimeStr", render)
watchState("anyUpdates",       render)

-- ---------------------------------------------------------------------------
-- Hooks
-- ---------------------------------------------------------------------------

function onOpen(_ctx)
	render()
end

function update()
	render()
end

-- ---------------------------------------------------------------------------
-- Button handlers
-- ---------------------------------------------------------------------------

function onCheckClicked()
	setState("command", "check")
end

function onCancelClicked()
	setState("command", "cancel")
end
