--!nonstrict
-- nix-flake-update / widget.luau
-- Bar widget showing the current flake update status at a glance.

local function cfg(key)
	return noctalia.getConfig(key)
end

local function tr(key)
	return noctalia.tr(key)
end

local function getState(key)
	return noctalia.state.get(key)
end

local function display(glyph, text, color)
	local _color = color or "on_surface"

	if cfg("colorize_glyph") then
		barWidget.setGlyphColor(_color)
	end

	if cfg("colorize_text") then
		barWidget.setColor(_color)
	end

	if cfg("show_glyph") then
		barWidget.setGlyph(glyph)
	end

	if cfg("show_text") then
		barWidget.setText(text)
	end
end

function update()
	if not getState("flakeFound") and getState("lastCheckTime") == 0 then
		-- Still initialising or no flake detected yet
		display(cfg("unknown_glyph"), tr("bar.unknown"), cfg("unknown_color"))
		return
	end

	if getState("isChecking") then
		display(cfg("checking_glyph"), tr("bar.checking"), cfg("checking_color"))
		return
	end

	local anyUpdates   = getState("anyUpdates")
	local totalUpdates = getState("totalUpdates") or 0

	if anyUpdates then
		local label = tostring(totalUpdates) .. " " .. tr("bar.updates")
		display(cfg("update_available_glyph"), label, cfg("update_available_color"))
	else
		local err = getState("error") or ""
		if err ~= "" then
			display(cfg("unknown_glyph"), tr("bar.unknown"), cfg("unknown_color"))
		else
			display(cfg("up_to_date_glyph"), tr("bar.up_to_date"), cfg("up_to_date_color"))
		end
	end
end

function onClick()
	noctalia.togglePanel("mdusome/nix-flake-update:panel")
end
