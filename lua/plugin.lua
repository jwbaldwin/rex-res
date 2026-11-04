-- Rex restores sessions, layouts, labels, and directories on its own. This plugin
-- remembers which program ran in each terminal and types it back after a restart.
local plugin = {}
local terminal = "com.superlogical.terminal"
local default_programs = { "pi", "nvim", "opencode", "htop", "btop" }
local shells = { sh = true, bash = true, zsh = true, fish = true, dash = true, ksh = true, nu = true, login = true }
local format, version = "rex-res", 2

local function call(method, args)
	local result, err = rex.call(method, args)
	if not result then
		error(err, 0)
	end
	return result
end

local function block_call(method, pane, args)
	args = args or {}
	args.session_id, args.block_id = pane.session_id, pane.block_id
	local result, err = rex.block.call(terminal, method, args)
	if not result then
		error(err, 0)
	end
	return result
end

local function program(command)
	local first = command and command:match("^%s*(%S+)")
	return first and first:gsub("^%-", ""):match("([^/]+)$")
end

local function shell_quote(text)
	return "'" .. text:gsub("'", "'\\''") .. "'"
end

local function saved_time(timestamp)
	return (os.date("%b %d at %I:%M %p", timestamp):gsub(" 0", " "))
end

local function server_instance()
	return call("server.status").instance_id
end

