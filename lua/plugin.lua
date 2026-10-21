local plugin = {}
local terminal = "com.superlogical.terminal"
local defaults = { "vi", "vim", "nvim", "emacs", "man", "less", "more", "tail", "top", "htop", "irssi", "weechat", "mutt", "opencode" }
local shells = { sh = true, bash = true, zsh = true, fish = true, dash = true, ksh = true, nu = true, login = true }
local configured = false

local function call(method, args)
  return assert(rex.call(method, args))
end

local function exec(argv, options)
  local result = assert(rex.exec(argv, options))
  assert(result.ok, result.stderr ~= "" and result.stderr or "Command failed: " .. argv[1])
  return result.stdout
end

local function program(command)
  local first = command:match('^"([^"]+)"') or command:match("^'([^']+)'") or command:match("^(%S+)")
  return first and first:match("([^/]+)$")
end

local function leaves(layout, result)
  result = result or {}
  if layout.pane then
    result[#result + 1] = layout.pane
  else
    leaves(layout.split.before, result)
    leaves(layout.split.after, result)
  end
  return result
end

local function process_table()
  local by_pid, children = {}, {}
  for line in exec({ "/bin/ps", "-axww", "-o", "pid=,ppid=,command=" }):gmatch("[^\n]+") do
    local pid, parent, command = line:match("^%s*(%d+)%s+(%d+)%s+(.+)$")
    if pid then
      pid, parent = tonumber(pid), tonumber(parent)
      by_pid[pid] = command
      children[parent] = children[parent] or {}
      children[parent][#children[parent] + 1] = pid
    end
  end
  return by_pid, children
end

local function capture_pane(session_id, block, commands, children)
  assert(block.creator_name == terminal, "Only terminal panes can be saved")
  local args = { session_id = session_id, block_id = block.block_id, args = {} }
  local processes = call(terminal .. ".process", args)
  local pwd = call(terminal .. ".pwd", args)
  local active = processes.foreground or processes.child
  local pid = active and active.pid
  local command = pid and commands[pid]
  if command and program(command) == "login" then
    pid = (children[pid] or {})[1]
    command = pid and commands[pid]
  end
  if command then command = command:gsub("^%-", "") end
  if command and shells[program(command)] then command = nil end
  assert(not command or not command:find("[%z\r\n]"), "Cannot save a multiline command")
  local cwd = active and active.cwd or pwd.pwd or processes.child and processes.child.cwd
  if not cwd and pid then
    cwd = exec({ "/usr/sbin/lsof", "-a", "-p", tostring(pid), "-d", "cwd", "-Fn" }, { timeout = 5 }):match("\nn([^\n]+)")
  end
  assert(type(cwd) == "string" and cwd:sub(1, 1) == "/", "Cannot find pane's working directory")
  return { id = block.block_id, label = block.label or "", cwd = cwd, command = command }
end

local function capture_layout(layout, panes)
  if layout.block_id then return { pane = assert(panes[layout.block_id]) } end
  local split = assert(layout.split, "Missing terminal layout")
  return { split = { direction = split.direction, ratio = split.ratio,
    before = capture_layout(split.before, panes), after = capture_layout(split.after, panes) } }
end

local function capture()
  local commands, children = process_table()
  local listed = call("session.list").sessions
  local snapshot = { format = "rex-res-lua", version = 1, saved_at = os.time(), sessions = {} }
  local labels, pane_count = {}, 0
  for _, session in ipairs(listed) do
    assert(not labels[session.label], "Session labels must be unique: " .. session.label)
    labels[session.label] = true
    call("session.attach", { session_id = session.session_id })
    local view = call("session.view", { session_id = session.session_id })
    local saved = { label = session.label, windows = {} }
    for index, window in ipairs(view.windows or {}) do
      if window.window_id == view.active_window_id then saved.active_window = index end
      local tab = { label = window.label, layers = {}, focused = window.focused_block_id, zoomed = window.zoomed_block_id }
      for _, layer in ipairs(window.layers or {}) do
        local panes = {}
        for _, block in ipairs(layer.blocks or {}) do
          panes[block.block_id] = capture_pane(session.session_id, block, commands, children)
          pane_count = pane_count + 1
        end
        tab.layers[#tab.layers + 1] = { bounds = layer.bounds, layout = capture_layout(layer.layout, panes) }
      end
      saved.windows[#saved.windows + 1] = tab
    end
    assert(call("session.view", { session_id = session.session_id }).revision == view.revision, "Layout changed; save again")
    snapshot.sessions[#snapshot.sessions + 1] = saved
  end
  local after = call("session.list").sessions
  assert(#listed == #after, "Sessions changed; save again")
  for i, session in ipairs(listed) do assert(session.session_id == after[i].session_id, "Sessions changed; save again") end
  return snapshot, pane_count
end

local function validate(snapshot)
  assert(type(snapshot) == "table" and snapshot.format == "rex-res-lua" and snapshot.version == 1, "Not a rex-res Lua snapshot")
  assert(type(snapshot.sessions) == "table", "Missing saved sessions")
  local function layout(node, depth)
    assert(type(node) == "table" and depth < 64, "Invalid saved layout")
    if node.pane then
      local pane = node.pane
      assert(not node.split and type(pane) == "table" and type(pane.id) == "string" and type(pane.label) == "string", "Invalid saved pane")
      assert(type(pane.cwd) == "string" and pane.cwd:sub(1, 1) == "/" and not pane.cwd:find("%z"), "Invalid saved directory")
      assert(pane.command == nil or type(pane.command) == "string" and program(pane.command) and not pane.command:find("[%z\r\n]"), "Invalid saved command")
    else
      local split = node.split
      assert(type(split) == "table" and (split.direction == "horizontal" or split.direction == "vertical"), "Invalid saved split")
      assert(type(split.ratio) == "number" and split.ratio > 0 and split.ratio < 1, "Invalid saved split ratio")
      layout(split.before, depth + 1)
      layout(split.after, depth + 1)
    end
  end
  local labels = {}
  for _, session in ipairs(snapshot.sessions) do
    assert(type(session.label) == "string" and not labels[session.label] and type(session.windows) == "table", "Invalid or duplicate session label")
    labels[session.label] = true
    for _, window in ipairs(session.windows) do
      assert(type(window.label) == "string" and type(window.layers) == "table" and #window.layers > 0, "Invalid saved tab")
      for _, layer in ipairs(window.layers) do
        assert(type(layer.bounds) == "table" and #layer.bounds == 4, "Invalid saved layer bounds")
        for _, coordinate in ipairs(layer.bounds) do assert(type(coordinate) == "number", "Invalid layer coordinate") end
        layout(layer.layout, 0)
      end
    end
  end
end

local function restore(snapshot, allowed)
  local sessions = {}
  for _, session in ipairs(call("session.list").sessions) do
    assert(not sessions[session.label], "Session labels must be unique: " .. session.label)
    sessions[session.label] = session.session_id
  end
  local created, replayed, skipped = 0, 0, 0
  local function compile(node)
    if node.pane then
      local pane = node.pane
      local options = { cwd = pane.cwd }
      if pane.command and allowed[program(pane.command)] then
        options.initial_input = " " .. pane.command .. "\r"
        replayed = replayed + 1
      elseif pane.command then
        skipped = skipped + 1
      end
      created = created + 1
      return { block = { flavor = terminal .. ".shell", options = options } }
    end
    local split = node.split
    return { split = { direction = split.direction, ratio = split.ratio, before = compile(split.before), after = compile(split.after) } }
  end
  local function remember(node, ids, restored, session_id)
    for i, pane in ipairs(leaves(node)) do
      restored[pane.id] = assert(ids[i], "Rex omitted a created pane")
      call("session.set_block_label", { session_id = session_id, block_id = ids[i], label = pane.label })
    end
  end
  local function complete(node, restored, session_id)
    if node.pane then return end
    local split = node.split
    local function anchor(branch)
      for _, pane in ipairs(leaves(branch)) do if restored[pane.id] then return restored[pane.id] end end
    end
    local before, after = anchor(split.before), anchor(split.after)
    if before and after then
      complete(split.before, restored, session_id)
      complete(split.after, restored, session_id)
    else
      local missing = before and split.after or split.before
      local result = call("session.new_split", { session_id = session_id,
        anchor_block_id = assert(before or after), direction = split.direction, ratio = split.ratio,
        side = before and "after" or "before", layout = compile(missing), focus = false })
      remember(missing, result.block_ids, restored, session_id)
      complete(before and split.before or split.after, restored, session_id)
    end
  end
  for _, saved in ipairs(snapshot.sessions) do
    local session_id = sessions[saved.label]
    if not session_id then session_id = call("session.create", { label = saved.label }).session_id end
    call("session.attach", { session_id = session_id })
    local view = call("session.view", { session_id = session_id })
    local new_windows = {}
    for index, tab in ipairs(saved.windows) do
      local window = (view.windows or {})[index]
      local restored = {}
      local window_id = window and window.window_id
      if not window then
        local result = call("session.new_window", { session_id = session_id, window_label = tab.label,
          layout = compile(tab.layers[1].layout), focus = false })
        window_id = result.window_id
        remember(tab.layers[1].layout, result.block_ids, restored, session_id)
        new_windows[index] = window_id
      end
      for layer_index, layer in ipairs(tab.layers) do
        local existing = window and window.layers[layer_index]
        if existing then
          local current = {}
          local function collect(node)
            if node.block_id then current[#current + 1] = node.block_id
            else collect(node.split.before); collect(node.split.after) end
          end
          collect(existing.layout)
          for i, pane in ipairs(leaves(layer.layout)) do restored[pane.id] = current[i] end
          complete(layer.layout, restored, session_id)
        elseif layer_index > 1 then
          local result = call("session.new_layer", { session_id = session_id, window_id = window_id,
            bounds = layer.bounds, layout = compile(layer.layout), focus = false })
          remember(layer.layout, result.block_ids, restored, session_id)
        end
      end
      if not window then
        if restored[tab.focused] then call("session.focus_block", { session_id = session_id, block_id = restored[tab.focused] }) end
        if restored[tab.zoomed] then call("session.zoom_block", { session_id = session_id, block_id = restored[tab.zoomed], zoom = true }) end
      end
    end
    if new_windows[saved.active_window] then
      call("session.focus_window", { session_id = session_id, window_id = new_windows[saved.active_window] })
    end
  end
  return string.format("Created %d panes; replayed %d commands; skipped %d unapproved commands", created, replayed, skipped)
end

function plugin.setup(options)
  assert(not configured, "rex-res.setup must run only once per config load")
  options = options or {}
  assert(type(options) == "table", "rex-res options must be a table")
  local accepted = { state_dir = true, prefix = true, programs = true }
  for key in pairs(options) do assert(accepted[key], "Unknown rex-res option: " .. tostring(key)) end
  local state_dir = options.state_dir or os.getenv("REX_RES_STATE") or assert(os.getenv("HOME")) .. "/.local/state/rex-res"
  assert(type(state_dir) == "string" and state_dir:sub(1, 1) == "/" and not state_dir:find("%z"), "state_dir must be an absolute path")
  local prefix = options.prefix
  if prefix == nil then prefix = "ctrl+b" end
  assert(prefix == false or type(prefix) == "string" and #prefix > 0 and not prefix:find(">", 1, true), "prefix must be one key or false")
  local programs = options.programs or defaults
  assert(type(programs) == "table", "programs must be a list of executable names")
  local allowed = {}
  for _, name in ipairs(programs) do
    assert(type(name) == "string" and name:match("^[%w_.+-]+$"), "programs must contain executable names, not commands")
    allowed[name] = true
  end
  local path = state_dir .. "/workspace.json"
  local busy = false
  local function read()
    local file = assert(io.open(path, "rb"))
    local text = file:read(16 * 1024 * 1024 + 1)
    file:close()
    assert(text and #text <= 16 * 1024 * 1024, "Snapshot is empty or larger than 16 MiB")
    local snapshot = assert(rex.json.decode(text))
    validate(snapshot)
    return snapshot
  end
  local function action(name, title, run)
    rex.action { name = name, title = title, category = "Rex Resurrect", run = function(ctx)
      assert(not busy, "Another rex-res action is running")
      busy = true
      local ok, result = pcall(run)
      busy = false
      if not ok then error(result, 0) end
      if ctx.origin == "palette" or ctx.origin == "key" then
        local notification, err = rex.exec({ "/usr/bin/osascript", "-e", [[
on run argv
  display notification (item 2 of argv) with title (item 1 of argv)
end run
]], "Rex Resurrect", result }, { timeout = 5 })
        if not notification or not notification.ok then
          rex.log("warn", "Workspace action completed, but notification failed: " .. (err or notification.stderr))
        end
      end
      return result
    end }
  end
  action("res_save", "Save Rex Workspace", function()
    local snapshot, count = capture()
    validate(snapshot)
    local encoded = assert(rex.json.encode(snapshot, { indent = true }))
    assert(#encoded <= 16 * 1024 * 1024, "Snapshot is larger than 16 MiB")
    exec({ "/bin/sh", "-c", [[
set -eu
umask 077
mkdir -p "$1"
chmod 700 "$1"
tmp=$(mktemp "$1/.workspace.XXXXXX")
trap 'rm -f "$tmp"' EXIT HUP INT TERM
cat > "$tmp"
mv -f "$tmp" "$1/workspace.json"
]], "rex-res", state_dir }, { stdin = encoded, timeout = 10 })
    return string.format("Saved %d sessions and %d panes to %s", #snapshot.sessions, count, path)
  end)
  action("res_restore", "Restore Rex Workspace", function() return restore(read(), allowed) end)
  action("res_status", "Saved Rex Workspace Status", function()
    local snapshot = read()
    local count = 0
    for _, session in ipairs(snapshot.sessions) do
      for _, window in ipairs(session.windows) do
        for _, layer in ipairs(window.layers) do count = count + #leaves(layer.layout) end
      end
    end
    return string.format("%d sessions and %d panes saved %s in %s", #snapshot.sessions, count, os.date("%Y-%m-%d %H:%M:%S", snapshot.saved_at), path)
  end)
  if prefix then
    rex.bind(prefix .. ">ctrl+s", "res_save")
    rex.bind(prefix .. ">ctrl+r", "res_restore")
    rex.bind(prefix .. ">" .. prefix, "pane.send_key", { key = prefix })
  end
  configured = true
end

return plugin
