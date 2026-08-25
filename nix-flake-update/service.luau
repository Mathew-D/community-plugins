--!nonstrict
-- nix-flake-update / service.luau
--
-- Read-only update checker for flake-based NixOS configurations.
--
-- Strategy:
--   1. Detect the user's flake directory (user setting → common path scan).
--   2. Write a Python 3 helper script to the plugin data dir once.
--   3. Periodically spawn the helper as a background process; it reads
--      flake.lock (pure JSON, no nix invocation needed), then runs
--      `git ls-remote` for every git-backed input in parallel and writes
--      a JSON result file.
--   4. Poll the result file in the 1-second update() tick; parse it and
--      update shared state consumed by the widget and panel.
--   5. Never run nix flake update / nixos-rebuild / home-manager switch.

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

local stateDir    = noctalia.pluginDataDir() or "/tmp/nix-flake-update"
local resultFile  = stateDir .. "/result.json"
local pidFile     = stateDir .. "/check.pid"
local scriptFile  = stateDir .. "/check_flake.py"

-- ---------------------------------------------------------------------------
-- The Python 3 check script (written once at startup)
-- Uses only stdlib: json, subprocess, os, sys, concurrent.futures
-- No nix invocations; reads flake.lock directly, queries remotes via git.
-- ---------------------------------------------------------------------------