-- Attaching to every session lets the action read sessions other than its own.
local function terminal_panes()
	local panes = {}
	for _, session in ipairs(call("session.attach_all", { event_scope = "session" }).sessions or {}) do
		for _, block in ipairs(call("session.list_blocks", { session_id = session.session_id }).blocks or {}) do
			if block.creator_name == terminal then
				panes[#panes + 1] = { session_id = session.session_id, session = session.label, block_id = block.block_id }
			end
		end
	end
	return panes
end

-- Rex reports each program's name but never its arguments, so ps supplies the command line.
local function command_lines(pids)
	local lines = {}
	if #pids == 0 then
		return lines
	end
	local result, err = rex.exec({ "/bin/ps", "-ww", "-o", "pid=,command=", "-p", table.concat(pids, ",") }, { timeout = 5 })
	if not result then
		error(err, 0)
	end
	for pid, command in result.stdout:gmatch("%s*(%d+) +([^\n]*)") do
		lines[tonumber(pid)] = command:gsub("%s+$", "")
	end
	return lines
end

local function capture(allowed)
	local running = {}
	for _, pane in ipairs(terminal_panes()) do
		local foreground = block_call("process", pane).foreground
		if foreground and allowed[program(foreground.argv0 or foreground.name)] then
			running[#running + 1] = { pane = pane, process = foreground }
		end
	end
	local pids = {}
	for i, entry in ipairs(running) do
		pids[i] = tostring(entry.process.pid)
	end
	local lines = command_lines(pids)
	local saved = {}
	for _, entry in ipairs(running) do
		local command = lines[entry.process.pid]
		if command and command ~= "" and not command:find("[%z\r\n]") then
			saved[#saved + 1] = {
				block_id = entry.pane.block_id,
				session = entry.pane.session,
				cwd = entry.process.cwd,
				command = command,
			}
		end
	end
	return saved
end

local function check(ok, message)
	if not ok then
		error(message, 0)
	end
end

local function validate(snapshot)
	check(
		type(snapshot) == "table" and snapshot.format == format and snapshot.version == version,
		"Snapshot is from an older rex-res or another tool; run Save to replace it"
	)
	check(type(snapshot.panes) == "table" and type(snapshot.server) == "string", "Snapshot is missing its panes")
	for _, pane in ipairs(snapshot.panes) do
		check(type(pane.block_id) == "string" and type(pane.command) == "string", "Invalid saved pane")
		check(program(pane.command) and not pane.command:find("[%z\r\n]"), "Invalid saved command")
		check(pane.cwd == nil or type(pane.cwd) == "string" and pane.cwd:sub(1, 1) == "/", "Invalid saved directory")
	end
	return snapshot
end

local function restore(snapshot)
	local current = {}
	for _, pane in ipairs(terminal_panes()) do
		current[pane.block_id] = pane
	end
	local started, busy, missing = 0, 0, 0
	for _, saved in ipairs(snapshot.panes) do
		local pane = current[saved.block_id]
		local shell = pane and block_call("process", pane).foreground
		if not pane then
			missing = missing + 1
		elseif not shell or not shells[program(shell.argv0 or shell.name)] then
			busy = busy + 1
		else
			local line = saved.command
			if saved.cwd and saved.cwd ~= shell.cwd then
				line = "cd -- " .. shell_quote(saved.cwd) .. " && " .. line
			end
			-- The leading space keeps the command out of shell history.
			block_call("write", pane, { data = " " .. line .. "\r" })
			started = started + 1
		end
	end
	return started, busy, missing
end

local function count_programs(panes)
	local counts, names = {}, {}
	for _, pane in ipairs(panes) do
		local name = program(pane.command)
		if not counts[name] then
			names[#names + 1] = name
		end
		counts[name] = (counts[name] or 0) + 1
	end
	table.sort(names)
	for i, name in ipairs(names) do
		names[i] = counts[name] > 1 and name .. " ×" .. counts[name] or name
	end
	return #names > 0 and table.concat(names, ", ") or "nothing running"
end

local function notify(summary, detail)
	local result, err = rex.exec({
		"/usr/bin/osascript",
		"-e",
		"on run argv\ndisplay notification (item 3 of argv) with title (item 1 of argv) subtitle (item 2 of argv)\nend run",
		"Rex Resurrect",
		summary,
		detail,
	}, { timeout = 5 })
	if not result or not result.ok then
		rex.log("warn", "rex-res notification failed: " .. (err or result.stderr))
	end
end

function plugin.setup(options)
	options = options or {}
	for key in pairs(options) do
		assert(({ state_dir = true, prefix = true, programs = true })[key], "Unknown rex-res option: " .. tostring(key))
	end
	local state_dir = options.state_dir or os.getenv("REX_RES_STATE") or os.getenv("HOME") .. "/.local/state/rex-res"
	assert(type(state_dir) == "string" and state_dir:sub(1, 1) == "/", "state_dir must be an absolute path")
	local prefix = options.prefix == nil and "ctrl+b" or options.prefix
	assert(prefix == false or type(prefix) == "string" and not prefix:find(">", 1, true), "prefix must be one key or false")
	local allowed = {}
	for _, name in ipairs(options.programs or default_programs) do
		assert(type(name) == "string" and name:match("^[%w_.+-]+$"), "programs must be executable names")
		allowed[name] = true
	end
	local path = state_dir .. "/workspace.json"

	local function read()
		local file = io.open(path, "rb")
		if not file then
			return nil
		end
		local text = file:read("*a")
		file:close()
		local snapshot, err = rex.json.decode(text)
		if snapshot == nil then
			error("Cannot read " .. path .. ": " .. tostring(err), 0)
		end
		return snapshot
	end

	local function write(snapshot)
		local made, err = rex.exec({ "/bin/mkdir", "-p", "-m", "700", state_dir })
		assert(made and made.ok, err or made and made.stderr)
		local text = assert(rex.json.encode(snapshot, { indent = true }))
		local partial = path .. ".partial"
		local file = assert(io.open(partial, "wb"))
		file:write(text)
		file:close()
		assert(os.rename(partial, path))
	end

	local function action(name, title, args, run)
		rex.action({
			name = name,
			title = title,
			category = "Rex Resurrect",
			args = args,
			run = function(ctx, given)
				local summary, detail = run(given)
				if ctx.origin == "palette" or ctx.origin == "key" then
					notify(summary, detail)
				end
				return summary .. "\n" .. detail
			end,
		})
	end

	action("res_save", "rex-res: Save running programs", { force = "boolean?" }, function(args)
		local instance = server_instance()
		local previous = read()
		local unrestored = previous
			and previous.format == format
			and previous.version == version
			and previous.server ~= instance
			and previous.restored_in ~= instance
			and #(previous.panes or {}) > 0
		if unrestored and not args.force then
			error("Saved programs from before Rex restarted haven't been restored. Run Restore first, or save with force=true", 0)
		end
		local panes = capture(allowed)
		write({ format = format, version = version, saved_at = os.time(), server = instance, panes = panes })
		return string.format("Saved %d programs", #panes), count_programs(panes)
	end)

	action("res_restore", "rex-res: Restore running programs", nil, function()
		local snapshot = validate(read() or error("Nothing saved yet", 0))
		local started, busy, missing = restore(snapshot)
		snapshot.restored_in = server_instance()
		write(snapshot)
		return string.format("Started %d programs", started),
			string.format("%d panes already busy · %d panes gone", busy, missing)
	end)

	action("res_status", "rex-res: Show saved programs", nil, function()
		local snapshot = validate(read() or error("Nothing saved yet", 0))
		local instance = server_instance()
		local state = (snapshot.server == instance or snapshot.restored_in == instance) and "" or " · waiting to restore"
		return string.format("%d programs saved %s%s", #snapshot.panes, saved_time(snapshot.saved_at), state),
			count_programs(snapshot.panes)
	end)

	if prefix then
		rex.bind(prefix .. ">ctrl+s", "res_save")
		rex.bind(prefix .. ">ctrl+r", "res_restore")
		rex.bind(prefix .. ">" .. prefix, "pane.send_key", { key = prefix })
	end
end

return plugin
