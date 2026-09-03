--!nonstrict
-- nix-flake-update / service.luau
--
-- Read-only update checker for flake-based NixOS configurations.
--
-- Strategy:
--   1. Detect the user's flake directory (user setting → common path scan).
--   2. Write a Python 3 helper script to the plugin data dir once.
--   3. Periodically spawn the helper as a background process; it copies
--      flake.nix + flake.lock into a temp dir, runs `nix flake update`,
--      diffs the lock files, and writes JSON result data.
--   4. Poll the result file in the 1-second update() tick; parse it and
--      update shared state consumed by the widget and panel.
--   5. Never modify the real flake.lock or trigger a rebuild.

noctalia.setUpdateInterval(1000)

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

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

local function killWithPidFile(path)
	if noctalia.fileExists(path) then
		local raw = noctalia.readFile(path) or ""
		local pid = noctalia.string.trim(raw)
		if type(pid) == "string" and pid ~= "" then
			noctalia.runAsync(`pkill -9 -P {pid} 2>/dev/null; kill -9 {pid} 2>/dev/null`)
		end
		noctalia.removeFile(path)
	end
end

-- ---------------------------------------------------------------------------
-- Paths
-- ---------------------------------------------------------------------------

local stateDir   = noctalia.pluginDataDir() or "/tmp/nix-flake-update"
local resultFile = stateDir .. "/result.json"
local pidFile    = stateDir .. "/check.pid"
local scriptFile = stateDir .. "/check_flake.py"

-- ---------------------------------------------------------------------------
-- The Python 3 check script (written once at startup)
-- Uses only stdlib: json, os, shutil, subprocess, sys, tempfile
-- It runs `nix flake update` in a temp copy so the real flake.lock stays untouched.
-- ---------------------------------------------------------------------------