local PYTHON_SCRIPT = [==[
#!/usr/bin/env python3
"""
Read flake.lock and check whether any flake input has a newer revision
available on its remote. Outputs a single JSON object to stdout.

Never modifies flake.lock or runs nix flake update.
"""
import json
import os
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor, as_completed

GIT_TIMEOUT  = 30   # seconds per git ls-remote call
HTTP_TIMEOUT = 10   # seconds for GitHub compare API call
MAX_WORKERS  = 8    # parallel git ls-remote calls


def _github_commit_count(owner, repo, base, head):
    """
    Return the number of commits `head` is ahead of `base` on GitHub,
    using the public compare API (no auth required for public repos).
    Returns None on any failure.
    """
    import urllib.request
    import urllib.error

    url = "https://api.github.com/repos/{}/{}/compare/{}...{}".format(
        owner, repo, base, head
    )
    req = urllib.request.Request(url, headers={"Accept": "application/vnd.github+json",
                                               "User-Agent": "nix-flake-update-plugin"})
    try:
        with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT) as resp:
            data = json.loads(resp.read().decode())
            return data.get("ahead_by")
    except Exception:
        return None


def _git_ls_remote(url, ref):
    """Return the full SHA at the tip of `ref` on `url`, or None on failure."""
    # Try the exact ref, then refs/heads/<ref>, then refs/tags/<ref>
    candidates = [ref]
    if ref and not ref.startswith("refs/"):
        candidates += ["refs/heads/" + ref, "refs/tags/" + ref]

    for candidate in candidates:
        try:
            proc = subprocess.run(
                ["git", "ls-remote", "--exit-code", url, candidate],
                capture_output=True,
                text=True,
                timeout=GIT_TIMEOUT,
            )
            if proc.returncode == 0 and proc.stdout.strip():
                lines = [
                    l for l in proc.stdout.strip().splitlines()
                    if "\t" in l
                ]
                if lines:
                    return lines[0].split("\t")[0].strip()
        except subprocess.TimeoutExpired:
            return None
        except Exception:
            pass
    return None


def _check_input(input_name, node):
    """Return a dict describing the update status of one flake input."""
    locked   = node.get("locked", {})
    original = node.get("original", {})

    input_type  = locked.get("type") or original.get("type", "")
    locked_rev  = locked.get("rev", "")

    # ---- Inputs we cannot (or need not) check remotely -------------------
    if input_type == "path":
        return dict(name=input_name, locked_rev="", new_rev="",
                    status="local", type=input_type)
    if input_type == "tarball":
        return dict(name=input_name, locked_rev=locked_rev[:7] if locked_rev else "",
                    new_rev="", status="tarball", type=input_type)
    if input_type == "indirect":
        return dict(name=input_name, locked_rev=locked_rev[:7] if locked_rev else "",
                    new_rev="", status="indirect", type=input_type)

    # ---- Build remote URL and ref ----------------------------------------
    ref = original.get("ref") or locked.get("ref") or "HEAD"

    owner = None
    repo  = None

    if input_type == "github":
        owner = original.get("owner") or locked.get("owner", "")
        repo  = original.get("repo")  or locked.get("repo",  "")
        url   = "https://github.com/{}/{}".format(owner, repo)
    elif input_type == "gitlab":
        owner = original.get("owner") or locked.get("owner", "")
        repo  = original.get("repo")  or locked.get("repo",  "")
        host  = original.get("host")  or locked.get("host",  "gitlab.com")
        url   = "https://{}/{}/{}".format(host, owner, repo)
    elif input_type == "sourcehut":
        owner = original.get("owner") or locked.get("owner", "")
        repo  = original.get("repo")  or locked.get("repo",  "")
        url   = "https://git.sr.ht/{}/{}".format(owner, repo)
    elif input_type == "git":
        url = original.get("url") or locked.get("url", "")
    else:
        return dict(name=input_name, locked_rev=locked_rev[:7] if locked_rev else "",
                    new_rev="", commit_count=None, status="unsupported", type=input_type)

    if not url:
        return dict(name=input_name, locked_rev=locked_rev[:7] if locked_rev else "",
                    new_rev="", commit_count=None, status="error", type=input_type)

    # ---- Query remote -------------------------------------------------------
    new_rev = _git_ls_remote(url, ref)

    if new_rev is None:
        status       = "error"
        new_rev      = ""
        commit_count = None
    elif locked_rev and new_rev:
        if locked_rev == new_rev:
            status       = "up_to_date"
            commit_count = 0
        else:
            status = "update"
            # For GitHub inputs query the compare API to get the ahead-by count.
            commit_count = None
            if input_type == "github" and owner and repo and locked_rev and new_rev:
                commit_count = _github_commit_count(owner, repo, locked_rev, new_rev)
    else:
        status       = "unknown"
        commit_count = None

    return dict(
        name=input_name,
        locked_rev=locked_rev[:7] if locked_rev else "",
        new_rev=new_rev[:7]       if new_rev    else "",
        commit_count=commit_count,
        status=status,
        type=input_type,
    )


def main():
    if len(sys.argv) < 2:
        print(json.dumps({"error": "No flake path provided", "inputs": [], "total_updates": 0}))
        sys.exit(1)

    flake_path = sys.argv[1]
    lock_path  = os.path.join(flake_path, "flake.lock")

    if not os.path.isfile(lock_path):
        print(json.dumps({
            "error": "flake.lock not found at " + lock_path,
            "inputs": [],
            "total_updates": 0,
        }))
        sys.exit(1)

    try:
        with open(lock_path) as fh:
            lock = json.load(fh)
    except Exception as exc:
        print(json.dumps({
            "error": "Cannot parse flake.lock: " + str(exc),
            "inputs": [],
            "total_updates": 0,
        }))
        sys.exit(1)

    nodes    = lock.get("nodes", {})
    root_key = lock.get("root", "root")
    root_inputs = nodes.get(root_key, {}).get("inputs", {})

    # Resolve node references (may be a string alias, or a path-list)
    work = {}
    for input_name, node_ref in root_inputs.items():
        if isinstance(node_ref, str):
            actual = node_ref
        elif isinstance(node_ref, list):
            actual = node_ref[-1] if node_ref else input_name
        else:
            actual = input_name
        node = nodes.get(actual, {})
        if node:
            work[input_name] = node

    results = []
    with ThreadPoolExecutor(max_workers=MAX_WORKERS) as pool:
        future_map = {pool.submit(_check_input, name, node): name
                      for name, node in work.items()}
        for future in as_completed(future_map, timeout=120):
            try:
                results.append(future.result())
            except Exception:
                name = future_map[future]
                results.append(dict(name=name, locked_rev="", new_rev="",
                                    status="error", type="unknown"))

    results.sort(key=lambda x: x["name"])
    total_updates = sum(1 for r in results if r.get("status") == "update")

    print(json.dumps({
        "error": None,
        "inputs": results,
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
	local timeout = cfg("update_check_timeout") or 5
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
