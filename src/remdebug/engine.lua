--
-- RemDebug for LuaIDE
-- Copyright Kepler Project 2005 (http://www.keplerproject.org/remdebug)
--

local socket = require"socket"
local lfs = require"lfs"
local debug = require"debug"

module("remdebug.engine", package.seeall)

_COPYRIGHT = "2006 - Kepler Project"
_DESCRIPTION = "Remote Debugger for the Lua programming language"
_VERSION = "1.0"

local coro_debugger
local events = { BREAK = 1, WATCH = 2 }
local breakpoints = {}
local watches = {}
local step_into = false
local step_over = false
local step_level = 0
local stack_level = 0

local controller_host = "localhost"
local controller_port = 8171

local function set_breakpoint(file, line)
  if not breakpoints[file] then
    breakpoints[file] = {}
  end
  breakpoints[file][line] = true
end

local function remove_breakpoint(file, line)
  if breakpoints[file] then
    breakpoints[file][line] = nil
  end
end

local function has_breakpoint(file, line)
  return breakpoints[file] and breakpoints[file][line]
end

local function restore_vars(vars)
  if type(vars) ~= 'table' then return end
  local func = debug.getinfo(3, "f").func
  local i = 1
  local written_vars = {}
  while true do
    local name = debug.getlocal(3, i)
    if not name then break end
    if vars[name] and not written_vars[name] then
      debug.setlocal(3, i, vars[name])
      written_vars[name] = true
    end
    i = i + 1
  end
  i = 1
  while true do
    local name = debug.getupvalue(func, i)
    if not name then break end
    if vars[name] and not written_vars[name] then
      debug.setupvalue(func, i, vars[name])
      written_vars[name] = true
    end
    i = i + 1
  end
end

local function capture_vars()
  local vars = {}
  local func = debug.getinfo(3, "f").func
  local i = 1
  while true do
    local name, value = debug.getupvalue(func, i)
    if not name then break end
    vars[name] = value
    i = i + 1
  end
  i = 1
  while true do
    local name, value = debug.getlocal(3, i)
    if not name then break end
    -- ignore temporary variables
    if name:sub(1,1) ~= '(' then
      vars[name] = value
    end
    i = i + 1
  end
  setmetatable(vars, { __index = getfenv(func), __newindex = getfenv(func) })
  return vars
end
--[[
local function break_dir(path)
  local paths = {}
  path = string.gsub(path, "\\", "/")
  for w in string.gfind(path, "[^/]+") do
    table.insert(paths, w)
  end
  return paths
end

local function merge_paths(path1, path2) -- TODO fix fow windows paths
  if path2:sub(1,1) == '/' then return path2 end -- unix paths
  local paths1 = break_dir(path1)
  local paths2 = break_dir(path2)
  for i, path in ipairs(paths2) do
    if path == ".." then
      table.remove(paths1, table.getn(paths1))
    elseif path ~= "." then
      table.insert(paths1, path)
    end
  end
  return table.concat(paths1, "/")
end
--]]
local function debug_hook(event, line)
  if event == "call" then
    stack_level = stack_level + 1
  elseif event == "return" or event == "tail return" then
    stack_level = stack_level - 1
  else
    -- get whole file path
    local file = debug.getinfo(2, "S").short_src
	local dir = lfs.currentdir()
	if string.sub(dir, 1, 1) ~= '/'
	then -- widnows
		dir = dir .. '\\'
		-- if file is on other partition, file got whole path
		if string.find(file, ":") then dir = "" end
	else -- unix
		dir = dir .. '/'
		if string.sub(file, 1, 1) == '/' then dir = "" end
	end
	file = dir .. file

    local vars = capture_vars()
    table.foreach(watches, function (index, value)
      setfenv(value, vars)
      local status, res = pcall(value)
      if status and res then
        coroutine.resume(coro_debugger, events.WATCH, vars, file, line, index)
	restore_vars(vars)
      end
    end)
    if step_into or (step_over and stack_level <= step_level) or has_breakpoint(file, line) then
      step_into = false
      step_over = false
      coroutine.resume(coro_debugger, events.BREAK, vars, file, line)
      restore_vars(vars)
    end
  end
end

local function debugger_loop(server)
  local command
  local eval_env = {}

  while true do
    local line, status = server:receive()
    command = string.sub(line, string.find(line, "^[A-Z]+"))
    if command == "SETB" then
      local _, _, _, filename, line = string.find(line, "^([A-Z]+)%s+([%w%p]+)%s+(%d+)$")
      if filename and line then
        filename = string.gsub(filename, "%%20", " ")
        set_breakpoint(filename, tonumber(line))
        server:send("200 OK\n")
      else
        server:send("400 Bad Request\n")
      end
    elseif command == "DELB" then
      local _, _, _, filename, line = string.find(line, "^([A-Z]+)%s+([%w%p]+)%s+(%d+)$")
      if filename and line then
        remove_breakpoint(filename, tonumber(line))
        server:send("200 OK\n")
      else
        server:send("400 Bad Request\n")
      end
    elseif command == "EXEC" then
      local _, _, chunk = string.find(line, "^[A-Z]+%s+(.+)$")
      if chunk then
        local func = loadstring(chunk)
        local status, res
        if func then
          setfenv(func, eval_env)
          status, res = xpcall(func, debug.traceback)
        end
        res = tostring(res)
        if status then
          server:send("200 OK " .. string.len(res) .. "\n")
          server:send(res)
        else
          server:send("401 Error in Expression " .. string.len(res) .. "\n")
          server:send(res)
        end
      else
        server:send("400 Bad Request\n")
      end
    elseif command == "SETW" then
      local _, _, exp = string.find(line, "^[A-Z]+%s+(.+)$")
      if exp then
        local func = loadstring("return(" .. exp .. ")")
        local newidx = table.getn(watches) + 1
        watches[newidx] = func
        table.setn(watches, newidx)
        server:send("200 OK " .. newidx .. "\n")
      else
        server:send("400 Bad Request\n")
      end
    elseif command == "DELW" then
      local _, _, index = string.find(line, "^[A-Z]+%s+(%d+)$")
      index = tonumber(index)
      if index then
        watches[index] = nil
        server:send("200 OK\n")
      else
        server:send("400 Bad Request\n")
      end
    elseif command == "RUN" then
      server:send("200 OK\n")
      local ev, vars, file, line, idx_watch = coroutine.yield()
      eval_env = vars
      if ev == events.BREAK then
        server:send("202 Paused " .. file .. " " .. line .. "\n")
      elseif ev == events.WATCH then
        server:send("203 Paused " .. file .. " " .. line .. " " .. idx_watch .. "\n")
      else
        server:send("401 Error in Execution " .. string.len(file) .. "\n")
        server:send(file)
      end
    elseif command == "STEP" then
      server:send("200 OK\n")
      step_into = true
      local ev, vars, file, line, idx_watch = coroutine.yield()
      eval_env = vars
      if ev == events.BREAK then
        server:send("202 Paused " .. file .. " " .. line .. "\n")
      elseif ev == events.WATCH then
        server:send("203 Paused " .. file .. " " .. line .. " " .. idx_watch .. "\n")
      else
        server:send("401 Error in Execution " .. string.len(file) .. "\n")
        server:send(file)
      end
    elseif command == "OVER" then
      server:send("200 OK\n")
      step_over = true
      step_level = stack_level
      local ev, vars, file, line, idx_watch = coroutine.yield()
      eval_env = vars
      if ev == events.BREAK then
        server:send("202 Paused " .. file .. " " .. line .. "\n")
      elseif ev == events.WATCH then
        server:send("203 Paused " .. file .. " " .. line .. " " .. idx_watch .. "\n")
      else
        server:send("401 Error in Execution " .. string.len(file) .. "\n")
        server:send(file)
      end
    else
      server:send("400 Bad Request\n")
    end
  end
end

coro_debugger = coroutine.create(debugger_loop)

--
-- remdebug.engine.config(tab)
-- Configures the engine
--
function config(tab)
  if tab.host then
    controller_host = tab.host
  end
  if tab.port then
    controller_port = tab.port
  end
end

--
-- remdebug.engine.start()
-- Tries to start the debug session by connecting with a controller
--
function start()
  pcall(require, "remdebug.config")
  local server = socket.connect(controller_host, controller_port)
  if server then
    _TRACEBACK = function (message)
      local err = debug.traceback(message)
      server:send("401 Error in Execution " .. string.len(err) .. "\n")
      server:send(err)
      server:close()
      return err
    end
    debug.sethook(debug_hook, "lcr")
    return coroutine.resume(coro_debugger, server)
  end
end