local PYTHON_SCRIPT = [==[
#!/usr/bin/env python3
"""
Check for flake input updates by running `nix flake update` on a temporary
copy of flake.nix + flake.lock, then diffing the two lock files.

The real flake.lock is never modified.
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile


def _parse_inputs(lock):
    """Return {input_name: node} for all root-level inputs."""
    nodes    = lock.get("nodes", {})
    root_key = lock.get("root", "root")
    root_inputs = nodes.get(root_key, {}).get("inputs", {})
    result = {}
    for name, ref in root_inputs.items():
        if isinstance(ref, str):
            key = ref
        elif isinstance(ref, list):
            key = ref[-1] if ref else name
        else:
            key = name
        node = nodes.get(key)
        if node:
            result[name] = node
    return result


def main():
    if len(sys.argv) < 2:
        print(json.dumps({"error": "No flake path provided", "inputs": [], "total_updates": 0}))
        sys.exit(1)

    flake_path = sys.argv[1]
    lock_path  = os.path.join(flake_path, "flake.lock")
    flake_nix  = os.path.join(flake_path, "flake.nix")

    for path in (lock_path, flake_nix):
        if not os.path.isfile(path):
            print(json.dumps({"error": path + " not found", "inputs": [], "total_updates": 0}))
            sys.exit(1)

    try:
        with open(lock_path) as fh:
            old_lock = json.load(fh)
    except Exception as exc:
        print(json.dumps({"error": "Cannot parse flake.lock: " + str(exc), "inputs": [], "total_updates": 0}))
        sys.exit(1)

    tmpdir = tempfile.mkdtemp(prefix="nix-flake-update-check-")
    try:
        shutil.copy2(flake_nix,  os.path.join(tmpdir, "flake.nix"))
        shutil.copy2(lock_path,  os.path.join(tmpdir, "flake.lock"))

        proc = subprocess.run(
            ["nix", "flake", "update"],
            cwd=tmpdir,
            capture_output=True,
            text=True,
            timeout=600,
        )

        if proc.returncode != 0:
            err = (proc.stderr or proc.stdout or "unknown error").strip()
            # Truncate to avoid huge JSON
            print(json.dumps({"error": "nix flake update failed: " + err[:400],
                              "inputs": [], "total_updates": 0}))
            return

        with open(os.path.join(tmpdir, "flake.lock")) as fh:
            new_lock = json.load(fh)

    finally:
        shutil.rmtree(tmpdir, ignore_errors=True)

    old_inputs = _parse_inputs(old_lock)
    new_inputs = _parse_inputs(new_lock)

    results = []
    for name, old_node in old_inputs.items():
        old_locked   = old_node.get("locked", {})
        new_node     = new_inputs.get(name, {})
        new_locked   = new_node.get("locked", {})
        input_type   = old_locked.get("type") or old_node.get("original", {}).get("type", "")
        old_rev      = old_locked.get("rev", "")
        new_rev      = new_locked.get("rev", "")

        if input_type == "path":
            status = "local"
        elif not old_rev and not new_rev:
            status = "unknown"
        elif old_rev == new_rev:
            status = "up_to_date"
        else:
            status = "update"

        results.append({
            "name":       name,
            "locked_rev": old_rev[:7] if old_rev else "",
            "new_rev":    new_rev[:7] if new_rev else "",
            "status":     status,
            "type":       input_type,
        })

    results.sort(key=lambda x: x["name"])
    total_updates = sum(1 for r in results if r["status"] == "update")

    print(json.dumps({
        "error":         None,
        "inputs":        results,
        "total_updates": total_updates,
    }))


main()
]==]

-- ---------------------------------------------------------------------------
-- State initialisation
-- ---------------------------------------------------------------------------

setState("isChecking",        false)
setState("lastCheckTime",     0)
setState("lastCheckTimeStr",  "never")
setState("flakePath",         "")
setState("flakeFound",        false)
setState("inputs",            "[]")
setState("totalUpdates",      0)
setState("anyUpdates",        false)
setState("error",             "")
setState("checkStartTime",    0)
setState("command",           "")

noctalia.mkdirAll(stateDir)
noctalia.writeFile(scriptFile, PYTHON_SCRIPT)

-- ---------------------------------------------------------------------------
-- Flake path detection
-- ---------------------------------------------------------------------------

local function detectFlakePath()
	-- 1. User-configured path takes priority
	local configured = cfg("flake_path")
	if type(configured) == "string" and configured ~= "" then
		if noctalia.fileExists(configured .. "/flake.lock") then
			return configured
		end
		-- Configured but not found → don't fall through to common paths,
		-- so the user gets a clear error rather than silently using another dir.
		return nil
	end

	-- 2. Scan common locations
	local home = os.getenv("HOME") or ""
	local candidates = {
		home .. "/.config/nixos",
		home .. "/nixos",
		home .. "/.dotfiles",
		home .. "/dotfiles",
		"/etc/nixos",
	}

	for _, candidate in ipairs(candidates) do
		if candidate ~= "/flake.lock" and noctalia.fileExists(candidate .. "/flake.lock") then
			return candidate
		end
	end

	return nil
end

-- ---------------------------------------------------------------------------
-- Update check lifecycle
-- ---------------------------------------------------------------------------

local function startCheck()
	if getState("isChecking") then
		return
	end

	local flakePath = getState("flakePath")
	if not getState("flakeFound") or flakePath == "" then
		-- Re-attempt detection (user may have changed setting)
		local path = detectFlakePath()
		if path then
			setState("flakePath", path)
			setState("flakeFound", true)
			flakePath = path
		else
			local configured = cfg("flake_path")
			if type(configured) == "string" and configured ~= "" then
				setState("error", tr("error.flake_path_not_found") .. ": " .. configured)
			else
				setState("error", tr("error.no_flake_detected"))
			end
			return
		end
	end

	setState("isChecking",     true)
	setState("checkStartTime", os.time())
	setState("error",          "")

	if cfg("show_check_notification") then
		noctalia.notify(tr("notification.checking"))
	end

	-- Clear the result file, then spawn the Python script in the background.
	-- The PID is captured so we can kill it on timeout or exit.
	noctalia.writeFile(resultFile, "")
	noctalia.runAsync(`python3 {scriptFile} {flakePath} > {resultFile} 2>&1 & echo $! > {pidFile}`)
end

local function cancelCheck()
	setState("isChecking", false)
	killWithPidFile(pidFile)
end

local function pollCheckResult()
	if not getState("isChecking") then
		return
	end

	-- Timeout guard
	local timeout = cfg("update_check_timeout") or 10
	if (os.time() - (getState("checkStartTime") or 0)) > 60 * timeout then
		cancelCheck()
		setState("error", tr("error.check_timed_out"))
		return
	end

	local raw = noctalia.readFile(resultFile) or ""
	raw = noctalia.string.trim(raw)
	if raw == "" then
		return
	end

	-- Try to parse; the file may still be partially written.
	local ok, result = pcall(function()
		return noctalia.json.decode(raw)
	end)

	if not ok or type(result) ~= "table" then
		return
	end

	-- We have a complete, valid result.
	setState("isChecking",       false)
	setState("lastCheckTime",    os.time())
	setState("lastCheckTimeStr", noctalia.formatTime("%Y-%m-%d %H:%M:%S"))

	if result.error and result.error ~= noctalia.json.null then
		setState("error",        tostring(result.error))
		setState("inputs",       "[]")
		setState("totalUpdates", 0)
		setState("anyUpdates",   false)
	else
		local inputs = result.inputs or {}
		setState("error",        "")
		setState("inputs",       noctalia.json.encode(inputs))
		setState("totalUpdates", result.total_updates or 0)
		setState("anyUpdates",   (result.total_updates or 0) > 0)

		if getState("anyUpdates") and cfg("show_update_notification") then
			local count = tostring(result.total_updates or 0)
			noctalia.notify(count .. " " .. tr("notification.updates_available"))
		end
	end

	if cfg("show_check_notification") then
		noctalia.notify(tr("notification.check_complete"))
	end

	noctalia.removeFile(pidFile)
end

-- ---------------------------------------------------------------------------
-- One-time initialisation
-- ---------------------------------------------------------------------------

local initialized = false

local function initialize()
	if initialized then
		return
	end
	initialized = true

	local path = detectFlakePath()
	if path then
		setState("flakePath",  path)
		setState("flakeFound", true)
	else
		setState("flakeFound", false)
		local configured = cfg("flake_path")
		if type(configured) == "string" and configured ~= "" then
			setState("error", tr("error.flake_path_not_found") .. ": " .. configured)
		else
			setState("error", tr("error.no_flake_detected"))
		end
	end

	-- Kick off the first check after a brief startup delay
	-- so the bar isn't blank for too long on login.
	startCheck()
end

-- ---------------------------------------------------------------------------
-- Command watcher (panel → service requests)
-- ---------------------------------------------------------------------------

watchState("command", function(command)
	if command == "check" then
		cancelCheck()
		startCheck()
		setState("command", "")
	elseif command == "cancel" then
		cancelCheck()
		setState("command", "")
	end
end)

-- ---------------------------------------------------------------------------
-- Main update loop (called every 1 s by the runtime)
-- ---------------------------------------------------------------------------

function update()
	initialize()

	-- Poll for an in-flight check's result
	if getState("isChecking") then
		pollCheckResult()
	end

	-- Periodic automatic re-check
	local interval  = cfg("update_check_interval") or 60
	local lastCheck = getState("lastCheckTime") or 0

	if not getState("isChecking")
		and lastCheck > 0
		and (os.time() - lastCheck) >= 60 * interval
	then
		startCheck()
	end
end

-- ---------------------------------------------------------------------------
-- Shutdown
-- ---------------------------------------------------------------------------

function onExit(_signal)
	cancelCheck()
end
