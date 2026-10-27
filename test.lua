--!nocheck
--[[
	NyxDump 1.7.1 - full place export: one working place file + all game data
	------------------------------------------------------
	Paste into your executor and execute. By default you get:

		<workspace>/NyxDump_<PlaceId>_<timestamp>/
			Game.rbxlx            full place (built-in XML saver; opens in Studio)
			Scripts/              every game script as decompiled .lua
			Guis/                 every top-level GUI as .rbxmx
			Models/               every top-level Workspace/ReplicatedStorage model as .rbxmx
			Data/                 instances.jsonl, animations.jsonl, scripts_index, place_info
			Assets/               ALL referenced images/sounds/meshes/animations/textures
			REPORT.txt / summary.json / manifest.json / README.txt

	Config (put before the dumper):
		_G.NYX_DUMP_CONFIG = { OnlyPlaceFile = true }   -- place file only, no folders
		_G.NYX_DUMP_CONFIG = { AssetLimit = 300 }       -- cap asset downloads (0 = all, default)
		_G.NYX_DUMP_CONFIG = { SkipRobloxInternals = false } -- also dump Roblox CorePackages
		_G.NYX_DUMP_CONFIG = { MaxInstances = 0 }       -- no instance cap (default 500000)
		_G.NYX_DUMP_CONFIG = { OnlyPlaceFile = true }   -- place file only, no folders

	How to know it finished: console prints NYX_DUMP_DONE + ALL DONE banner, the folder
	contains DONE.txt and STATUS.txt says state: done; REPORT.txt ends with END OF REPORT.

	Memory safety: built-in XML is written with one writefile (Xeno's appendfile drops chunks).
	If the client already uses > AutoFallbackMemoryMB, XML is written per-service instead of one
	big string, so Roblox does not close on OOM.

	Known limits (engine-side, not bugs):
	  * Workspace streaming: only map chunks loaded around the player exist on the client.
	  * Protected instances (CoreGui internals, RobloxSecurity objects) cannot be read.
	  * The Lua API cannot write outside the executor workspace folder.

	Native extras (getnilinstances/getloadedmodules/getscripts/getproperties) are OFF by
	default: on a Roblox update with stale executor offsets they crash the client. SafeMode=true
	is the emergency "no native calls at all" switch; the normal path is built-in XML + native
	decompile + every asset.
]]

local VERSION = "1.7.1"

-- ===========================================================================
-- CONFIG - edit before running if you want
-- ===========================================================================
local CFG = {
	OutputFolderName = "NyxDump", -- folder prefix inside the executor workspace
	OnlyPlaceFile = false,        -- false = place file PLUS Scripts/Guis/Models/Data/Assets
	XmlUseAppend = false,         -- Xeno's appendfile silently drops ~1.5 MB chunks: never stream XML
	                              -- through it; write the whole XML with one writefile instead
	SafeMode = false,             -- emergency only: skips ALL executor-native calls. Default OFF
	                              -- (full dump); turn on if a stale executor build keeps killing
	                              -- the client before it can write anything.
	GhostMode = false,            -- true = quiet full dump (no console, random waits, request-only
	                              -- assets). Off by default so you can see the phase if the
	                              -- executor/anti-cheat kills the client.
	Silent = false,               -- GhostMode sets this: no [NyxDump] console prints
	SlowMode = false,             -- GhostMode sets this: random small waits while walking
	AssetViaRequestOnly = false,  -- GhostMode sets this: no getcustomasset/game:HttpGet
	DumpNilInstances = false,     -- getnilinstances/getloadedmodules/getscripts are native calls
	                              -- that crashed stale executors; off by default (they only add
	                              -- orphaned instances to the dump)
	ReadAllProperties = false,    -- getproperties is native too; curated props are dumped anyway
	MaxInstances = 500000,        -- hard cap so a broken game cannot exhaust memory (0 = no cap)
	YieldEvery = 300,             -- task.wait() every N instances (keeps the client alive)
	ProgressEvery = 1000,         -- generic progress print interval
	WriteStatus = true,           -- keep STATUS.txt updated while running
	DumpXml = true,               -- Game.rbxlx (full place XML) - written before slow phases
	DumpJsonl = true,             -- Data/instances.jsonl (one JSON object per instance)
	DumpScripts = true,           -- decompile every script into Scripts/
	SkipRobloxInternals = true,   -- skip CorePackages/CoreScripts/CoreGui scripts (thousands of
	                              -- engine modules; set false if you really want everything)
	DumpGuis = true,              -- export top-level GUIs as .rbxmx into Guis/
	DownloadAssets = true,        -- download rbxassetid content into Assets/ (slow, last phase)
	AssetLimit = 0,               -- max assets to download (0 = EVERYTHING, no limit)
	AssetDelay = 0.02,            -- small yield between asset downloads (keeps the client alive)
	ExportTopModels = true,       -- export every top-level Workspace/ReplicatedStorage model
	MaxModelFiles = 0,            -- 0 = unlimited Models/*.rbxmx
	DumpAnimations = true,        -- write Data/animations.jsonl + download AnimationId assets
	AntiIdle = true,              -- keep sending virtual input so the server never kicks for
	                              -- 20-minute idle while a multi-hour dump is running
	FreezeRendering = false,      -- OFF: Set3dRenderingEnabled/setfpscap crashed Xeno on 0.745
	AbortMemoryMB = 0,            -- 0 = do not abort; high memory only enables per-service XML
	MemoryStopMB = 0,             -- 0 = no early collection stop
	EmbedSourcesInPlace = false,  -- true = decompile scripts BEFORE Game.rbxlx so sources are
	                              -- embedded in the place file (slower; place file waits for scripts)
	SaveBytecode = false,         -- also keep .bytecode next to successfully decompiled scripts
	DecompileAttempts = 2,        -- how many times to retry a failed local decompile
	DecompileDelay = 0.12,        -- seconds between decompile calls: executors that proxy to the
	                              -- online decompiler are rate limited (~500 requests/minute)
	MaxPathLength = 150,          -- relative path budget for files inside the dump folder
	MaxSegmentLength = 60,        -- per path segment budget
	XmlMemoryLimitMB = 192,       -- without appendfile the place XML is built in memory up to this
	AutoFallbackMemoryMB = 2100,  -- above this, build small per-service XML instead of one big string
	UseSaveInstance = false,      -- Xeno's built-in saveinstance() produced a 5.7 MB skeleton with
	                              -- PromptPart placeholders - off by default; built-in XML is used
	AlwaysBuildLuaXml = false,    -- also build our own Game.rbxlx even when saveinstance() worked
	OnlineDecompile = false,      -- OFF: no third-party decompiler API by default. Scripts are
	                              -- decompiled by the executor itself; enable only if you accept
	                              -- sending bytecode to api.lua.expert
	OnlineDecompileUrl = "https://api.lua.expert/v1/decompile",
	OnlineDecompileLimit = 0,     -- max online recoveries (0 = all)
	OnlineDecompileDelay = 0.13,  -- pacing between online requests (~450/minute)
	OnlineMaxBytes = 4194304,     -- skip .bytecode bigger than 4 MB for online recovery
	PrintProgress = true,
}
if type(_G) == "table" and type(_G.NYX_DUMP_CONFIG) == "table" then
	for k, v in pairs(_G.NYX_DUMP_CONFIG) do
		if CFG[k] ~= nil then CFG[k] = v end
	end
end
if CFG.GhostMode then
	CFG.Silent = true
	CFG.SlowMode = true
	CFG.AssetViaRequestOnly = true
	CFG.UseSaveInstance = false
	CFG.DumpNilInstances = false
	CFG.ReadAllProperties = false
	CFG.FreezeRendering = false
end

-- ===========================================================================
-- environment probes
-- ===========================================================================
local ENV = _ENV
local G = _G

-- Direct references to every global we may need. Luau has no _ENV, and executors
-- inject their functions into the global environment, so direct references are the
-- most reliable probe. Lua 5.2+/mock runtimes also work through _ENV/getfenv below.
local DIRECT_GLOBALS = {
	game = game,
	typeof = typeof,
	print = print,
	os = os,
	task = task,
	wait = wait,
	getfenv = getfenv,
	writefile = writefile,
	appendfile = appendfile,
	readfile = readfile,
	makefolder = makefolder,
	isfolder = isfolder,
	isfile = isfile,
	listfiles = listfiles,
	delfile = delfile,
	getworkspace = getworkspace,
	decompile = decompile,
	getscriptbytecode = getscriptbytecode,
	getproperties = getproperties,
	getnilinstances = getnilinstances,
	getloadedmodules = getloadedmodules,
	getscripts = getscripts,
	getcustomasset = getcustomasset,
	request = request,
	http_request = http_request,
	syn = syn,
}

local function envLookup(env, name)
	if type(env) ~= "table" then return nil end
	local ok, v = pcall(function() return env[name] end)
	if ok and v ~= nil then return v end
	return nil
end

local function getGlobal(name)
	local direct = DIRECT_GLOBALS[name]
	if direct ~= nil then return direct end
	local v = envLookup(ENV, name)
	if v ~= nil then return v end
	local getfenvFn = DIRECT_GLOBALS.getfenv
	if type(getfenvFn) == "function" then
		local ok, env = pcall(getfenvFn, 1)
		if ok then
			v = envLookup(env, name)
			if v ~= nil then return v end
		end
	end
	if type(G) == "table" then
		local ok, g = pcall(function() return G[name] end)
		if ok and g ~= nil then return g end
	end
	return nil
end

local function getApi(name)
	local v = getGlobal(name)
	if type(v) == "function" then return v end
	return nil
end

local game = getGlobal("game")
local typeofGlobal = getGlobal("typeof")
local synTable = getGlobal("syn")

local function typeofOf(v)
	if typeofGlobal ~= nil then
		local ok, t = pcall(typeofGlobal, v)
		if ok then return t end
	end
	return type(v)
end

local function isInstance(v)
	if v == nil then return false end
	return typeofOf(v) == "Instance"
end

local function api(name)
	local v = getApi(name)
	if v ~= nil then return v end
	if synTable ~= nil then
		local ok, f = pcall(function() return synTable[name] end)
		if ok and type(f) == "function" then return f end
	end
	return nil
end

local fileApi = {
	write = api("writefile"),
	append = api("appendfile"),
	read = api("readfile"),
	makeDir = api("makefolder"),
	isDir = api("isfolder"),
	isFile = api("isfile"),
	list = api("listfiles"),
	delete = api("delfile"),
	workspace = api("getworkspace"),
}
-- Decompiler entry points. Most executors expose "decompile"; some expose other names too.
local decompileFns = {}
do
	local decompileNames = { "decompile", "luau_decompile", "decompilebytecode", "decompile_bytecode" }
	for i = 1, #decompileNames do
		local fn = api(decompileNames[i])
		if fn ~= nil then decompileFns[#decompileFns + 1] = fn end
	end
end
local decompileFn = decompileFns[1]
local bytecodeFn = api("getscriptbytecode")
local propertiesFn = api("getproperties")
local nilInstancesFn = api("getnilinstances")
local loadedModulesFn = api("getloadedmodules")
local scriptsFn = api("getscripts")
local customAssetFn = api("getcustomasset")
local requestFn = api("request") or api("http_request")
local saveInstanceFn = api("saveinstance")
local identifyFn = api("identifyexecutor") or api("getexecutorname")

local EXECUTOR_NAME = nil
if identifyFn ~= nil then
	local ok, name = pcall(identifyFn)
	if ok and type(name) == "string" and #name > 0 then EXECUTOR_NAME = name end
	if EXECUTOR_NAME == nil then
		local ok2, name2 = pcall(identifyFn, true)
		if ok2 and type(name2) == "string" and #name2 > 0 then EXECUTOR_NAME = name2 end
	end
end

local taskTable = getGlobal("task")
local waitFunction = nil
if taskTable ~= nil then
	local ok, fn = pcall(function() return taskTable.wait end)
	if ok and type(fn) == "function" then waitFunction = fn end
end
if waitFunction == nil then waitFunction = api("wait") end

local clockFn = api("clock")
local osDateFn = nil
do
	local osTable = getGlobal("os")
	if type(osTable) == "table" then
		local ok, fn = pcall(function() return osTable.date end)
		if ok and type(fn) == "function" then osDateFn = fn end
		if clockFn == nil then
			local ok2, fn2 = pcall(function() return osTable.clock end)
			if ok2 and type(fn2) == "function" then clockFn = fn2 end
		end
	end
end

-- ===========================================================================
-- small utilities
-- ===========================================================================
local function prop(inst, key)
	local ok, v = pcall(function() return inst[key] end)
	if ok then return v end
	return nil
end

local function classNameOf(inst)
	local v = prop(inst, "ClassName")
	if type(v) == "string" and #v > 0 then return v end
	return nil
end

local function nameOf(inst)
	local v = prop(inst, "Name")
	if type(v) == "string" then return v end
	return ""
end

local function objField(obj, key)
	local ok, v = pcall(function() return obj[key] end)
	if ok then return v end
	return nil
end

local function fmtFloat(v)
	if type(v) ~= "number" then return nil end
	if v ~= v then return "NAN" end
	if v == math.huge then return "INF" end
	if v == -math.huge then return "-INF" end
	return string.format("%.14g", v)
end

local function fmtInt(v)
	if type(v) ~= "number" then return nil end
	if v ~= v or v == math.huge or v == -math.huge then return nil end
	return string.format("%.0f", math.floor(v + 0.5))
end

local function say(msg)
	if CFG.Silent then return end
	if CFG.PrintProgress then
		pcall(print, "[NyxDump] " .. tostring(msg))
	end
end

local startClock = nil
if clockFn ~= nil then
	local ok, v = pcall(clockFn)
	if ok and type(v) == "number" then startClock = v end
end

local function elapsedMs()
	if startClock == nil or clockFn == nil then return 0 end
	local ok, v = pcall(clockFn)
	if ok and type(v) == "number" then return math.floor((v - startClock) * 1000 + 0.5) end
	return 0
end

local function makeStamp()
	if osDateFn ~= nil then
		local ok, s = pcall(osDateFn, "%Y%m%d_%H%M%S")
		if ok and type(s) == "string" and #s > 0 then return s end
	end
	local t = math.floor((startClock or 0) * 1000)
	return tostring(t)
end

local errorCount, warningCount = 0, 0
local errors, warnings = {}, {}
local function trimMsg(s)
	s = tostring(s or "")
	if #s > 400 then return s:sub(1, 400) .. "..." end
	return s
end
local function addError(phase, msg)
	errorCount = errorCount + 1
	if #errors < 300 then errors[#errors + 1] = "[" .. tostring(phase) .. "] " .. trimMsg(msg) end
end
local function addWarning(phase, msg)
	warningCount = warningCount + 1
	if #warnings < 300 then warnings[#warnings + 1] = "[" .. tostring(phase) .. "] " .. trimMsg(msg) end
end

-- ===========================================================================
-- JSON
-- ===========================================================================
local function jsonEscape(s)
	s = tostring(s)
	local special = {
		['"'] = '\\"', ["\\"] = "\\\\", ["\b"] = "\\b", ["\f"] = "\\f",
		["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t",
	}
	local out = {}
	local i, n = 1, #s
	while i <= n do
		local c = s:sub(i, i)
		local esc = special[c]
		if esc ~= nil then
			out[#out + 1] = esc
		else
			local b = s:byte(i)
			if b < 32 or b == 127 then
				out[#out + 1] = string.format("\\u%04x", b)
			else
				out[#out + 1] = c
			end
		end
		i = i + 1
	end
	return table.concat(out)
end

local encodeJson

local function jsonArray(t)
	return setmetatable(t or {}, { __jsonarray = true })
end

local function encodeTableAsObject(t, depth)
	local entries = {}
	for k, v in pairs(t) do
		entries[#entries + 1] = { key = tostring(k), value = v }
	end
	table.sort(entries, function(a, b) return a.key < b.key end)
	local parts = {}
	for i = 1, #entries do
		local e = entries[i]
		parts[#parts + 1] = '"' .. jsonEscape(e.key) .. '":' .. encodeJson(e.value, depth + 1)
	end
	return "{" .. table.concat(parts, ",") .. "}"
end

encodeJson = function(v, depth)
	depth = depth or 0
	local tv = type(v)
	if v == nil then return "null" end
	if tv == "boolean" then return v and "true" or "false" end
	if tv == "number" then
		if v ~= v or v == math.huge or v == -math.huge then return "null" end
		if v == math.floor(v) and math.abs(v) < 9007199254740992 then
			return string.format("%.0f", v)
		end
		return string.format("%.17g", v)
	end
	if tv == "string" then return '"' .. jsonEscape(v) .. '"' end
	if tv == "table" then
		if depth >= 8 then return '"<deep>"' end
		local mt = getmetatable(v)
		local forcedArray = type(mt) == "table" and mt.__jsonarray == true
		local isArray = true
		local count = 0
		for k in pairs(v) do
			count = count + 1
			if type(k) ~= "number" then isArray = false end
		end
		if count == 0 and not forcedArray then return "{}" end
		if isArray or forcedArray then
			local parts = {}
			for i = 1, #v do parts[#parts + 1] = encodeJson(v[i], depth + 1) end
			return "[" .. table.concat(parts, ",") .. "]"
		end
		return encodeTableAsObject(v, depth)
	end
	-- userdata / function / thread: keep something readable
	local ok, s = pcall(tostring, v)
	if ok and type(s) == "string" then return '"' .. jsonEscape(s) .. '"' end
	return '"<' .. tostring(tv) .. '>"'
end

-- ===========================================================================
-- output root + file plumbing
-- ===========================================================================
local workspacePath = nil
if fileApi.workspace ~= nil then
	local ok, p = pcall(fileApi.workspace)
	if ok and type(p) == "string" and #p > 0 then workspacePath = p end
end

local placeId = 0
if game ~= nil then
	local ok, v = pcall(function() return game.PlaceId end)
	if ok and type(v) == "number" then placeId = v end
end

local rootName = CFG.OutputFolderName .. "_" .. tostring(placeId) .. "_" .. makeStamp()
local rootPath = rootName
local filesWritten = {}
local dirsCreated = {}
local dirsMade = {}

local function ensureDirsFor(path)
	local idx = 1
	while true do
		local slash = path:find("/", idx, true)
		if slash == nil then break end
		local dir = path:sub(1, slash - 1)
		if not dirsMade[dir] then
			dirsMade[dir] = true
			dirsCreated[#dirsCreated + 1] = dir
			if fileApi.makeDir ~= nil then pcall(fileApi.makeDir, dir) end
		end
		idx = slash + 1
	end
end

local function writeWholeFile(path, data, kind)
	if fileApi.write == nil then return false, "writefile is not available" end
	ensureDirsFor(path)
	local ok, err = pcall(fileApi.write, path, tostring(data))
	if not ok then
		addError("files", "writefile failed for " .. tostring(path) .. ": " .. tostring(err))
		return false, tostring(err)
	end
	filesWritten[#filesWritten + 1] = { path = path, bytes = #tostring(data), kind = kind or "file" }
	return true
end

local FLUSH_SIZE = 256 * 1024

local function partName(path, index)
	local base, ext = path:match("^(.+)%.([%w]+)$")
	if base ~= nil then return base .. "_part" .. tostring(index) .. "." .. ext end
	return path .. "_part" .. tostring(index)
end

local function newWriter(path, appendFn, maxMem, split)
	local w = {
		path = path,
		append = appendFn,
		maxMem = maxMem or (96 * 1024 * 1024),
		split = split == true,
		buf = {},
		bufSize = 0,
		size = 0,
		aborted = false,
		failed = false,
		closed = false,
		partIndex = 0,
		appendWarned = false,
		files = {},
	}
	-- Xeno's appendfile refuses to create a missing file itself and raises
	-- "Expected File But Got Directory"; pre-create it with writefile first.
	if w.append ~= nil and fileApi.write ~= nil then
		local okCreate = pcall(fileApi.write, w.path, "")
		if not okCreate then w.append = nil end
	end
	function w.write(s)
		if w.closed or s == nil then return end
		local len = #s
		if len == 0 then return end
		w.size = w.size + len
		w.buf[#w.buf + 1] = s
		w.bufSize = w.bufSize + len
		if w.append ~= nil then
			if w.bufSize >= FLUSH_SIZE then
				local chunk = table.concat(w.buf)
				w.buf = {}
				w.bufSize = 0
				local ok, err = pcall(w.append, w.path, chunk)
				if not ok then
					if not w.appendWarned then
						w.appendWarned = true
						addWarning("files", "appendfile failed (" .. tostring(err)
							.. ") - switching to in-memory buffering")
					end
					w.append = nil
					w.failed = true
					table.insert(w.buf, 1, chunk)
					w.bufSize = w.bufSize + #chunk
					if w.bufSize > w.maxMem then
						w.aborted = true
						w.buf = {}
						w.bufSize = 0
					end
				end
			end
		elseif w.bufSize >= FLUSH_SIZE and w.split and w.size > w.maxMem then
			w.partIndex = w.partIndex + 1
			local p = partName(w.path, w.partIndex)
			writeWholeFile(p, table.concat(w.buf), "writer-part")
			w.files[#w.files + 1] = p
			w.buf = {}
			w.bufSize = 0
		elseif not w.split and w.size > w.maxMem then
			w.aborted = true
			w.buf = {}
			w.bufSize = 0
		end
	end
	function w.close()
		if w.closed then return w end
		w.closed = true
		if w.aborted then return w end
		if w.append ~= nil then
			if #w.buf > 0 then
				local ok, err = pcall(w.append, w.path, table.concat(w.buf))
				if not ok then
					w.append = nil
					w.failed = true
					if not w.appendWarned then
						w.appendWarned = true
						addWarning("files", "appendfile failed at close (" .. tostring(err)
							.. ") - writing the buffered XML with writefile")
					end
				end
			end
			w.buf = {}
			w.bufSize = 0
			if w.append ~= nil and not w.failed then
				w.files[#w.files + 1] = w.path
				return w
			end
		end
		if w.append == nil then
			local pending = table.concat(w.buf)
			w.buf = {}
			w.bufSize = 0
			if #pending > 0 or (#w.files == 0 and w.partIndex == 0) then
				local target = w.path
				if w.partIndex > 0 then
					w.partIndex = w.partIndex + 1
					target = partName(w.path, w.partIndex)
				end
				if writeWholeFile(target, pending, "writer") then
					w.files[#w.files + 1] = target
					w.failed = false
					w.recovered = true
				end
			end
		end
		return w
	end
	return w
end

-- ===========================================================================
-- live status files: STATUS.txt / ENV.txt / DONE.txt / FAILED.txt
-- (updated during the run, so even a killed thread leaves a readable trace)
-- ===========================================================================
local RUN = {
	state = "starting",
	phase = "prep",
	instances = 0,
	services = 0,
	skippedProtected = 0,
	streaming = nil,
	scriptsTotal = 0,
	scriptsDone = 0,
	scriptsSkipped = 0,
	xmlItems = 0,
	xmlBytes = 0,
	xmlMode = "none",
	placeMode = "none",       -- saveinstance | lua-xml | none
	placeFile = nil,
	nativePlaceFile = nil,
	safeMode = false,
	onlyPlace = false,
	saveinstancePath = nil,
	onlineRecovered = 0,
	jsonLines = 0,
	guis = 0,
	assetsFound = 0,
	assetsDone = 0,
	animations = 0,
	models = 0,
	memoryStopped = nil,
	pokeIdle = nil,
	idleConn = nil,
	lastPoke = nil,
}

local STATUS_PATH = rootPath .. "/STATUS.txt"
local ENV_PATH = rootPath .. "/ENV.txt"
local DONE_PATH = rootPath .. "/DONE.txt"
local FAILED_PATH = rootPath .. "/FAILED.txt"

local function rawWrite(path, text)
	if fileApi.write == nil then return false end
	ensureDirsFor(path)
	return pcall(fileApi.write, path, text)
end

local function buildStatusText()
	local lines = {
		"NyxDump " .. VERSION .. " status",
		"state: " .. tostring(RUN.state),
		"phase: " .. tostring(RUN.phase),
		"updated: " .. makeStamp(),
		"elapsedMs: " .. tostring(elapsedMs()),
		"output: " .. rootPath,
		"",
		"instances: " .. tostring(RUN.instances),
		"services: " .. tostring(RUN.services),
		"streaming: " .. tostring(RUN.streaming),
		"skippedProtected: " .. tostring(RUN.skippedProtected),
		"scripts: " .. tostring(RUN.scriptsDone) .. "/" .. tostring(RUN.scriptsTotal)
			.. " (skipped internals " .. tostring(RUN.scriptsSkipped) .. ")",
		"xmlItems: " .. tostring(RUN.xmlItems) .. " (" .. tostring(RUN.xmlMode) .. ")",
		"jsonlLines: " .. tostring(RUN.jsonLines),
		"guis: " .. tostring(RUN.guis),
		"assets: " .. tostring(RUN.assetsDone) .. "/" .. tostring(RUN.assetsFound),
		"",
		"state=done + DONE.txt mean it finished. Running state here means it was interrupted.",
	}
	if RUN.xmlBytes ~= nil and RUN.xmlBytes > 0 then
		lines[#lines + 1] = "xmlBytes: " .. tostring(RUN.xmlBytes)
	end
	return table.concat(lines, "\n") .. "\n"
end

local function setState(state, phase)
	RUN.state = state
	if phase ~= nil then RUN.phase = phase end
	if CFG.WriteStatus then rawWrite(STATUS_PATH, buildStatusText()) end
end

local function gcNow(where)
	pcall(function()
		if collectgarbage ~= nil then collectgarbage("collect") end
	end)
	RUN.lastGc = where or RUN.phase
end

local function clientMemoryMB()
	local ok, mb = pcall(function()
		return game:GetService("Stats"):GetTotalMemoryUsageMb()
	end)
	if ok and type(mb) == "number" then return mb end
	return nil
end

local function freeMemoryNow()
	-- Only Lua GC here. Do NOT call Set3dRenderingEnabled/setfpscap: on Xeno 0.745 with
	-- missing offsets those native calls themselves crash the client.
	gcNow("free_memory")
end

local function restoreRendering()
	-- kept for compatibility; rendering is not touched anymore
end

local function setupAntiIdle()
	if CFG.AntiIdle == false then return end
	local Players, VirtualUser = nil, nil
	pcall(function() Players = game:GetService("Players") end)
	pcall(function() VirtualUser = game:GetService("VirtualUser") end)
	local function poke()
		if VirtualUser ~= nil then
			pcall(function()
				VirtualUser:CaptureController()
				VirtualUser:ClickButton2(Vector2.new(0, 0))
			end)
		end
		RUN.lastPoke = os.clock()
	end
	RUN.pokeIdle = poke
	local lp = nil
	if Players ~= nil then lp = Players.LocalPlayer end
	if lp ~= nil and lp.Idled ~= nil then
		pcall(function()
			RUN.idleConn = lp.Idled:Connect(function()
				poke()
				say("anti-idle: server idle warning -> virtual input sent, no kick")
			end)
		end)
	end
	poke()
	say("anti-idle: enabled (the server will not kick you during the dump)")
end

local function progressStatus()
	if RUN.pokeIdle ~= nil and (RUN.lastPoke == nil or os.clock() - RUN.lastPoke > 240) then
		RUN.pokeIdle()
	end
	if CFG.WriteStatus then rawWrite(STATUS_PATH, buildStatusText()) end
end

local function featureFlag(fn)
	if fn ~= nil then return "yes" end
	return "no"
end

local function buildEnvText()
	local lines = {
		"NyxDump " .. VERSION .. " environment",
		"generated: " .. makeStamp(),
		"executor: " .. tostring(EXECUTOR_NAME or "unknown"),
		"placeId: " .. tostring(placeId),
		"output: " .. rootPath,
		"workspace: " .. tostring(workspacePath or "unknown"),
		"instances: " .. tostring(RUN.instances),
		"services: " .. tostring(RUN.services),
		"streaming: " .. tostring(RUN.streaming),
		"safe mode: " .. tostring(RUN.safeMode),
		"place mode: " .. tostring(RUN.placeMode),
		"place file: " .. tostring(RUN.placeFile or "-"),
		"native place file: " .. tostring(RUN.nativePlaceFile or "-"),
		"online recovered scripts: " .. tostring(RUN.onlineRecovered),
		"",
		"executor api:",
		"  writefile: " .. featureFlag(fileApi.write),
		"  appendfile: " .. featureFlag(fileApi.append),
		"  readfile: " .. featureFlag(fileApi.read),
		"  makefolder: " .. featureFlag(fileApi.makeDir),
		"  isfolder: " .. featureFlag(fileApi.isDir),
		"  isfile: " .. featureFlag(fileApi.isFile),
		"  listfiles: " .. featureFlag(fileApi.list),
		"  delfile: " .. featureFlag(fileApi.delete),
		"  getworkspace: " .. featureFlag(fileApi.workspace),
		"  decompile: " .. featureFlag(decompileFn) .. " (functions: " .. tostring(#decompileFns)
			.. ", attempts: " .. tostring(CFG.DecompileAttempts)
			.. ", pacing: " .. tostring(CFG.DecompileDelay) .. "s)",
		"  getscriptbytecode: " .. featureFlag(bytecodeFn),
		"  getproperties: " .. featureFlag(propertiesFn),
		"  getnilinstances: " .. featureFlag(nilInstancesFn),
		"  getloadedmodules: " .. featureFlag(loadedModulesFn),
		"  getscripts: " .. featureFlag(scriptsFn),
		"  getcustomasset: " .. featureFlag(customAssetFn),
		"  request: " .. featureFlag(requestFn),
		"  saveinstance: " .. featureFlag(saveInstanceFn),
		"",
		"config:",
		"  OnlyPlaceFile: " .. tostring(CFG.OnlyPlaceFile),
		"  DumpXml: " .. tostring(CFG.DumpXml),
		"  DumpScripts: " .. tostring(CFG.DumpScripts),
		"  SkipRobloxInternals: " .. tostring(CFG.SkipRobloxInternals),
		"  EmbedSourcesInPlace: " .. tostring(CFG.EmbedSourcesInPlace),
		"  SaveBytecode: " .. tostring(CFG.SaveBytecode),
		"  DumpJsonl: " .. tostring(CFG.DumpJsonl),
		"  DumpGuis: " .. tostring(CFG.DumpGuis),
		"  DownloadAssets: " .. tostring(CFG.DownloadAssets),
		"  AssetLimit: " .. tostring(CFG.AssetLimit),
		"  XmlMemoryLimitMB: " .. tostring(CFG.XmlMemoryLimitMB),
		"  SafeMode: " .. tostring(CFG.SafeMode),
		"  UseSaveInstance: " .. tostring(CFG.UseSaveInstance),
		"  AlwaysBuildLuaXml: " .. tostring(CFG.AlwaysBuildLuaXml),
		"  OnlineDecompile: " .. tostring(CFG.OnlineDecompile),
		"  OnlineDecompileLimit: " .. tostring(CFG.OnlineDecompileLimit),
		"  OnlyPlaceFile: " .. tostring(CFG.OnlyPlaceFile),
		"  AntiIdle: " .. tostring(CFG.AntiIdle),
		"  MaxInstances: " .. tostring(CFG.MaxInstances),
	}
	if fileApi.append == nil then
		lines[#lines + 1] = ""
		lines[#lines + 1] = "note: appendfile is missing - the place XML is built in memory (limit "
			.. tostring(CFG.XmlMemoryLimitMB) .. " MB). If the game is bigger, the dump falls back to"
			.. " per-service Xml/*.rbxmx models instead of one Game.rbxlx."
	end
	if decompileFn == nil then
		lines[#lines + 1] = "note: decompile is missing - scripts are saved as .bytecode only."
	end
	if CFG.SafeMode then
		lines[#lines + 1] = ""
		lines[#lines + 1] = "note: SafeMode is ON - no saveinstance/decompile/getnilinstances/getproperties"
		lines[#lines + 1] = "      calls are made, so a stale executor build cannot crash the client."
		lines[#lines + 1] = "      Set SafeMode=false once your executor supports the current Roblox version."
	end
	return table.concat(lines, "\n") .. "\n"
end

local function writeEnvFile()
	writeWholeFile(ENV_PATH, buildEnvText(), "env")
end

local function writeDoneFile(summary)
	local lines = {
		"NyxDump " .. VERSION .. " DONE",
		"generated: " .. makeStamp(),
		"elapsedMs: " .. tostring(elapsedMs()),
		"output: " .. rootPath,
		"",
		summary and encodeJson(summary) or "{}",
	}
	rawWrite(DONE_PATH, table.concat(lines, "\n") .. "\n")
end

local function writeFailedFile(err)
	local lines = {
		"NyxDump " .. VERSION .. " FAILED",
		"phase: " .. tostring(RUN.phase),
		"elapsedMs: " .. tostring(elapsedMs()),
		"output: " .. rootPath,
		"error: " .. tostring(err),
	}
	rawWrite(FAILED_PATH, table.concat(lines, "\n") .. "\n")
end

-- ===========================================================================
-- place-file helpers: executor-native saveinstance + online decompiler calls
-- ===========================================================================
local function base64Encode(s)
	local chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
	local out = {}
	local n = #s
	local i = 1
	while i <= n do
		local b1 = s:byte(i)
		local b2 = nil
		local b3 = nil
		if i + 1 <= n then b2 = s:byte(i + 1) end
		if i + 2 <= n then b3 = s:byte(i + 2) end
		local c1 = math.floor(b1 / 4) + 1
		local c2 = (b1 % 4) * 16 + (b2 ~= nil and math.floor(b2 / 16) or 0) + 1
		local c3 = 0
		local c4 = 0
		if b2 ~= nil then
			c3 = (b2 % 16) * 4 + (b3 ~= nil and math.floor(b3 / 64) or 0) + 1
		end
		if b3 ~= nil then
			c4 = (b3 % 64) + 1
		end
		local chunk = chars:sub(c1, c1) .. chars:sub(c2, c2)
		chunk = chunk .. (c3 ~= 0 and chars:sub(c3, c3) or "=")
		chunk = chunk .. (c4 ~= 0 and chars:sub(c4, c4) or "=")
		out[#out + 1] = chunk
		i = i + 3
	end
	return table.concat(out)
end

local function httpPostJson(url, body)
	if requestFn == nil then return nil, "request is not available" end
	local options = {
		Url = url,
		Method = "POST",
		Headers = { ["Content-Type"] = "application/json" },
		Body = body,
	}
	local ok, res = pcall(requestFn, options)
	if not ok or res == nil then return nil, tostring(res) end
	if type(res) == "string" then return res end
	if type(res) == "table" then
		local code = res.StatusCode or res.Status or res.status or res.statusCode
		local bodyRes = res.Body or res.body or res.BodyData or res.data
		if type(bodyRes) == "table" then bodyRes = bodyRes.body or bodyRes.Body end
		if type(bodyRes) == "string" then
			if code ~= nil and tonumber(code) ~= 200 then return nil, "HTTP " .. tostring(code) end
			return bodyRes
		end
	end
	return nil, "unexpected response shape"
end

local function listWorkspaceFilesSafe()
	local out = {}
	if fileApi.list == nil then return out end
	local folders = { ".", "", "/" }
	for i = 1, #folders do
		local ok, list = pcall(fileApi.list, folders[i])
		if ok and type(list) == "table" then
			for j = 1, #list do
				if type(list[j]) == "string" then out[#out + 1] = list[j] end
			end
		end
	end
	return out
end

local function pathKey(path)
	return (tostring(path):gsub("\\", "/")):lower()
end

local function choosePlaceFileName(data)
	local head = data:sub(1, 512)
	if head:sub(1, 3) == "\239\187\191" then head = head:sub(4) end
	if head:sub(1, 8) == "<roblox!" then return "Game.rbxl" end
	if head:find("<roblox", 1, true) ~= nil then return "Game.rbxlx" end
	return "Game.rbxlx"
end

local function looksLikePlaceFile(data)
	local head = data:sub(1, 512)
	if head:sub(1, 3) == "\239\187\191" then head = head:sub(4) end
	if head:sub(1, 8) == "<roblox!" then return true end
	return head:find("<roblox", 1, true) ~= nil
end

local function savePlaceData(data, kind)
	if type(data) ~= "string" or #data == 0 then return nil end
	local name = choosePlaceFileName(data)
	if kind == "saveinstance" then
		if name == "Game.rbxl" then name = "Game_native.rbxl" else name = "Game_native.rbxlx" end
	end
	local target = rootPath .. "/" .. name
	if writeWholeFile(target, data, "place") then
		if kind == "saveinstance" then
			RUN.nativePlaceFile = target
			if RUN.xmlMode ~= "none" then
				RUN.placeMode = "saveinstance+lua-xml"
			else
				RUN.placeMode = "saveinstance"
			end
		else
			RUN.placeFile = target
			RUN.placeMode = kind or "lua-xml"
		end
		return target
	end
	return nil
end

-- Uses the executor's own serializer (saveinstance) when it exists: this produces a
-- genuinely loadable Roblox place file instead of our hand-written XML.
local function trySaveInstance()
	if saveInstanceFn == nil then return nil, "saveinstance is not available" end
	if CFG.SafeMode then return nil, "SafeMode" end
	say("saveinstance: native place dump started (the client may freeze for a while)...")
	setState("running", "saveinstance")
	local started = elapsedMs()
	local before = {}
	for _, p in ipairs(listWorkspaceFilesSafe()) do before[pathKey(p)] = true end
	local ok, res = pcall(saveInstanceFn)
	local err = nil
	if not ok then err = tostring(res) end

	-- some builds return the file contents / path directly
	if ok and type(res) == "string" and #res > 16 then
		local data = res
		if not looksLikePlaceFile(data) and #data < 512 then
			if fileApi.read ~= nil then
				local okR, readBack = pcall(fileApi.read, data)
				if okR and type(readBack) == "string" then data = readBack end
			end
		end
		if looksLikePlaceFile(data) then
			local target = savePlaceData(data, "saveinstance")
			if target ~= nil then
				say("saveinstance done in " .. tostring(math.floor((elapsedMs() - started) / 100) / 10)
					.. "s -> " .. target)
				return target, nil
			end
		end
	end

	-- otherwise find the file saveinstance wrote into the workspace
	local found = nil
	for attempt = 1, 20 do
		if waitFunction ~= nil then pcall(waitFunction, 0.5) end
		local after = listWorkspaceFilesSafe()
		for _, p in ipairs(after) do
			local key = pathKey(p)
			if not before[key] then
				if key:sub(-6) == ".rbxlx" or key:sub(-5) == ".rbxl" or key:sub(-5) == ".rbxm" then
					found = p
					break
				end
			end
		end
		if found ~= nil then break end
	end
	if found ~= nil and fileApi.read ~= nil then
		local okR, data = pcall(fileApi.read, found)
		if okR and type(data) == "string" and looksLikePlaceFile(data) then
			local target = savePlaceData(data, "saveinstance")
			if target ~= nil then
				RUN.saveinstancePath = found
				say("saveinstance done in " .. tostring(math.floor((elapsedMs() - started) / 100) / 10)
					.. "s -> " .. target)
				return target, nil
			end
			err = "saveinstance output could not be copied"
		else
			err = "saveinstance output could not be read"
		end
	elseif found == nil then
		-- last resort: known default names used by executor implementations
		local gameName = ""
		if game ~= nil then
			local okN, nm = pcall(function() return game.Name end)
			if okN and type(nm) == "string" then
				gameName = nm:gsub("[^%w_%.%- ]", ""):gsub("%s+", "_")
			end
		end
		local candidates = {
			tostring(placeId) .. ".rbxlx", tostring(placeId) .. ".rbxl",
			"saveinstance.rbxlx", "saveinstance.rbxl", "game.rbxlx", "Game.rbxlx",
			"place.rbxlx", "dump.rbxlx",
		}
		if #gameName > 0 then
			candidates[#candidates + 1] = gameName .. ".rbxlx"
			candidates[#candidates + 1] = gameName .. ".rbxl"
		end
		if fileApi.read ~= nil then
			for i = 1, #candidates do
				local okR, data = pcall(fileApi.read, candidates[i])
				if okR and type(data) == "string" and looksLikePlaceFile(data) then
					local target = savePlaceData(data, "saveinstance")
					if target ~= nil then
						RUN.saveinstancePath = candidates[i]
						say("saveinstance -> " .. target)
						return target, nil
					end
				end
			end
		end
		if err == nil then err = "saveinstance did not produce a .rbxl/.rbxlx file" end
	end
	addWarning("saveinstance", tostring(err))
	say("saveinstance failed: " .. tostring(err) .. " (falling back to built-in XML)")
	return nil, err
end

-- ===========================================================================
-- path sanitising
-- ===========================================================================
local RESERVED_NAMES = {}
do
	local names = {
		"CON", "PRN", "AUX", "NUL",
		"COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9",
		"LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9",
	}
	for i = 1, #names do RESERVED_NAMES[names[i]] = true end
end

local usedPaths = {}

-- transliteration for Cyrillic so output paths stay ASCII on every filesystem
local CYR = {
	[0x401] = "Yo", [0x404] = "Ye", [0x406] = "I", [0x407] = "Yi", [0x410] = "A",
	[0x411] = "B", [0x412] = "V", [0x413] = "G", [0x414] = "D", [0x415] = "E",
	[0x416] = "Zh", [0x417] = "Z", [0x418] = "I", [0x419] = "Y", [0x41A] = "K",
	[0x41B] = "L", [0x41C] = "M", [0x41D] = "N", [0x41E] = "O", [0x41F] = "P",
	[0x420] = "R", [0x421] = "S", [0x422] = "T", [0x423] = "U", [0x424] = "F",
	[0x425] = "Kh", [0x426] = "Ts", [0x427] = "Ch", [0x428] = "Sh", [0x429] = "Shch",
	[0x42A] = "", [0x42B] = "Y", [0x42C] = "", [0x42D] = "E", [0x42E] = "Yu",
	[0x42F] = "Ya", [0x430] = "a", [0x431] = "b", [0x432] = "v", [0x433] = "g",
	[0x434] = "d", [0x435] = "e", [0x436] = "zh", [0x437] = "z", [0x438] = "i",
	[0x439] = "y", [0x43A] = "k", [0x43B] = "l", [0x43C] = "m", [0x43D] = "n",
	[0x43E] = "o", [0x43F] = "p", [0x440] = "r", [0x441] = "s", [0x442] = "t",
	[0x443] = "u", [0x444] = "f", [0x445] = "kh", [0x446] = "ts", [0x447] = "ch",
	[0x448] = "sh", [0x449] = "shch", [0x44A] = "", [0x44B] = "y", [0x44C] = "",
	[0x44D] = "e", [0x44E] = "yu", [0x44F] = "ya", [0x451] = "yo", [0x454] = "ye",
	[0x456] = "i", [0x457] = "yi", [0x490] = "G", [0x491] = "g",
}

local function sanitizeSegment(name)
	local s = tostring(name or "")
	if #s == 0 then return "unnamed" end
	local out = {}
	local i = 1
	local n = #s
	while i <= n do
		local b = s:byte(i)
		if b < 0x80 then
			local c = s:sub(i, i)
			if b < 32 or b == 127 then
				out[#out + 1] = "_"
			elseif c == "<" or c == ">" or c == ":" or c == '"' or c == "/" or c == "\\"
				or c == "|" or c == "?" or c == "*" then
				out[#out + 1] = "_"
			else
				out[#out + 1] = c
			end
			i = i + 1
		elseif b <= 0xDF and i + 1 <= n then
			local b2 = s:byte(i + 1)
			if b2 >= 0x80 and b2 <= 0xBF then
				local cp = (b - 0xC0) * 64 + (b2 - 0x80)
				local mapped = CYR[cp]
				if mapped == nil then
					out[#out + 1] = "_"
				elseif #mapped > 0 then
					out[#out + 1] = mapped
				end
				i = i + 2
			else
				out[#out + 1] = "_"
				i = i + 1
			end
		else
			-- 3/4 byte UTF-8 (emoji etc.) or stray byte: one placeholder per sequence
			out[#out + 1] = "_"
			i = i + 1
			while i <= n do
				local b2 = s:byte(i)
				if b2 >= 0x80 and b2 <= 0xBF then i = i + 1 else break end
			end
		end
	end
	local result = table.concat(out)
	result = result:gsub("%s+", " ")
	result = result:gsub("^%s+", "")
	result = result:gsub("%s+$", "")
	result = result:gsub("^%.+", "_")
	result = result:gsub("%.+$", "")
	if #result == 0 then result = "unnamed" end
	if RESERVED_NAMES[result:upper()] then result = "_" .. result end
	if #result > CFG.MaxSegmentLength then
		result = result:sub(1, CFG.MaxSegmentLength)
	end
	return result
end

local usedDirs = {}

local function allocatePath(dir, baseName, ext, seed)
	local name = sanitizeSegment(baseName)
	local extPart = ext or ""
	local candidate = dir .. "/" .. name .. extPart
	local key = candidate:lower()
	if usedPaths[key] then
		local suffix = tostring(seed or 1)
		candidate = dir .. "/" .. name .. "_" .. suffix .. extPart
		key = candidate:lower()
		local tries = 0
		while usedPaths[key] and tries < 10000 do
			tries = tries + 1
			candidate = dir .. "/" .. name .. "_" .. suffix .. "_" .. tostring(tries) .. extPart
			key = candidate:lower()
		end
	end
	usedPaths[key] = true
	local parent = dir:lower()
	usedDirs[parent] = (usedDirs[parent] or 0) + 1
	return candidate
end

-- ===========================================================================
-- instance collection
-- ===========================================================================
local entries = {}
local indexOf = {}
local children = {}
local serviceRoots = {}
local classSamples = {}
local classIsACache = {}
local skippedProtected = 0
local truncated = false
local collectTicks = 0

local function yieldNow()
	if waitFunction ~= nil then pcall(waitFunction, 0) end
end

local function tick()
	collectTicks = collectTicks + 1
	if CFG.YieldEvery > 0 and collectTicks % CFG.YieldEvery == 0 then
		yieldNow()
	end
	if CFG.SlowMode and collectTicks % 25 == 0 then
		task.wait(0.005 + math.random() * 0.02)
	end
end

local function addEntry(inst, parentIdx, isNilRoot)
	if inst == nil then return nil end
	if RUN.memoryStopped ~= nil then return nil end
	local existing = indexOf[inst]
	if existing ~= nil then return existing end
	if CFG.MaxInstances > 0 and #entries >= CFG.MaxInstances then
		truncated = true
		return nil
	end
	local cls = classNameOf(inst)
	if cls == nil then
		skippedProtected = skippedProtected + 1
		return nil
	end
	local name = nameOf(inst)
	local index = #entries + 1
	local depth = 1
	if parentIdx ~= nil and parentIdx > 0 and entries[parentIdx] ~= nil then
		depth = entries[parentIdx].depth + 1
	end
	local entry = {
		inst = inst,
		parent = parentIdx or -1,
		name = name,
		class = cls,
		depth = depth,
		nilRoot = isNilRoot == true,
		index = index,
	}
	entries[index] = entry
	indexOf[inst] = index
	if classSamples[cls] == nil then classSamples[cls] = inst end
	tick()
	if CFG.ProgressEvery > 0 and index % CFG.ProgressEvery == 0 then
		RUN.instances = index
		say("collect: " .. tostring(index) .. " instances")
		progressStatus()
	end
	if index % 5000 == 0 and (CFG.MemoryStopMB or 0) > 0 then
		local mem = clientMemoryMB()
		if mem ~= nil and mem > CFG.MemoryStopMB then
			truncated = true
			RUN.memoryStopped = mem
			say(string.format("memory guard: %.0f MB - stopping collection early to avoid a crash", mem))
		end
		gcNow("collect")
	end
	return index
end

local function collectDescendantsFast(rootInst, rootIdx)
	local ok, descs = pcall(function() return rootInst:GetDescendants() end)
	if not ok or type(descs) ~= "table" then
		return false
	end
	for i = 1, #descs do
		local inst = descs[i]
		if isInstance(inst) then
			local parentObj = prop(inst, "Parent")
			local parentIdx = nil
			if isInstance(parentObj) then parentIdx = indexOf[parentObj] end
			if parentIdx == nil then parentIdx = rootIdx end
			addEntry(inst, parentIdx, false)
		end
	end
	return true
end

local function collectDescendantsDeep(rootInst, rootIdx, depth)
	if depth > 100 then return end
	local ok, kids = pcall(function() return rootInst:GetChildren() end)
	if not ok or type(kids) ~= "table" then
		addWarning("collect", "cannot enumerate children of " .. tostring(rootIdx))
		return
	end
	for i = 1, #kids do
		local inst = kids[i]
		if isInstance(inst) then
			local idx = addEntry(inst, rootIdx, false)
			if idx ~= nil then
				collectDescendantsDeep(inst, idx, depth + 1)
			end
		end
	end
end

local function classIsA(cls, target)
	local row = classIsACache[cls]
	if row == nil then
		row = {}
		classIsACache[cls] = row
	end
	local v = row[target]
	if v ~= nil then return v end
	local sample = classSamples[cls]
	if sample == nil then
		row[target] = false
		return false
	end
	local ok, res = pcall(function() return sample:IsA(target) end)
	v = (ok and res == true)
	row[target] = v
	return v
end

local function classIn(cls, list)
	for i = 1, #list do
		if cls == list[i] then return true end
	end
	return false
end

-- ===========================================================================
-- property tables (name:xmltype) - types mirror the Roblox XML format
-- ===========================================================================
local function parseProps(spec)
	local out = {}
	for item in spec:gmatch("[^,]+") do
		local name, typ = item:match("^%s*([^:]+):(.+)%s*$")
		if name ~= nil and typ ~= nil then
			out[#out + 1] = { n = name, t = typ }
		end
	end
	return out
end

local PROP = {
	common = parseProps("Name:string"),
	part = parseProps("CFrame:CoordinateFrame,Size:Vector3,Color:Color3,Transparency:float,Reflectance:float,Anchored:bool,CanCollide:bool,CastShadow:bool,CanQuery:bool,CanTouch:bool,Massless:bool,Locked:bool,Material:token,CollisionGroup:string"),
	partOnly = parseProps("Shape:token"),
	mesh = parseProps("MeshId:Content,TextureID:Content,RenderFidelity:token,DoubleSided:bool"),
	specialMesh = parseProps("MeshId:Content,TextureId:Content,Scale:Vector3,MeshType:token,Offset:Vector3"),
	fileMesh = parseProps("MeshId:Content,TextureId:Content"),
	model = parseProps("PrimaryPart:Ref"),
	scriptObj = parseProps("Disabled:bool"),
	guiBase = parseProps("Size:UDim2,Position:UDim2,AnchorPoint:Vector2,Visible:bool,BackgroundColor3:Color3,BackgroundTransparency:float,BorderColor3:Color3,BorderSizePixel:int,ZIndex:int,Rotation:float,ClipsDescendants:bool,LayoutOrder:int,AutomaticSize:token"),
	guiButton = parseProps("AutoButtonColor:bool"),
	text = parseProps("Text:string,TextColor3:Color3,TextTransparency:float,TextSize:float,TextScaled:bool,TextWrapped:bool,RichText:bool,TextXAlignment:token,TextYAlignment:token,Font:token,TextStrokeColor3:Color3,TextStrokeTransparency:float,TextTruncate:token,LineHeight:float,MaxVisibleGraphemes:int"),
	textBox = parseProps("PlaceholderText:string,PlaceholderColor3:Color3,ClearTextOnFocus:bool,MultiLine:bool,TextEditable:bool"),
	image = parseProps("Image:Content,ImageColor3:Color3,ImageTransparency:float,ImageRectOffset:Vector2,ImageRectSize:Vector2,ScaleType:token,SliceCenter:Rect2D,SliceScale:float,TileSize:UDim2,ResampleMode:token"),
	layer = parseProps("Enabled:bool,ZIndexBehavior:token,ResetOnSpawn:bool"),
	screenGui = parseProps("DisplayOrder:int,IgnoreGuiInset:bool"),
	surfaceGui = parseProps("Face:token,SizingMode:token,PixelsPerStud:float,CanvasSize:Vector2,AlwaysOnTop:bool,LightInfluence:float,Brightness:float,Adornee:Ref"),
	billboardGui = parseProps("Size:UDim2,StudsOffset:Vector3,AlwaysOnTop:bool,ExtentsOffset:Vector3,MaxDistance:float,Adornee:Ref"),
	scrolling = parseProps("CanvasSize:UDim2,CanvasPosition:Vector2,ScrollBarThickness:int,ScrollingEnabled:bool,ScrollingDirection:token,ElasticBehavior:token,AutomaticCanvasSize:token,ScrollBarImageColor3:Color3,ScrollBarImageTransparency:float,VerticalScrollBarInset:token,HorizontalScrollBarInset:token"),
	sound = parseProps("SoundId:Content,Volume:float,Looped:bool,PlaybackSpeed:float,Playing:bool,RollOffMode:token,RollOffMinDistance:float,RollOffMaxDistance:float"),
	decal = parseProps("Texture:Content,Color3:Color3,Transparency:float,Face:token,ZIndex:int"),
	texture = parseProps("StudsPerTileU:float,StudsPerTileV:float,OffsetStudsU:float,OffsetStudsV:float"),
	light = parseProps("Brightness:float,Color:Color3,Enabled:bool,Shadows:bool"),
	pointLight = parseProps("Range:float"),
	spotLight = parseProps("Angle:float,Face:token,Range:float"),
	surfaceLight = parseProps("Angle:float,Face:token,Range:float"),
	particle = parseProps("Texture:Content,Rate:float,Enabled:bool,Lifetime:NumberRange,Speed:NumberRange,Size:NumberSequence,Transparency:NumberSequence,Color:ColorSequence,LightEmission:float,LightInfluence:float,EmissionDirection:token,Rotation:NumberRange,RotSpeed:NumberRange,SpreadAngle:Vector2,Acceleration:Vector3,LockedToPart:bool,ZOffset:float,Shape:token,ShapeStyle:token,ShapeInOut:token,ShapePartial:float,Squash:NumberSequence"),
	beam = parseProps("Texture:Content,Color:ColorSequence,Transparency:NumberSequence,Width0:float,Width1:float,CurveSize0:float,CurveSize1:float,LightEmission:float,LightInfluence:float,TextureLength:float,TextureSpeed:float,FaceCamera:bool,Segments:int,Enabled:bool,Attachment0:Ref,Attachment1:Ref"),
	trail = parseProps("Texture:Content,Color:ColorSequence,Transparency:NumberSequence,Lifetime:float,MinLength:float,FaceCamera:bool,LightEmission:float,WidthScale:NumberSequence,TextureLength:float,TextureMode:token,Attachment0:Ref,Attachment1:Ref"),
	attachment = parseProps("CFrame:CoordinateFrame,Visible:bool"),
	camera = parseProps("CFrame:CoordinateFrame,Focus:CoordinateFrame,FieldOfView:float,CameraType:token,CameraSubject:Ref"),
	humanoid = parseProps("DisplayName:string,MaxHealth:float,WalkSpeed:float,JumpPower:float,JumpHeight:float,HipHeight:float,AutoRotate:bool,UseJumpPower:bool,HealthDisplayDistance:float,NameDisplayDistance:float"),
	animation = parseProps("AnimationId:Content"),
	sky = parseProps("SkyboxBk:Content,SkyboxDn:Content,SkyboxFt:Content,SkyboxLf:Content,SkyboxRt:Content,SkyboxUp:Content,StarCount:int"),
	atmosphere = parseProps("Density:float,Offset:float,Color:Color3,Decay:Color3,Glare:float,Haze:float"),
	lighting = parseProps("Ambient:Color3,OutdoorAmbient:Color3,Brightness:float,ClockTime:float,GeographicLatitude:float,ColorShift_Top:Color3,ColorShift_Bottom:Color3,EnvironmentDiffuseScale:float,EnvironmentSpecularScale:float,ExposureCompensation:float,FogColor:Color3,FogEnd:float,FogStart:float,GlobalShadows:bool,ShadowSoftness:float,TimeOfDay:string"),
	workspace = parseProps("Gravity:float,FallenPartsDestroyHeight:float,StreamingEnabled:bool,StreamingMinRadius:int,StreamingTargetRadius:int"),
	terrain = parseProps("WaterColor:Color3,WaterTransparency:float,WaterWaveSize:float,WaterWaveSpeed:float"),
	bodyColors = parseProps("HeadColor3:Color3,TorsoColor3:Color3,LeftArmColor3:Color3,RightArmColor3:Color3,LeftLegColor3:Color3,RightLegColor3:Color3"),
	tool = parseProps("TextureId:Content,CanBeDropped:bool,RequiresHandle:bool,ToolTip:string"),
	proximityPrompt = parseProps("ActionText:string,ObjectText:string,HoldDuration:float,MaxActivationDistance:float,RequiresLineOfSight:bool,Enabled:bool,Style:token,KeyboardKeyCode:token,GamepadKeyCode:token,UIOffset:Vector2"),
	clickDetector = parseProps("MaxActivationDistance:float"),
	uiListLayout = parseProps("Padding:UDim,FillDirection:token,HorizontalAlignment:token,VerticalAlignment:token,SortOrder:token,Wraps:bool"),
	uiGridLayout = parseProps("CellSize:UDim2,CellPadding:UDim2,FillDirection:token,SortOrder:token,StartCorner:token,FillDirectionMaxCells:int"),
	uiTableLayout = parseProps("FillDirection:token,FillEmptySpaceColumns:bool,FillEmptySpaceRows:bool,MajorAxis:token,SortOrder:token"),
	uiPadding = parseProps("PaddingTop:UDim,PaddingBottom:UDim,PaddingLeft:UDim,PaddingRight:UDim"),
	uiCorner = parseProps("CornerRadius:UDim"),
	uiStroke = parseProps("Color:Color3,Thickness:float,Transparency:float,ApplyStrokeMode:token,LineJoinMode:token,Enabled:bool"),
	uiGradient = parseProps("Color:ColorSequence,Transparency:NumberSequence,Rotation:float,Offset:Vector2,Enabled:bool"),
	uiScale = parseProps("Scale:float"),
	uiAspectRatio = parseProps("AspectRatio:float,AspectType:token,DominantAxis:token"),
	uiSizeConstraint = parseProps("MaxSize:Vector2,MinSize:Vector2"),
	uiTextSizeConstraint = parseProps("MaxTextSize:int,MinTextSize:int"),
	viewportFrame = parseProps("Ambient:Color3,LightColor:Color3,LightDirection:Vector3,ImageColor3:Color3,ImageTransparency:float"),
	canvasGroup = parseProps("GroupTransparency:float"),
	surfaceAppearance = parseProps("AlphaMode:token,EmissiveStrength:float,EmissiveTint:Color3"),
	shirt = parseProps("ShirtTemplate:Content"),
	pants = parseProps("PantsTemplate:Content"),
}

local LAYERS = {
	{ target = "BasePart", props = PROP.part },
	{ classes = { "Part" }, props = PROP.partOnly },
	{ target = "MeshPart", props = PROP.mesh },
	{ classes = { "SpecialMesh" }, props = PROP.specialMesh },
	{ classes = { "FileMesh" }, props = PROP.fileMesh },
	{ classes = { "Model" }, props = PROP.model },
	{ target = "BaseScript", props = PROP.scriptObj },
	{ target = "GuiObject", props = PROP.guiBase },
	{ target = "GuiButton", props = PROP.guiButton },
	{ classes = { "TextLabel", "TextButton" }, props = PROP.text },
	{ classes = { "TextBox" }, props = PROP.text },
	{ classes = { "TextBox" }, props = PROP.textBox },
	{ classes = { "ImageLabel", "ImageButton" }, props = PROP.image },
	{ target = "LayerCollector", props = PROP.layer },
	{ classes = { "ScreenGui" }, props = PROP.screenGui },
	{ classes = { "SurfaceGui" }, props = PROP.surfaceGui },
	{ classes = { "BillboardGui" }, props = PROP.billboardGui },
	{ target = "ScrollingFrame", props = PROP.scrolling },
	{ target = "Sound", props = PROP.sound },
	{ target = "Decal", props = PROP.decal },
	{ target = "Texture", props = PROP.texture },
	{ target = "Light", props = PROP.light },
	{ classes = { "PointLight" }, props = PROP.pointLight },
	{ classes = { "SpotLight" }, props = PROP.spotLight },
	{ classes = { "SurfaceLight" }, props = PROP.surfaceLight },
	{ classes = { "ParticleEmitter" }, props = PROP.particle },
	{ classes = { "Beam" }, props = PROP.beam },
	{ classes = { "Trail" }, props = PROP.trail },
	{ classes = { "Attachment" }, props = PROP.attachment },
	{ classes = { "Camera" }, props = PROP.camera },
	{ target = "Humanoid", props = PROP.humanoid },
	{ classes = { "Animation" }, props = PROP.animation },
	{ classes = { "Sky" }, props = PROP.sky },
	{ classes = { "Atmosphere" }, props = PROP.atmosphere },
	{ classes = { "Lighting" }, props = PROP.lighting },
	{ classes = { "Workspace" }, props = PROP.workspace },
	{ classes = { "Terrain" }, props = PROP.terrain },
	{ classes = { "BodyColors" }, props = PROP.bodyColors },
	{ target = "Tool", props = PROP.tool },
	{ classes = { "ProximityPrompt" }, props = PROP.proximityPrompt },
	{ classes = { "ClickDetector" }, props = PROP.clickDetector },
	{ classes = { "UIListLayout" }, props = PROP.uiListLayout },
	{ classes = { "UIGridLayout" }, props = PROP.uiGridLayout },
	{ classes = { "UITableLayout" }, props = PROP.uiTableLayout },
	{ classes = { "UIPadding" }, props = PROP.uiPadding },
	{ classes = { "UICorner" }, props = PROP.uiCorner },
	{ classes = { "UIStroke" }, props = PROP.uiStroke },
	{ classes = { "UIGradient" }, props = PROP.uiGradient },
	{ classes = { "UIScale" }, props = PROP.uiScale },
	{ classes = { "UIAspectRatioConstraint" }, props = PROP.uiAspectRatio },
	{ classes = { "UISizeConstraint" }, props = PROP.uiSizeConstraint },
	{ classes = { "UITextSizeConstraint" }, props = PROP.uiTextSizeConstraint },
	{ classes = { "ViewportFrame" }, props = PROP.viewportFrame },
	{ classes = { "CanvasGroup" }, props = PROP.canvasGroup },
	{ classes = { "SurfaceAppearance" }, props = PROP.surfaceAppearance },
	{ classes = { "Shirt" }, props = PROP.shirt },
	{ classes = { "Pants" }, props = PROP.pants },
}

local propListCache = {}

local function getPropList(cls)
	local cached = propListCache[cls]
	if cached ~= nil then return cached end
	local list, seen = {}, {}
	local function add(props)
		for i = 1, #props do
			local p = props[i]
			if not seen[p.n] then
				seen[p.n] = true
				list[#list + 1] = p
			end
		end
	end
	add(PROP.common)
	for i = 1, #LAYERS do
		local layer = LAYERS[i]
		local match = false
		if layer.target ~= nil then
			match = classIsA(cls, layer.target)
		elseif layer.classes ~= nil then
			match = classIn(cls, layer.classes)
		end
		if match then add(layer.props) end
	end
	propListCache[cls] = list
	return list
end

-- ===========================================================================
-- XML value formatting
-- ===========================================================================
local function xmlText(s)
	s = tostring(s or "")
	local needFilter = s:find("%c") ~= nil
	if needFilter then
		local out = {}
		for i = 1, #s do
			local b = s:byte(i)
			if b == 9 or b == 10 or b == 13 or (b >= 32 and b ~= 127) then
				out[#out + 1] = s:sub(i, i)
			end
		end
		s = table.concat(out)
	end
	s = s:gsub("&", "&amp;")
	s = s:gsub("<", "&lt;")
	s = s:gsub(">", "&gt;")
	s = s:gsub('"', "&quot;")
	return s
end

local XML_TAGS = {
	bool = "bool", int = "int", int64 = "int64", float = "float", double = "double",
	string = "string", token = "token", Vector3 = "Vector3", Vector2 = "Vector2",
	CoordinateFrame = "CoordinateFrame", Color3 = "Color3", UDim = "UDim", UDim2 = "UDim2",
	Rect2D = "Rect2D", NumberRange = "NumberRange", NumberSequence = "NumberSequence",
	ColorSequence = "ColorSequence", Content = "Content", ProtectedString = "ProtectedString",
	Ref = "Ref",
}

local function vector3Xml(v)
	local x, y, z = objField(v, "X"), objField(v, "Y"), objField(v, "Z")
	if type(x) ~= "number" or type(y) ~= "number" or type(z) ~= "number" then return nil end
	return "<X>" .. fmtFloat(x) .. "</X><Y>" .. fmtFloat(y) .. "</Y><Z>" .. fmtFloat(z) .. "</Z>"
end

local function vector2Xml(v)
	local x, y = objField(v, "X"), objField(v, "Y")
	if type(x) ~= "number" or type(y) ~= "number" then return nil end
	return "<X>" .. fmtFloat(x) .. "</X><Y>" .. fmtFloat(y) .. "</Y>"
end

local function cframeXml(v)
	local ok, x, y, z, r00, r01, r02, r10, r11, r12, r20, r21, r22 =
		pcall(function() return v:GetComponents() end)
	if not ok or type(x) ~= "number" then return nil end
	local nums = { x, y, z, r00, r01, r02, r10, r11, r12, r20, r21, r22 }
	local names = { "X", "Y", "Z", "R00", "R01", "R02", "R10", "R11", "R12", "R20", "R21", "R22" }
	local out = {}
	for i = 1, 12 do
		local s = fmtFloat(nums[i])
		if s == nil then return nil end
		out[#out + 1] = "<" .. names[i] .. ">" .. s .. "</" .. names[i] .. ">"
	end
	return table.concat(out)
end

local function color3Xml(v)
	local r, g, b = objField(v, "R"), objField(v, "G"), objField(v, "B")
	if type(r) ~= "number" or type(g) ~= "number" or type(b) ~= "number" then return nil end
	return "<R>" .. fmtFloat(r) .. "</R><G>" .. fmtFloat(g) .. "</G><B>" .. fmtFloat(b) .. "</B>"
end

local function udimXml(v)
	local scale, offset = objField(v, "Scale"), objField(v, "Offset")
	if type(scale) ~= "number" or type(offset) ~= "number" then return nil end
	return "<S>" .. fmtFloat(scale) .. "</S><O>" .. fmtInt(offset) .. "</O>"
end

local function udim2Xml(v)
	local x = objField(v, "X")
	local y = objField(v, "Y")
	if type(x) ~= "table" and type(x) ~= "userdata" then return nil end
	local xs, xo = objField(x, "Scale"), objField(x, "Offset")
	local ys, yo = objField(y, "Scale"), objField(y, "Offset")
	if type(xs) ~= "number" or type(xo) ~= "number" or type(ys) ~= "number" or type(yo) ~= "number" then
		return nil
	end
	return "<XS>" .. fmtFloat(xs) .. "</XS><XO>" .. fmtInt(xo) .. "</XO><YS>"
		.. fmtFloat(ys) .. "</YS><YO>" .. fmtInt(yo) .. "</YO>"
end

local function rectXml(v)
	local minV, maxV = objField(v, "Min"), objField(v, "Max")
	local minXml, maxXml = vector2Xml(minV), vector2Xml(maxV)
	if minXml == nil or maxXml == nil then
		local minX, minY = objField(minV, "X"), objField(minV, "Y")
		local maxX, maxY = objField(maxV, "X"), objField(maxV, "Y")
		if type(minX) ~= "number" or type(minY) ~= "number" or type(maxX) ~= "number" or type(maxY) ~= "number" then
			return nil
		end
		minXml = "<X>" .. fmtFloat(minX) .. "</X><Y>" .. fmtFloat(minY) .. "</Y>"
		maxXml = "<X>" .. fmtFloat(maxX) .. "</X><Y>" .. fmtFloat(maxY) .. "</Y>"
	end
	return "<min>" .. minXml .. "</min><max>" .. maxXml .. "</max>"
end

local function numberRangeXml(v)
	local minV, maxV = objField(v, "Min"), objField(v, "Max")
	if type(minV) ~= "number" or type(maxV) ~= "number" then return nil end
	return fmtFloat(minV) .. " " .. fmtFloat(maxV) .. " "
end

local function numberSequenceXml(v)
	local keypoints = objField(v, "Keypoints")
	if type(keypoints) ~= "table" then return nil end
	local out = {}
	for i = 1, #keypoints do
		local kp = keypoints[i]
		local t, val, env = objField(kp, "Time"), objField(kp, "Value"), objField(kp, "Envelope")
		if type(t) ~= "number" or type(val) ~= "number" then return nil end
		if type(env) ~= "number" then env = 0 end
		out[#out + 1] = fmtFloat(t) .. " " .. fmtFloat(val) .. " " .. fmtFloat(env) .. " "
	end
	if #out == 0 then return nil end
	return table.concat(out)
end

local function colorSequenceXml(v)
	local keypoints = objField(v, "Keypoints")
	if type(keypoints) ~= "table" then return nil end
	local out = {}
	for i = 1, #keypoints do
		local kp = keypoints[i]
		local t = objField(kp, "Time")
		local color = objField(kp, "Value")
		local r, g, b = objField(color, "R"), objField(color, "G"), objField(color, "B")
		if type(t) ~= "number" or type(r) ~= "number" or type(g) ~= "number" or type(b) ~= "number" then
			return nil
		end
		out[#out + 1] = fmtFloat(t) .. " " .. fmtFloat(r) .. " " .. fmtFloat(g) .. " " ..
			fmtFloat(b) .. " 0 "
	end
	if #out == 0 then return nil end
	return table.concat(out)
end

local function contentXml(v)
	if type(v) ~= "string" then
		local ok, s = pcall(tostring, v)
		if not ok or type(s) ~= "string" then return nil end
		v = s
	end
	if #v == 0 then return nil end
	return "<url>" .. xmlText(v) .. "</url>"
end

local function valueToXml(typ, value)
	if value == nil then return nil end
	if typ == "bool" then
		if type(value) ~= "boolean" then return nil end
		return value and "true" or "false"
	elseif typ == "int" or typ == "int64" then
		if type(value) ~= "number" then return nil end
		return fmtInt(value)
	elseif typ == "float" or typ == "double" then
		return fmtFloat(value)
	elseif typ == "string" then
		if type(value) ~= "string" then return nil end
		return xmlText(value)
	elseif typ == "token" then
		local n = nil
		if type(value) == "number" then
			n = value
		else
			local ok, v = pcall(function() return value.Value end)
			if ok and type(v) == "number" then n = v end
		end
		if n == nil then return nil end
		return fmtInt(n)
	elseif typ == "Vector3" then
		return vector3Xml(value)
	elseif typ == "Vector2" then
		return vector2Xml(value)
	elseif typ == "CoordinateFrame" then
		return cframeXml(value)
	elseif typ == "Color3" then
		return color3Xml(value)
	elseif typ == "UDim" then
		return udimXml(value)
	elseif typ == "UDim2" then
		return udim2Xml(value)
	elseif typ == "Rect2D" then
		return rectXml(value)
	elseif typ == "NumberRange" then
		return numberRangeXml(value)
	elseif typ == "NumberSequence" then
		return numberSequenceXml(value)
	elseif typ == "ColorSequence" then
		return colorSequenceXml(value)
	elseif typ == "Content" then
		return contentXml(value)
	elseif typ == "ProtectedString" then
		if type(value) ~= "string" then return nil end
		return xmlText(value)
	end
	return nil
end

local function emitProperties(inst, cls, parts)
	local list = getPropList(cls)
	for i = 1, #list do
		local p = list[i]
		local value = prop(inst, p.n)
		if value ~= nil then
			if p.t == "Ref" then
				if isInstance(value) then
					local target = indexOf[value]
					if target ~= nil then
						parts[#parts + 1] = '<Ref name="' .. p.n .. '">RBX' .. tostring(target) .. "</Ref>"
					end
				end
			else
				local inner = valueToXml(p.t, value)
				if inner ~= nil then
					local tag = XML_TAGS[p.t]
					if tag ~= nil then
						parts[#parts + 1] = "<" .. tag .. ' name="' .. p.n .. '">' .. inner .. "</" .. tag .. ">"
					end
				end
			end
		end
	end
end

-- ===========================================================================
-- state shared between phases
-- ===========================================================================
local sourcesByInst = {}
local scriptRecords = {}
local scriptStats = { total = 0, decompiled = 0, bytecodeOnly = 0, source = 0, failed = 0, recoveredOnRetry = 0, noBytecode = 0 }
local decompileFailures = {}
local guiExported = 0
local guiFiles = {}
local assetStats = { found = 0, downloaded = 0, failed = 0, skipped = 0, limitHit = false }
local xmlItems = 0
local xmlFiles = {}
local jsonLines = 0
local jsonFiles = {}
local placeInfo = {}

-- ===========================================================================
-- phase: collect
-- ===========================================================================
local function detectStreaming()
	if game == nil then return nil end
	local ok, ws = pcall(function() return game:GetService("Workspace") end)
	if not ok or ws == nil then return nil end
	local ok2, v = pcall(function() return ws.StreamingEnabled end)
	if ok2 and type(v) == "boolean" then return v end
	return nil
end

local function collectAll()
	local roots = {}
	local rootSeen = {}

	local function addRoot(inst, label)
		if not isInstance(inst) then return end
		if rootSeen[inst] then return end
		rootSeen[inst] = true
		local idx = addEntry(inst, -1, false)
		if idx == nil then return end
		roots[#roots + 1] = idx
		local fast = collectDescendantsFast(inst, idx)
		if not fast then
			collectDescendantsDeep(inst, idx, 1)
		end
	end

	local childCount = 0
	local ok, kids = pcall(function() return game:GetChildren() end)
	if ok and type(kids) == "table" then
		childCount = #kids
		for i = 1, #kids do addRoot(kids[i], "game") end
	end
	if childCount == 0 then
		-- last resort: some executors restrict DataModel:GetChildren()
		local knownServices = {
			"Workspace", "Players", "Lighting", "ReplicatedFirst", "ReplicatedStorage",
			"StarterGui", "StarterPack", "StarterPlayer", "Teams", "SoundService",
			"Chat", "TextChatService", "LocalizationService", "MaterialService",
			"CollectionService", "SocialService", "VoiceChatService", "VideoService",
			"CoreGui", "TestService", "ContentProvider", "AssetService",
		}
		for i = 1, #knownServices do
			local okSvc, svc = pcall(function() return game:GetService(knownServices[i]) end)
			if okSvc and svc ~= nil then addRoot(svc, "service") end
		end
	end
	-- CoreGui is sometimes missing from GetChildren; explicit GetService is deduped by identity
	local okCore, coreGui = pcall(function() return game:GetService("CoreGui") end)
	if okCore and coreGui ~= nil then addRoot(coreGui, "service") end

	if CFG.DumpNilInstances and not RUN.safeMode then
		local function addExtras(list, label)
			if type(list) ~= "table" then return end
			for i = 1, #list do
				local inst = list[i]
				if isInstance(inst) and indexOf[inst] == nil then
					local parentObj = prop(inst, "Parent")
					local parentIdx = nil
					if isInstance(parentObj) then parentIdx = indexOf[parentObj] end
					local idx = addEntry(inst, parentIdx or -1, parentIdx == nil)
					if idx ~= nil and parentIdx == nil then
						collectDescendantsDeep(inst, idx, 1)
					end
				end
			end
			if label ~= nil then say("extra instances from " .. label) end
		end
		if nilInstancesFn ~= nil then
			local okN, list = pcall(nilInstancesFn)
			if okN then addExtras(list, "getnilinstances") else addWarning("collect", "getnilinstances failed") end
		end
		if loadedModulesFn ~= nil then
			local okM, list = pcall(loadedModulesFn)
			if okM then addExtras(list, "getloadedmodules") else addWarning("collect", "getloadedmodules failed") end
		end
		if scriptsFn ~= nil then
			local okS, list = pcall(scriptsFn)
			if okS then addExtras(list, "getscripts") else addWarning("collect", "getscripts failed") end
		end
	end

	serviceRoots = roots
	RUN.services = #roots
	RUN.instances = #entries
	RUN.skippedProtected = skippedProtected
	RUN.streaming = detectStreaming()
	if RUN.streaming == true then
		addWarning("collect", "Workspace.StreamingEnabled is true: only map chunks loaded around the player exist on the client")
		say("WARNING: streaming is ON - the dump contains only loaded map chunks")
	end
	return roots
end

local function finalizeCollection()
	children = {}
	for i = 1, #entries do
		local e = entries[i]
		local p = e.parent
		if p ~= nil and p > 0 then
			if children[p] == nil then children[p] = {} end
			children[p][#children[p] + 1] = i
		end
	end
	-- unique display names: Roblox allows duplicate sibling names, paths must not collide
	local nameSeen = {}
	for i = 1, #entries do
		local e = entries[i]
		local key = tostring(e.parent) .. "|" .. e.name
		local n = (nameSeen[key] or 0) + 1
		nameSeen[key] = n
		if n == 1 then
			e.displayName = e.name
		else
			e.displayName = e.name .. " #" .. tostring(n)
		end
	end
	-- compute paths
	local function buildPath(idx)
		local segs = {}
		local cur = idx
		local guard = 0
		while cur ~= nil and cur > 0 and guard < 64 do
			local e = entries[cur]
			if e == nil then break end
			segs[#segs + 1] = e.displayName or e.name
			if e.nilRoot then
				segs[#segs + 1] = "[nil]"
				break
			end
			if e.parent <= 0 then break end
			cur = e.parent
			guard = guard + 1
		end
		local rev = {}
		for i = #segs, 1, -1 do rev[#rev + 1] = segs[i] end
		return table.concat(rev, ".")
	end
	for i = 1, #entries do
		local e = entries[i]
		if e.path == nil then
			e.path = buildPath(i)
		end
	end
end

-- ===========================================================================
-- phase: scripts
-- ===========================================================================
local function pathSegmentsFor(idx, maxDepth)
	local segs = {}
	local cur = idx
	local guard = 0
	while cur ~= nil and cur > 0 and guard < (maxDepth or 8) do
		local e = entries[cur]
		if e == nil then break end
		segs[#segs + 1] = e.displayName or e.name
		if e.nilRoot then break end
		if e.parent <= 0 then break end
		cur = e.parent
		guard = guard + 1
	end
	local rev = {}
	for i = #segs, 1, -1 do
		rev[#rev + 1] = segs[i]
	end
	return rev
end

local function allocateInstanceFile(kind, idx, ext)
	local segs = pathSegmentsFor(idx, 8)
	local last = "instance"
	if #segs > 0 then last = segs[#segs] end
	local dirParts = { rootPath, kind }
	local budget = #rootPath + #kind
	for i = 1, #segs - 1 do
		local seg = sanitizeSegment(segs[i])
		if budget + #seg + 1 > (CFG.MaxPathLength - #last - #ext - 10) then break end
		dirParts[#dirParts + 1] = seg
		budget = budget + #seg + 1
	end
	local dir = table.concat(dirParts, "/")
	return allocatePath(dir, last, ext, idx)
end

local decompileCalls = 0

local function decompileThrottle()
	decompileCalls = decompileCalls + 1
	local delay = tonumber(CFG.DecompileDelay) or 0
	if delay > 0 and waitFunction ~= nil then
		pcall(waitFunction, delay)
	end
end

local function tryDecompileOnce(value)
	for i = 1, #decompileFns do
		decompileThrottle()
		local ok, res = pcall(decompileFns[i], value)
		if ok and type(res) == "string" and #res > 0 then return res end
	end
	return nil
end

local function tryDecompile(value, label)
	local attempts = tonumber(CFG.DecompileAttempts) or 1
	if attempts < 1 then attempts = 1 end
	for attempt = 1, attempts do
		local src = tryDecompileOnce(value)
		if src ~= nil then return src, attempt > 1 end
		if attempt < attempts and waitFunction ~= nil then
			pcall(waitFunction, 0.35 * attempt)
		end
	end
	return nil
end

local function readSource(inst)
	local ok, res = pcall(function() return inst.Source end)
	if ok and type(res) == "string" then return res end
	return nil
end

-- Roblox ships thousands of engine modules as Script/LocalScript/ModuleScript too. They are
-- not part of the game, take minutes to decompile and flood the Scripts/ folder.
local INTERNAL_SCRIPT_PREFIXES = {
	"CorePackages.", "CoreScripts.", "CoreGui.", "RobloxScripts.", "RobloxGui.",
	"CorePackages/", "CoreScripts/", "CoreGui/",
}

local function isInternalScriptPath(path)
	for i = 1, #INTERNAL_SCRIPT_PREFIXES do
		if path:sub(1, #INTERNAL_SCRIPT_PREFIXES[i]) == INTERNAL_SCRIPT_PREFIXES[i] then
			return true
		end
	end
	return false
end

local function recoverFailedOnline()
	if #decompileFailures == 0 then return end
	if not CFG.OnlineDecompile then return end
	if requestFn == nil then
		addWarning("scripts", "online decompile skipped: executor has no request() - "
			.. tostring(#decompileFailures) .. " script(s) stay as .bytecode")
		return
	end
	local pending = {}
	for i = 1, #decompileFailures do
		local f = decompileFailures[i]
		if f.bytecode ~= nil and #f.bytecode > 0 and not f.recovered then
			pending[#pending + 1] = f
		end
	end
	if #pending == 0 then return end
	local limit = tonumber(CFG.OnlineDecompileLimit) or 0
	local delay = tonumber(CFG.OnlineDecompileDelay) or 0.13
	RUN.phase = "scripts-online"
	progressStatus()
	say("online decompile: recovering " .. tostring(#pending) .. " script(s) via "
		.. tostring(CFG.OnlineDecompileUrl))
	local recovered = 0
	for i = 1, #pending do
		if limit > 0 and recovered >= limit then
			say("online decompile: limit " .. tostring(limit) .. " reached, rest stays .bytecode")
			break
		end
		local f = pending[i]
		local resp = httpPostJson(CFG.OnlineDecompileUrl, '{"script":"' .. base64Encode(f.bytecode) .. '"}')
		if resp ~= nil and #resp > 0 and not resp:match("^%s*{") then
			local file = allocateInstanceFile("Scripts", f.idx, ".lua")
			if writeWholeFile(file, resp, "script") then
				f.recovered = true
				f.sourceFile = file
				recovered = recovered + 1
				RUN.onlineRecovered = recovered
				local e = entries[f.idx]
				if e ~= nil and e.script ~= nil then
					e.script.status = "decompiled-online"
					e.script.origin = "online-decompile"
					e.script.sourceFile = file
					e.script.bytes = #resp
					e.script.errorText = nil
				end
			end
		end
		if delay > 0 and waitFunction ~= nil then pcall(waitFunction, delay) end
		if i % 25 == 0 then
			say("online decompile: " .. tostring(i) .. "/" .. tostring(#pending)
				.. " (recovered " .. tostring(recovered) .. ")")
			progressStatus()
		end
	end
	if recovered > 0 then
		scriptStats.decompiled = scriptStats.decompiled + recovered
		scriptStats.bytecodeOnly = scriptStats.bytecodeOnly - recovered
		if scriptStats.bytecodeOnly < 0 then scriptStats.bytecodeOnly = 0 end
	end
	say("online decompile: recovered " .. tostring(recovered) .. "/" .. tostring(#pending))
end

local function dumpScripts()
	if CFG.SafeMode then
		say("scripts: skipped (SafeMode)")
		return
	end
	if not CFG.DumpScripts then return end
	local mainList, internalList = {}, {}
	for i = 1, #entries do
		local cls = entries[i].class
		if cls == "Script" or cls == "LocalScript" or cls == "ModuleScript" or classIsA(cls, "LuaSourceContainer") then
			if isInternalScriptPath(entries[i].path) then
				internalList[#internalList + 1] = i
			else
				mainList[#mainList + 1] = i
			end
		end
	end
	local processInternal = (not CFG.SkipRobloxInternals) and true or false
	local totalToProcess = #mainList + (processInternal and #internalList or 0)
	local skippedInternal = processInternal and 0 or #internalList
	scriptStats.total = totalToProcess
	RUN.scriptsTotal = totalToProcess
	RUN.scriptsSkipped = skippedInternal
	say("scripts found: " .. tostring(#mainList + #internalList)
		.. ", to dump: " .. tostring(totalToProcess)
		.. (skippedInternal > 0 and (", skipped core: " .. tostring(skippedInternal)
			.. " (Roblox engine CorePackages/CoreGui - set SkipRobloxInternals=false to include them)") or ""))
	progressStatus()
	local ticks = 0
	local function processList(list)
		for k = 1, #list do
			local idx = list[k]
			local e = entries[idx]
			local inst = e.inst
			local source, bytecode, status, origin, lastError
			local recovered = false
			if #decompileFns > 0 then
				local dec, wasRetry = tryDecompile(inst, "script")
				if dec ~= nil then
					source = dec
					status = "decompiled"
					origin = "decompile"
					if wasRetry then
						recovered = true
						scriptStats.recoveredOnRetry = scriptStats.recoveredOnRetry + 1
					end
				else
					lastError = "decompile returned nothing"
				end
			else
				lastError = "no decompile function in this executor"
			end
			if bytecodeFn ~= nil then
				local okB, bc = pcall(bytecodeFn, inst)
				if okB and type(bc) == "string" and #bc > 0 then
					bytecode = bc
				elseif not okB then
					lastError = lastError or ("getscriptbytecode: " .. tostring(bc))
				end
				if bytecode ~= nil and source == nil and #decompileFns > 0 then
					local dec2, retry2 = tryDecompile(bytecode, "bytecode")
					if dec2 ~= nil then
						source = dec2
						status = "decompiled"
						origin = "decompile-bytecode"
						if retry2 and not recovered then
							recovered = true
							scriptStats.recoveredOnRetry = scriptStats.recoveredOnRetry + 1
						end
					end
				end
			end
			if source == nil then
				local src = readSource(inst)
				if src ~= nil and #src > 0 then
					source = src
					status = "source"
					origin = "Source"
				elseif src ~= nil and status == nil then
					-- empty source but readable: keep as readable empty file
					source = ""
					status = "source"
					origin = "Source"
				end
			end
			if source ~= nil then
				if status == "decompiled" then
					scriptStats.decompiled = scriptStats.decompiled + 1
				else
					status = "source"
					scriptStats.source = scriptStats.source + 1
				end
			elseif bytecode ~= nil then
				status = "bytecode-only"
				scriptStats.bytecodeOnly = scriptStats.bytecodeOnly + 1
			else
				status = "failed"
				scriptStats.failed = scriptStats.failed + 1
				scriptStats.noBytecode = scriptStats.noBytecode + 1
				if lastError == nil then lastError = "no source and no bytecode available" end
			end
			local record = { status = status, origin = origin, errorText = lastError, recoveredOnRetry = recovered }
			if source ~= nil then
				local file = allocateInstanceFile("Scripts", idx, ".lua")
				if writeWholeFile(file, source, "script") then
					record.sourceFile = file
					record.bytes = #source
				end
				sourcesByInst[inst] = source
				if CFG.SaveBytecode and bytecode ~= nil then
					local bfile = allocateInstanceFile("Scripts", idx, ".bytecode")
					if writeWholeFile(bfile, bytecode, "bytecode") then record.bytecodeFile = bfile end
				end
			elseif bytecode ~= nil then
				-- fallback bytecode is always kept, even when SaveBytecode is off
				local bfile = allocateInstanceFile("Scripts", idx, ".bytecode")
				if writeWholeFile(bfile, bytecode, "bytecode") then
					record.bytecodeFile = bfile
					record.bytes = #bytecode
				end
			end
			if status == "failed" then
				decompileFailures[#decompileFailures + 1] = {
					idx = idx,
					path = e.path,
					class = e.class,
					status = status,
					errorText = lastError,
				}
				addWarning("scripts", "could not read script: " .. e.path .. " (" .. tostring(lastError) .. ")")
			elseif status == "bytecode-only" then
				local keepBytecode = nil
				if CFG.OnlineDecompile and bytecode ~= nil
					and #bytecode <= (tonumber(CFG.OnlineMaxBytes) or 4194304) then
					keepBytecode = bytecode
				end
				decompileFailures[#decompileFailures + 1] = {
					idx = idx,
					path = e.path,
					class = e.class,
					status = status,
					bytecodeFile = record.bytecodeFile,
					bytecode = keepBytecode,
					errorText = lastError,
				}
				addWarning("scripts", "decompile failed, bytecode kept: " .. e.path)
			end
			e.script = record
			scriptRecords[#scriptRecords + 1] = {
				idx = idx,
				path = e.path,
				class = e.class,
				status = status,
				origin = origin,
				sourceFile = record.sourceFile,
				bytecodeFile = record.bytecodeFile,
				bytes = record.bytes,
				errorText = record.errorText,
				recoveredOnRetry = recovered,
			}
			ticks = ticks + 1
			RUN.scriptsDone = ticks
			if ticks % 50 == 0 then yieldNow() end
			if ticks % 100 == 0 then
				say("scripts: " .. tostring(ticks) .. "/" .. tostring(totalToProcess)
					.. " (decompiled " .. tostring(scriptStats.decompiled)
					.. ", retried " .. tostring(scriptStats.recoveredOnRetry)
					.. ", bytecode-only " .. tostring(scriptStats.bytecodeOnly)
					.. ", failed " .. tostring(scriptStats.failed) .. ")")
			end
			if ticks % 500 == 0 then progressStatus() end
		end
	end
	processList(mainList)
	if processInternal then processList(internalList) end
	if CFG.OnlineDecompile and #decompileFailures > 0 then
		pcall(recoverFailedOnline)
	end
	local lines = {}
	for i = 1, #scriptRecords do
		local rec = scriptRecords[i]
		local e = entries[rec.idx]
		if e ~= nil and e.script ~= nil then
			rec.status = e.script.status
			rec.origin = e.script.origin
			rec.sourceFile = e.script.sourceFile
			rec.bytecodeFile = e.script.bytecodeFile
			rec.bytes = e.script.bytes
			rec.errorText = e.script.errorText
			rec.recoveredOnRetry = e.script.recoveredOnRetry
			rec.recoveredOnline = e.script.origin == "online-decompile"
		end
		lines[#lines + 1] = encodeJson(rec)
	end
	local okw = writeWholeFile(rootPath .. "/Data/scripts_index.jsonl",
		table.concat(lines, "\n") .. (#lines > 0 and "\n" or ""), "data")
	if not okw then addError("scripts", "failed to write scripts index") end
	local remaining = {}
	for i = 1, #decompileFailures do
		local f = decompileFailures[i]
		if not f.recovered then remaining[#remaining + 1] = f end
	end
	if #remaining > 0 then
		local fl = {
			"# scripts without .lua after local + online decompile attempts",
			"# optional extra pass on PC: python tools/decompile_remaining.py <dump folder>",
			"# status\tbytecode\tpath",
		}
		for i = 1, #remaining do
			local f = remaining[i]
			fl[#fl + 1] = tostring(f.status) .. "\t" .. tostring(f.bytecodeFile or "-")
				.. "\t" .. f.path
		end
		writeWholeFile(rootPath .. "/Data/decompile_failures.txt", table.concat(fl, "\n") .. "\n", "data")
	end
	progressStatus()
end

-- ===========================================================================
-- phase: GUI models
-- ===========================================================================
local XML_EMIT = { count = 0, hook = nil }

local function emitItemXml(idx, w)
	local e = entries[idx]
	if e == nil then return end
	XML_EMIT.count = XML_EMIT.count + 1
	if XML_EMIT.hook ~= nil then XML_EMIT.hook() end
	local parts = { '<Item class="', e.class, '" referent="RBX', tostring(idx), '">', "<Properties>" }
	emitProperties(e.inst, e.class, parts)
	local source = sourcesByInst[e.inst]
	if source ~= nil and CFG.EmbedSourcesInPlace then
		parts[#parts + 1] = '<ProtectedString name="Source">' .. xmlText(source) .. "</ProtectedString>"
	end
	parts[#parts + 1] = "</Properties>"
	w.write(table.concat(parts))
	local kids = children[idx]
	if kids ~= nil then
		for i = 1, #kids do
			emitItemXml(kids[i], w)
		end
	end
	w.write("</Item>\n")
end

local XML_HEADER = '<roblox xmlns:xmime="http://www.w3.org/2005/05/xmlmime" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:noNamespaceSchemaLocation="http://www.roblox.com/roblox.xsd" version="4">\n'
	.. "\t<External>null</External>\n\t<External>nil</External>\n"
local XML_FOOTER = "</roblox>\n"

local function dumpGuiModels()
	if not CFG.DumpGuis then return end
	local count = 0
	for i = 1, #entries do
		local e = entries[i]
		if classIsA(e.class, "LayerCollector") then
			local parentIsGui = false
			if e.parent > 0 and entries[e.parent] ~= nil then
				parentIsGui = classIsA(entries[e.parent].class, "LayerCollector")
			end
			if not parentIsGui then
				local file = allocateInstanceFile("Guis", i, ".rbxmx")
				local w = newWriter(file, nil, 32 * 1024 * 1024, false)
				w.write(XML_HEADER)
				emitItemXml(i, w)
				w.write(XML_FOOTER)
				w.close()
				if not w.aborted then
					guiExported = guiExported + 1
					guiFiles[#guiFiles + 1] = file
					e.guiFile = file
				else
					addError("guis", "GUI model too large: " .. e.path)
				end
				count = count + 1
				if count % 25 == 0 then yieldNow() end
			end
		end
	end
	say("gui models exported: " .. tostring(guiExported))
	RUN.guis = guiExported
	progressStatus()
end

local function dumpTopModels()
	if not CFG.ExportTopModels then return end
	local exported = 0
	for i = 1, #entries do
		local e = entries[i]
		if e.parent > 0 and entries[e.parent] ~= nil then
			local parentCls = entries[e.parent].class
			if (parentCls == "Workspace" or parentCls == "ReplicatedStorage") and classIsA(e.class, "Model") then
				if CFG.MaxModelFiles > 0 and exported >= CFG.MaxModelFiles then
					addWarning("models", "model export limit reached (" .. tostring(CFG.MaxModelFiles)
						.. "); raise MaxModelFiles or set 0 for unlimited")
					break
				end
				local file = allocateInstanceFile("Models", i, ".rbxmx")
				local w = newWriter(file, nil, 64 * 1024 * 1024, false)
				w.write(XML_HEADER)
				emitItemXml(i, w)
				w.write(XML_FOOTER)
				w.close()
				if not w.aborted then
					exported = exported + 1
					e.modelFile = file
				end
				if exported % 10 == 0 then yieldNow() end
			end
		end
	end
	say("top-level models exported: " .. tostring(exported))
	RUN.models = exported
end

-- ===========================================================================
-- phase: JSON data
-- ===========================================================================
local function getAttributesSafe(inst)
	local ok, res = pcall(function() return inst:GetAttributes() end)
	if ok and type(res) == "table" then return res end
	return nil
end

local collectionService = nil
do
	if game ~= nil then
		local ok, svc = pcall(function() return game:GetService("CollectionService") end)
		if ok and svc ~= nil then collectionService = svc end
	end
end

local function getTagsSafe(inst)
	if collectionService == nil then return nil end
	local ok, res = pcall(function() return collectionService:GetTags(inst) end)
	if ok and type(res) == "table" then return res end
	return nil
end

local function describeValue(v, depth)
	depth = depth or 0
	if v == nil then return nil end
	local tv = type(v)
	if tv == "string" or tv == "number" or tv == "boolean" then return v end
	if depth > 6 then return "<deep>" end
	if isInstance(v) then
		local idx = indexOf[v]
		if idx ~= nil then return "Instance:" .. entries[idx].path end
		local nm = prop(v, "Name")
		return "Instance:" .. tostring(nm)
	end
	local tt = typeofOf(v)
	if tt == "EnumItem" then
		local ok, full = pcall(tostring, v)
		if ok and type(full) == "string" then return full end
		return "EnumItem"
	end
	if tv == "table" then
		local out = {}
		local count = 0
		for k, val in pairs(v) do
			count = count + 1
			if count > 200 then break end
			out[tostring(k)] = describeValue(val, depth + 1)
		end
		return out
	end
	local ok, s = pcall(tostring, v)
	if ok and type(s) == "string" then return s end
	return "<" .. tostring(tt) .. ">"
end

local function collectPropsForJson(e)
	local out = {}
	local list = getPropList(e.class)
	for i = 1, #list do
		local p = list[i]
		local value = prop(e.inst, p.n)
		if value ~= nil then
			out[p.n] = describeValue(value, 0)
		end
	end
	if CFG.ReadAllProperties and not CFG.SafeMode and propertiesFn ~= nil then
		local ok, all = pcall(propertiesFn, e.inst)
		if ok and type(all) == "table" then
			for name, value in pairs(all) do
				if type(name) == "string" and out[name] == nil then
					out[name] = describeValue(value, 0)
				end
			end
		end
	end
	return out
end

local function dumpJsonData()
	if not CFG.DumpJsonl then return end
	local writer = newWriter(rootPath .. "/Data/instances.jsonl", (CFG.XmlUseAppend == true and fileApi.append) or nil, 64 * 1024 * 1024, true)
	local ticks = 0
	for i = 1, #entries do
		local e = entries[i]
		local record = {
			path = e.path,
			class = e.class,
			name = e.name,
			depth = e.depth,
			nilParent = e.nilRoot or false,
		}
		if e.parent > 0 and entries[e.parent] ~= nil then
			record.parentPath = entries[e.parent].path
		end
		record.childCount = children[i] ~= nil and #children[i] or 0
		record.props = collectPropsForJson(e)
		local attrs = getAttributesSafe(e.inst)
		if attrs ~= nil then record.attrs = describeValue(attrs, 0) end
		local tags = getTagsSafe(e.inst)
		if tags ~= nil and #tags > 0 then record.tags = tags end
		if e.script ~= nil then
			record.script = {
				status = e.script.status,
				sourceFile = e.script.sourceFile,
				bytecodeFile = e.script.bytecodeFile,
				bytes = e.script.bytes,
			}
		end
		if e.guiFile ~= nil then record.guiFile = e.guiFile end
		writer.write(encodeJson(record) .. "\n")
		jsonLines = jsonLines + 1
		RUN.jsonLines = jsonLines
		ticks = ticks + 1
		if CFG.YieldEvery > 0 and ticks % CFG.YieldEvery == 0 then yieldNow() end
		if CFG.ProgressEvery > 0 and ticks % CFG.ProgressEvery == 0 then
			say("json: " .. tostring(ticks) .. "/" .. tostring(#entries))
		end
		if ticks % 5000 == 0 then progressStatus() end
	end
	writer.close()
	if writer.aborted then
		addError("json", "instances.jsonl exceeded memory limit")
	elseif writer.failed then
		addError("json", "instances.jsonl write failed")
	end
	if #writer.files == 0 and writer.size == 0 then
		writeWholeFile(rootPath .. "/Data/instances.jsonl", "", "data")
		jsonFiles[#jsonFiles + 1] = rootPath .. "/Data/instances.jsonl"
	end
	for i = 1, #writer.files do jsonFiles[#jsonFiles + 1] = writer.files[i] end
end

-- ===========================================================================
-- phase: assets
-- ===========================================================================
local function parseAssetId(url)
	if type(url) ~= "string" or #url == 0 then return nil end
	local id = url:match("rbxassetid://(%d+)")
	if id == nil then
		id = url:match("[%?&]id=(%d+)")
	end
	if id == nil then
		id = url:match("^rbxassetid:(%d+)")
	end
	if id == nil then return nil end
	local n = tonumber(id)
	if n == nil or n <= 0 then return nil end
	return n
end

local function detectAssetExtension(data)
	if #data >= 8 and data:sub(1, 8) == "\137PNG\13\10\26\10" then return "png" end
	if #data >= 3 and data:sub(1, 3) == "\255\216\255" then return "jpg" end
	if #data >= 4 and data:sub(1, 4) == "OggS" then return "ogg" end
	if #data >= 3 and data:sub(1, 3) == "ID3" then return "mp3" end
	if #data >= 2 and data:sub(1, 2) == "\255\251" then return "mp3" end
	if #data >= 4 and data:sub(1, 4) == "\0\1\0\0" then return "ttf" end
	if #data >= 15 and data:sub(1, 15) == "Kaydara FBX Bin" then return "fbx" end
	local head = data:sub(1, 32)
	if head:sub(1, 8) == "<roblox!" then return "rbxm" end
	if head:sub(1, 7) == "<roblox" then return "rbxmx" end
	if head:find("version 1.0") or head:find("version 2.0") or head:match("^version") then return "mesh" end
	if head:sub(1, 1) == "{" then return "json" end
	return "bin"
end

-- Every asset-bearing property that is actually used in games. Reading these per class is
-- cheap (no getproperties), and it catches animations/meshes/textures that the old Content-only
-- scan missed.
local ASSET_CLASS_PROPS = {
	MeshPart = { "MeshId", "TextureID" },
	SpecialMesh = { "MeshId", "TextureId" },
	FileMesh = { "MeshId", "TextureId" },
	CharacterMesh = { "MeshId", "TextureId" },
	Sound = { "SoundId" },
	Animation = { "AnimationId" },
	Decal = { "Texture" },
	Texture = { "Texture" },
	ImageLabel = { "Image" },
	ImageButton = { "Image" },
	Sky = { "SkyboxBk", "SkyboxDn", "SkyboxFt", "SkyboxLf", "SkyboxRt", "SkyboxUp" },
	ParticleEmitter = { "Texture" },
	Beam = { "Texture" },
	Trail = { "Texture" },
	SurfaceAppearance = { "ColorMap", "MetalnessMap", "NormalMap", "RoughnessMap", "EmissiveMap", "HeightMap" },
	Shirt = { "ShirtTemplate" },
	Pants = { "PantsTemplate" },
	VideoFrame = { "VideoFrame" },
}

local function assetKindFor(propName, cls)
	local n = string.lower(propName)
	if n:find("mesh", 1, true) then return "mesh" end
	if n:find("sound", 1, true) then return "audio" end
	if n:find("animation", 1, true) then return "animation" end
	if n == "image" or n:find("texture", 1, true) or n:find("map", 1, true)
		or n:find("skybox", 1, true) or n:find("shirt", 1, true) or n:find("pants", 1, true)
		or n == "graphic" or n == "videoframe" then
		return "image"
	end
	return "asset"
end

local function readWorkspaceFile(path)
	if fileApi.read == nil then return nil end
	local candidates = { path }
	local norm = (path:gsub("\\", "/"))
	if norm ~= path then candidates[#candidates + 1] = norm end
	if workspacePath ~= nil then
		local ws = workspacePath:gsub("\\", "/")
		if #ws > 0 and norm:sub(1, #ws) == ws then
			candidates[#candidates + 1] = norm:sub(#ws + 2)
		end
	end
	local rel = norm:match("workspace/(.+)$")
	if rel ~= nil then candidates[#candidates + 1] = rel end
	for i = 1, #candidates do
		local ok, data = pcall(fileApi.read, candidates[i])
		if ok and type(data) == "string" and #data > 0 then return data end
	end
	return nil
end

local function fetchAsset(id)
	local urls = {
		"rbxassetid://" .. tostring(id),
		"https://assetdelivery.roblox.com/v1/asset/?id=" .. tostring(id),
	}
	if customAssetFn ~= nil and not CFG.SafeMode and not CFG.AssetViaRequestOnly then
		for i = 1, #urls do
			local ok, p = pcall(customAssetFn, urls[i])
			if ok and type(p) == "string" and #p > 0 then
				local data = readWorkspaceFile(p)
				if data ~= nil then return data, "getcustomasset" end
			end
		end
	end
	if game ~= nil and not CFG.AssetViaRequestOnly then
		for i = 2, #urls do
			local ok, data = pcall(function() return game:HttpGet(urls[i]) end)
			if ok and type(data) == "string" and #data > 0 then return data, "HttpGet" end
		end
	end
	if requestFn ~= nil then
		for i = 2, #urls do
			local ok, res = pcall(requestFn, { Url = urls[i], Method = "GET" })
			if ok then
				if type(res) == "table" then
					local body = res.Body
					if body == nil then body = res.body end
					if type(body) == "string" and #body > 0 then return body, "request" end
				elseif type(res) == "string" and #res > 0 then
					return res, "request"
				end
			end
		end
	end
	return nil
end

local function dumpAssets()
	if not CFG.DownloadAssets then return end
	local uses = {}
	local order = {}
	local kinds = {}
	local animUses = {}
	local scanTicks = 0

	local function contentId(inst, name)
		local value = prop(inst, name)
		if type(value) ~= "string" and value ~= nil then
			local okStr, s = pcall(tostring, value)
			if okStr and type(s) == "string" then value = s end
		end
		return parseAssetId(value)
	end

	local function addUse(id, usePath, propName, cls)
		if id == nil then return end
		if uses[id] == nil then
			uses[id] = {}
			order[#order + 1] = id
			kinds[id] = assetKindFor(propName, cls)
		end
		local bucket = uses[id]
		if #bucket < 12 then bucket[#bucket + 1] = usePath .. "." .. propName end
		if string.lower(propName):find("animation", 1, true) then
			if animUses[id] == nil then animUses[id] = {} end
			local ab = animUses[id]
			if #ab < 12 then ab[#ab + 1] = usePath end
		end
	end

	for i = 1, #entries do
		local e = entries[i]
		local list = getPropList(e.class)
		for j = 1, #list do
			local p = list[j]
			if p.t == "Content" then
				addUse(contentId(e.inst, p.n), e.path, p.n, e.class)
			end
		end
		local extra = ASSET_CLASS_PROPS[e.class]
		if extra ~= nil then
			for j = 1, #extra do
				addUse(contentId(e.inst, extra[j]), e.path, extra[j], e.class)
			end
		end
		scanTicks = scanTicks + 1
		if CFG.YieldEvery > 0 and scanTicks % CFG.YieldEvery == 0 then yieldNow() end
		if scanTicks % 5000 == 0 then
			RUN.assetsFound = #order
			progressStatus()
			say("scanning assets: " .. tostring(scanTicks) .. "/" .. tostring(#entries)
				.. ", ids " .. tostring(#order))
		end
	end
	assetStats.found = #order
	RUN.assetsFound = #order
	say("asset ids found: " .. tostring(#order) .. " (all types: images, sounds, meshes, animations, textures)")
	progressStatus()
	local records = {}
	local failed = {}
	local downloaded = 0
	for i = 1, #order do
		local id = order[i]
		if CFG.AssetLimit > 0 and downloaded >= CFG.AssetLimit then
			assetStats.limitHit = true
			assetStats.skipped = assetStats.skipped + (#order - i + 1)
			break
		end
		local data, via = fetchAsset(id)
		if data == nil then
			assetStats.failed = assetStats.failed + 1
			failed[#failed + 1] = { id = id, error = "download failed" }
		else
			local ext = detectAssetExtension(data)
			local file = "Assets/" .. tostring(id) .. "." .. ext
			if writeWholeFile(rootPath .. "/" .. file, data, "asset") then
				downloaded = downloaded + 1
				records[#records + 1] = {
					id = id,
					file = file,
					bytes = #data,
					kind = kinds[id] or "asset",
					source = via,
					usedBy = uses[id],
				}
			else
				assetStats.failed = assetStats.failed + 1
				failed[#failed + 1] = { id = id, error = "write failed" }
			end
		end
		if i % 10 == 0 then yieldNow() end
		if i % 200 == 0 then pcall(function() if collectgarbage ~= nil then collectgarbage("collect") end end) end
		if CFG.AssetDelay and CFG.AssetDelay > 0 then task.wait(CFG.AssetDelay) end
		RUN.assetsDone = i
		if i % 50 == 0 then
			say("assets: " .. tostring(i) .. "/" .. tostring(#order) .. " (downloaded " .. tostring(downloaded) .. ")")
			progressStatus()
		end
		if CFG.ProgressEvery > 0 and i % CFG.ProgressEvery == 0 then
			say("assets: " .. tostring(i) .. "/" .. tostring(#order))
		end
	end
	assetStats.downloaded = downloaded
	RUN.assetsDone = downloaded

	local animLines = 0
	if CFG.DumpAnimations then
		local byId = {}
		for r = 1, #records do byId[records[r].id] = records[r].file end
		local lines = {}
		for id, paths in pairs(animUses) do
			local file = byId[id]
			for p = 1, #paths do
				lines[#lines + 1] = encodeJson({
					path = paths[p],
					animationId = id,
					file = file,
				})
			end
		end
		table.sort(lines)
		animLines = #lines
		writeWholeFile(rootPath .. "/Data/animations.jsonl",
			table.concat(lines, "\n") .. (animLines > 0 and "\n" or ""), "data")
		RUN.animations = animLines
	end

	local index = {
		found = #order,
		downloaded = downloaded,
		failed = #failed,
		limit = CFG.AssetLimit,
		limitHit = assetStats.limitHit,
		animations = animLines,
		assets = jsonArray(records),
		errors = jsonArray(failed),
	}
	writeWholeFile(rootPath .. "/Assets/index.json", encodeJson(index) .. "\n", "data")
end

-- ===========================================================================
-- phase: place XML
-- ===========================================================================
local function emitServiceFile(rootIdx)
	local e = entries[rootIdx]
	local file = rootPath .. "/Xml/" .. sanitizeSegment(e.class) .. ".rbxmx"
	local w = newWriter(file, nil, 128 * 1024 * 1024, false)
	w.write(XML_HEADER)
	emitItemXml(rootIdx, w)
	w.write(XML_FOOTER)
	w.close()
	if not w.aborted then
		xmlFiles[#xmlFiles + 1] = file
		return true
	end
	addError("xml", "service model too large: " .. e.path)
	return false
end

-- Xeno (and some other executors) ship an appendfile that cannot create a missing file:
-- it raises "Expected File But Got Directory". Probe it before building the 100+ MB XML so we
-- never lose the whole place file to that quirk.
local APPEND_MODE = nil

local function probeAppendMode()
	if APPEND_MODE ~= nil then return APPEND_MODE end
	if fileApi.append == nil or fileApi.write == nil or fileApi.read == nil then
		APPEND_MODE = "memory"
		return APPEND_MODE
	end
	local function try(path)
		local okW = pcall(fileApi.write, path, "A")
		if not okW then return false, "writefile could not create the probe file" end
		local big = string.rep("x", FLUSH_SIZE + 1024)
		local okA, err = pcall(fileApi.append, path, big)
		if not okA then
			pcall(function() if fileApi.delete ~= nil then fileApi.delete(path) end end)
			return false, tostring(err)
		end
		local okR, data = pcall(fileApi.read, path)
		pcall(function() if fileApi.delete ~= nil then fileApi.delete(path) end end)
		if okR and type(data) == "string" and #data == 1 + #big and data:sub(1, 1) == "A" then
			return true
		end
		return false, "appendfile did not persist the probe data"
	end
	local okSub, errSub = try(rootPath .. "/.appendprobe")
	if okSub then
		APPEND_MODE = "subdir"
		return APPEND_MODE
	end
	local okRoot = try(rootName .. "_appendprobe.tmp")
	if okRoot then
		addWarning("xml", "appendfile works only at workspace root (" .. tostring(errSub)
			.. "); Game.rbxlx is written to the workspace root, then copied into the dump folder")
		APPEND_MODE = "root"
		return APPEND_MODE
	end
	addWarning("xml", "appendfile is unusable (" .. tostring(errSub)
		.. "); Game.rbxlx is built in memory (limit " .. tostring(CFG.XmlMemoryLimitMB) .. " MB)")
	APPEND_MODE = "memory"
	return APPEND_MODE
end

local function dumpPlaceXml()
	if not CFG.DumpXml then return end
	xmlItems = 0
	XML_EMIT.count = 0
	local useAppend = (CFG.XmlUseAppend == true and fileApi.append) or nil
	local mode = "memory"
	if useAppend ~= nil then mode = probeAppendMode() end
	local path, finalPath
	if mode == "root" then
		path = rootName .. "_Game.rbxlx"
		finalPath = rootPath .. "/Game.rbxlx"
	else
		path = rootPath .. "/Game.rbxlx"
		finalPath = path
	end
	if useAppend == nil then
		say("note: appendfile unusable -> building Game.rbxlx in memory (limit "
			.. tostring(CFG.XmlMemoryLimitMB) .. " MB)")
	end
	local memLimit = math.max(32, CFG.XmlMemoryLimitMB) * 1024 * 1024
	local memNow = clientMemoryMB()
	if memNow ~= nil and memNow > (CFG.AutoFallbackMemoryMB or 2400) then
		memLimit = 32 * 1024 * 1024
		addWarning("xml", string.format("client memory %.0f MB is high - using low-memory XML mode", memNow))
		say(string.format("WARNING: client memory %.0f MB - low-memory XML mode (per-service models if needed)", memNow))
	end
	local writer = newWriter(path, useAppend, memLimit, false)
	say("xml: " .. tostring(#entries) .. " instances, rough size estimate "
		.. string.format("%.1f", #entries * 320 / 1048576) .. " MB")
	local lastSay = 0
	XML_EMIT.hook = function()
		local c = XML_EMIT.count
		if c % 400 == 0 then yieldNow() end
		if c - lastSay >= 5000 then
			lastSay = c
			RUN.xmlItems = c
			RUN.xmlMode = (useAppend ~= nil) and "stream" or "memory"
			progressStatus()
			say("xml: " .. tostring(c) .. " instances, "
				.. string.format("%.1f", writer.size / 1048576) .. " MB")
		end
	end
	writer.write(XML_HEADER)
	for i = 1, #serviceRoots do
		emitItemXml(serviceRoots[i], writer)
		if i % 20 == 0 then yieldNow() end
	end
	writer.write(XML_FOOTER)
	writer.close()
	XML_EMIT.hook = nil
	if writer.aborted then
		addWarning("xml", "place XML exceeded memory limit without appendfile; writing per-service models")
		say("Game.rbxlx does not fit the memory limit -> writing per-service Xml/*.rbxmx models")
		local okCount = 0
		for i = 1, #serviceRoots do
			XML_EMIT.count = 0
			if emitServiceFile(serviceRoots[i]) then
				okCount = okCount + 1
				xmlItems = xmlItems + XML_EMIT.count
			end
		end
		RUN.xmlItems = xmlItems
		RUN.xmlMode = "per-service"
		if RUN.placeMode ~= "saveinstance" and RUN.placeMode ~= "saveinstance+lua-xml" then
			RUN.placeMode = "per-service"
		end
		rawWrite(rootPath .. "/Xml/_NOTE.txt",
			"Game.rbxlx was NOT written: appendfile is missing and the place XML exceeded the "
				.. tostring(CFG.XmlMemoryLimitMB) .. " MB memory limit.\n"
				.. "Per-service models are in this Xml/ folder - open each .rbxmx in Studio.\n"
				.. "Better: run this dumper in an executor that exposes saveinstance() so the native "
				.. "whole-place file is produced instead.\n")
		say("per-service models written: " .. tostring(okCount))
	elseif writer.failed then
		addError("xml", "place XML write failed (appendfile)")
		RUN.xmlMode = "failed"
	else
		local target = path
		if mode == "root" then
			local okR, data = pcall(fileApi.read, path)
			if okR and type(data) == "string" and writeWholeFile(finalPath, data, "place") then
				target = finalPath
				pcall(function() if fileApi.delete ~= nil then fileApi.delete(path) end end)
			end
		end
		xmlFiles[#xmlFiles + 1] = target
		xmlItems = XML_EMIT.count
		RUN.xmlItems = xmlItems
		RUN.xmlBytes = writer.size
		RUN.xmlMode = (useAppend ~= nil) and "stream" or "memory"
		if RUN.placeMode == "saveinstance" then
			RUN.placeMode = "saveinstance+lua-xml"
		else
			RUN.placeMode = "lua-xml"
			RUN.placeFile = target
		end
		say("Game.rbxlx written: " .. string.format("%.1f", writer.size / 1048576) .. " MB, "
			.. tostring(xmlItems) .. " instances" .. (target ~= path and " (copied into the dump folder)" or ""))
	end
	progressStatus()
end

-- ===========================================================================
-- phase: report
-- ===========================================================================
local function readPlaceInfo()
	local function num(key, default)
		local v = prop(game, key)
		if type(v) == "number" then return v end
		return default
	end
	local function str(key, default)
		local v = prop(game, key)
		if type(v) == "string" then return v end
		return default
	end
	local creatorType = prop(game, "CreatorType")
	if creatorType ~= nil then
		local ok, s = pcall(tostring, creatorType)
		if ok then creatorType = s else creatorType = nil end
	end
	placeInfo = {
		placeId = num("PlaceId", 0),
		gameId = num("GameId", 0),
		placeVersion = num("PlaceVersion", 0),
		creatorId = num("CreatorId", 0),
		creatorType = creatorType,
		jobId = str("JobId", nil),
		name = str("Name", nil),
		capturedAt = makeStamp(),
	}
	writeWholeFile(rootPath .. "/Data/place_info.json", encodeJson(placeInfo) .. "\n", "data")
end

local function writeServicesTxt()
	local lines = {}
	lines[#lines + 1] = "# service roots"
	for i = 1, #serviceRoots do
		local idx = serviceRoots[i]
		local e = entries[idx]
		local descendants = 0
		local function countChildren(cid)
			local kids = children[cid]
			if kids == nil then return end
			for j = 1, #kids do
				descendants = descendants + 1
				countChildren(kids[j])
			end
		end
		countChildren(idx)
		lines[#lines + 1] = e.path .. " (" .. e.class .. ") descendants=" .. tostring(descendants)
	end
	writeWholeFile(rootPath .. "/Data/services.txt", table.concat(lines, "\n") .. "\n", "data")
end


local function fmtMB(bytes)
	if bytes == nil or bytes <= 0 then return "n/a" end
	return string.format("%.1f MB", bytes / 1048576)
end

local function xmlSummaryText()
	if not CFG.DumpXml then return "disabled (CFG.DumpXml=false)" end
	if RUN.xmlMode == "stream" or RUN.xmlMode == "memory" then return "Game.rbxlx " .. fmtMB(RUN.xmlBytes) end
	if RUN.xmlMode == "per-service" then return "Xml/*.rbxmx (Game.rbxlx did not fit memory limit)" end
	return "missing (" .. tostring(RUN.xmlMode) .. ")"
end

local function placeSummaryText()
	local parts = {}
	if RUN.nativePlaceFile ~= nil then
		parts[#parts + 1] = "native working place: " .. tostring(RUN.nativePlaceFile)
	end
	if RUN.xmlMode == "stream" or RUN.xmlMode == "memory" then
		parts[#parts + 1] = "built-in XML: Game.rbxlx " .. fmtMB(RUN.xmlBytes)
	elseif RUN.xmlMode == "per-service" then
		parts[#parts + 1] = "per-service Xml/*.rbxmx models"
	end
	if #parts == 0 then
		return "MISSING - check CFG.DumpXml / CFG.UseSaveInstance (SafeMode="
			.. tostring(RUN.safeMode) .. ")"
	end
	if RUN.safeMode then
		parts[#parts + 1] = "(SafeMode: native calls disabled)"
	end
	return table.concat(parts, " + ")
end

local function writeReports()
	local done = (RUN.state == "done")
	writeEnvFile()
	local summary = {
		tool = "NyxDump",
		version = VERSION,
		ok = true,
		finished = done,
		root = rootName,
		workspace = workspacePath,
		executor = EXECUTOR_NAME,
		streaming = RUN.streaming,
		safeMode = RUN.safeMode,
		place = placeInfo,
		placeFile = RUN.placeFile,
		nativePlaceFile = RUN.nativePlaceFile,
		placeMode = RUN.placeMode,
		instances = #entries,
		skippedProtected = skippedProtected,
		truncated = truncated,
		services = #serviceRoots,
		scripts = {
			total = scriptStats.total,
			skippedInternal = RUN.scriptsSkipped,
			decompiled = scriptStats.decompiled,
			recoveredOnRetry = scriptStats.recoveredOnRetry,
			recoveredOnline = RUN.onlineRecovered,
			source = scriptStats.source,
			bytecodeOnly = scriptStats.bytecodeOnly,
			failed = scriptStats.failed,
			noBytecode = scriptStats.noBytecode,
		},
		guis = guiExported,
		models = RUN.models,
		animations = RUN.animations,
		xml = {
			enabled = CFG.DumpXml,
			mode = RUN.xmlMode,
			items = xmlItems,
			bytes = RUN.xmlBytes,
			files = jsonArray(xmlFiles),
		},
		jsonl = {
			enabled = CFG.DumpJsonl,
			lines = jsonLines,
			files = jsonArray(jsonFiles),
		},
		assets = {
			found = assetStats.found,
			downloaded = assetStats.downloaded,
			failed = assetStats.failed,
			skipped = assetStats.skipped,
			limit = CFG.AssetLimit,
			limitHit = assetStats.limitHit,
		},
		errors = { count = errorCount, list = jsonArray(errors) },
		warnings = { count = warningCount, list = jsonArray(warnings) },
		elapsedMs = elapsedMs(),
	}
	local manifest = {
		files = {},
		directories = {},
		fileSizes = {},
	}
	local function stripRoot(p)
		if p == nil then return nil end
		if p == rootPath then return nil end
		if p:sub(1, #rootPath + 1) == rootPath .. "/" then return p:sub(#rootPath + 2) end
		return p
	end
	local seenFiles, seenDirs = {}, {}
	for i = 1, #filesWritten do
		local f = filesWritten[i]
		local rel = stripRoot(f.path)
		if rel ~= nil and #rel > 0 and not seenFiles[rel] then
			seenFiles[rel] = true
			manifest.files[#manifest.files + 1] = rel
			manifest.fileSizes[rel] = f.bytes
		end
	end
	for i = 1, #dirsCreated do
		local rel = stripRoot(dirsCreated[i])
		if rel ~= nil and #rel > 0 and not seenDirs[rel] then
			seenDirs[rel] = true
			manifest.directories[#manifest.directories + 1] = rel
		end
	end
	manifest.files = jsonArray(manifest.files)
	manifest.directories = jsonArray(manifest.directories)
	writeWholeFile(rootPath .. "/manifest.json", encodeJson(manifest) .. "\n", "manifest")
	writeWholeFile(rootPath .. "/summary.json", encodeJson(summary) .. "\n", "summary")

	local lines = {}
	local function line(s) lines[#lines + 1] = s end
	line("NyxDump " .. VERSION .. " - place dump report")
	line("result: " .. (done and "DONE (all enabled phases finished)" or "PARTIAL - script did not reach the end"))
	line("generated: " .. tostring(placeInfo.capturedAt or makeStamp()))
	line("placeId: " .. tostring(placeInfo.placeId) .. "  gameId: " .. tostring(placeInfo.gameId)
		.. "  placeVersion: " .. tostring(placeInfo.placeVersion))
	line("output: " .. rootName)
	if workspacePath ~= nil then line("workspace: " .. tostring(workspacePath)) end
	line("executor: " .. tostring(EXECUTOR_NAME or "unknown"))
	line("mode: " .. (RUN.safeMode and "SAFE (built-in XML, no executor-native calls)"
		or "FULL (native saveinstance + native decompile)"))
	line("anti-idle: " .. tostring(CFG.AntiIdle) .. " (no server kick during the dump)")
	line("rendering frozen: " .. tostring(CFG.FreezeRendering))
	if RUN.memoryStopped ~= nil then
		line(string.format("memory guard: collection stopped at %.0f MB (partial dump)", RUN.memoryStopped))
	end
	if RUN.safeMode then
		line("  SafeMode note: if your executor supports the current Roblox version, rerun with")
		line("  _G.NYX_DUMP_CONFIG = { SafeMode = false } to enable the native place file and scripts.")
	end
	line("place file: " .. placeSummaryText())
	if RUN.nativePlaceFile ~= nil then
		line("native place file (open this one): " .. tostring(RUN.nativePlaceFile))
	end
	if RUN.saveinstancePath ~= nil then
		line("saveinstance output also kept at: " .. tostring(RUN.saveinstancePath))
	end
	line("")
	line("environment")
	line("  writefile: " .. tostring(fileApi.write ~= nil))
	line("  appendfile: " .. tostring(fileApi.append ~= nil))
	line("  makefolder: " .. tostring(fileApi.makeDir ~= nil))
	line("  decompile: " .. tostring(decompileFn ~= nil))
	line("  getscriptbytecode: " .. tostring(bytecodeFn ~= nil))
	line("  getproperties: " .. tostring(propertiesFn ~= nil))
	line("  getnilinstances: " .. tostring(nilInstancesFn ~= nil))
	line("  getloadedmodules: " .. tostring(loadedModulesFn ~= nil))
	line("  getscripts: " .. tostring(scriptsFn ~= nil))
	line("  getcustomasset: " .. tostring(customAssetFn ~= nil))
	line("  request: " .. tostring(requestFn ~= nil))
	line("  saveinstance: " .. tostring(saveInstanceFn ~= nil))
	line("")
	line("instances: " .. tostring(#entries))
	line("  services: " .. tostring(#serviceRoots))
	line("  skipped protected/unreadable: " .. tostring(skippedProtected))
	line("  truncated by MaxInstances: " .. tostring(truncated))
	line("  workspace streaming: " .. tostring(RUN.streaming))
	if RUN.streaming == true then
		line("    -> streaming was ON: only map chunks loaded around the player were dumped")
	end
	line("")
	line("scripts: " .. tostring(scriptStats.total)
		.. " (skipped core packages: " .. tostring(RUN.scriptsSkipped) .. ")")
	if RUN.safeMode then
		line("  skipped: SafeMode (executor-native decompile disabled)")
	end
	line("  decompiled: " .. tostring(scriptStats.decompiled)
		.. " (recovered by retry: " .. tostring(scriptStats.recoveredOnRetry)
		.. ", recovered online: " .. tostring(RUN.onlineRecovered) .. ")")
	line("  readable Source: " .. tostring(scriptStats.source))
	line("  bytecode only: " .. tostring(scriptStats.bytecodeOnly))
	line("  failed (no source, no bytecode): " .. tostring(scriptStats.failed)
		.. " (of them no bytecode: " .. tostring(scriptStats.noBytecode) .. ")")
	if scriptStats.bytecodeOnly > 0 then
		if requestFn == nil then
			line("  -> executor has no request(); finish the remaining .bytecode on PC with:")
			line("     python tools/decompile_remaining.py \"" .. rootPath .. "\"")
		else
			line("  -> online recovery failed for the files above; retry with:")
			line("     python tools/decompile_remaining.py \"" .. rootPath .. "\"")
		end
	end
	line("")
	line("xml: mode=" .. tostring(RUN.xmlMode) .. " items=" .. tostring(xmlItems)
		.. " bytes=" .. tostring(RUN.xmlBytes) .. " files=" .. tostring(#xmlFiles)
		.. " enabled=" .. tostring(CFG.DumpXml))
	line("jsonl: lines=" .. tostring(jsonLines) .. " files=" .. tostring(#jsonFiles) .. " enabled=" .. tostring(CFG.DumpJsonl))
	line("guis exported: " .. tostring(guiExported))
	line("models exported: " .. tostring(RUN.models))
	line("animations found: " .. tostring(RUN.animations)
		.. " (Data/animations.jsonl; animation assets are in Assets/)")
	line("assets: found=" .. tostring(assetStats.found) .. " downloaded=" .. tostring(assetStats.downloaded)
		.. " failed=" .. tostring(assetStats.failed) .. " skippedLimit=" .. tostring(assetStats.skipped)
		.. " limit=" .. tostring(CFG.AssetLimit))
	line("elapsedMs: " .. tostring(elapsedMs()))
	line("")
	line("errors: " .. tostring(errorCount))
	for i = 1, #errors do line("  - " .. errors[i]) end
	line("")
	line("warnings: " .. tostring(warningCount))
	for i = 1, #warnings do line("  - " .. warnings[i]) end
	line("")
	line("completion markers: console prints NYX_DUMP_DONE, dump folder gets DONE.txt,")
	line("STATUS.txt ends with state: done. No DONE.txt = the run was interrupted or killed.")
	line("")
	line("END OF REPORT")
	local reportText = table.concat(lines, "\n") .. "\n"
	writeWholeFile(rootPath .. "/REPORT.txt", reportText, "report")
	writeWholeFile(rootPath .. "/README.txt", table.concat({
		"NyxDump " .. VERSION .. " - dump of place " .. tostring(placeId),
		"",
		"Game.rbxlx        open in Roblox Studio (File -> Open).",
		"Scripts/          decompiled .lua scripts (+ .bytecode when decompiling failed).",
		"Guis/             top-level ScreenGui/SurfaceGui/BillboardGui as .rbxmx models.",
		"Data/             instances.jsonl, scripts_index.jsonl, place_info.json, services.txt.",
		"Assets/           downloaded content ids (images/sounds/meshes/textures).",
		"STATUS.txt        live state; state: done means finished.",
		"ENV.txt           executor API availability, config and streaming state.",
		"DONE.txt          completion marker (only exists after a full run).",
		"REPORT.txt        full run report.",
	}, "\n") .. "\n", "readme")

	if type(G) == "table" then
		pcall(function() G.NYX_DUMP_SUMMARY = summary end)
	end
	return summary
end

-- ===========================================================================
-- main
-- ===========================================================================
local function runPhase(name, fn)
	RUN.phase = name
	setState("running", name)
	say("phase: " .. name)
	local t0 = elapsedMs()
	local ok, res = pcall(fn)
	local dt = elapsedMs() - t0
	if not ok then
		addError(name, tostring(res))
		say("phase failed: " .. name .. " after " .. string.format("%.1f", dt / 1000)
			.. "s (details in REPORT.txt)")
	else
		say("phase done: " .. name .. " (" .. string.format("%.1f", dt / 1000) .. "s)")
	end
	progressStatus()
	return ok, res
end

local function printDoneBanner()
	local lines = {
		"",
		"============================================================",
		" NyxDump " .. VERSION .. " - ALL DONE",
		" folder: " .. rootPath,
		" place file: " .. placeSummaryText(),
		" instances: " .. tostring(#entries) .. "   services: " .. tostring(#serviceRoots),
		" scripts: " .. (RUN.onlyPlace and "skipped (single-file mode)" or (RUN.safeMode and "skipped (SafeMode)"
			or (tostring(scriptStats.decompiled) .. " decompiled ("
				.. tostring(RUN.onlineRecovered) .. " online), "
				.. tostring(scriptStats.bytecodeOnly) .. " bytecode, "
				.. tostring(scriptStats.failed) .. " failed (core skipped: "
				.. tostring(RUN.scriptsSkipped) .. ")"))),
		" guis: " .. tostring(guiExported) .. "   models: " .. tostring(RUN.models)
			.. "   animations: " .. tostring(RUN.animations),
		" assets: "
			.. tostring(assetStats.downloaded) .. "/" .. tostring(assetStats.found),
		" elapsed: " .. string.format("%.1f s", elapsedMs() / 1000),
		" markers: DONE.txt / REPORT.txt / STATUS.txt (state: done)",
		"============================================================",
	}
	for i = 1, #lines do print(lines[i]) end
end

local function main()
	if game == nil then
		print("NYX_DUMP_FATAL: game/DataModel is not accessible (not running in Roblox?)")
		return
	end
	if fileApi.write == nil then
		print("NYX_DUMP_FATAL: executor file API not found (writefile). Use a different executor.")
		return
	end

	RUN.safeMode = (CFG.SafeMode ~= false)
	if not rawWrite(STATUS_PATH, buildStatusText()) then
		print("NYX_DUMP_FATAL: cannot write into executor workspace (" .. rootPath .. "/STATUS.txt)")
		return
	end
	setState("running", "prep")
	writeEnvFile()

	say("NyxDump " .. VERSION .. " starting -> " .. rootPath)
	if workspacePath ~= nil then say("absolute: " .. workspacePath .. "/" .. rootPath) end
	if EXECUTOR_NAME ~= nil then say("executor: " .. tostring(EXECUTOR_NAME)) end
	local memNow = clientMemoryMB()
	if memNow ~= nil then
		say(string.format("client memory: %.0f MB", memNow))
		if memNow > 2200 then
			say("WARNING: client already uses " .. string.format("%.0f", memNow)
				.. " MB - rejoin the game before dumping, otherwise Roblox may close on OOM")
		end
	end
	if RUN.safeMode then
		say("mode: SAFE (built-in XML + pure Roblox API, no executor-native calls)")
		say("  scripts/native saveinstance are OFF: a stale executor build cannot crash the client")
		say("  after your executor supports this Roblox version run with _G.NYX_DUMP_CONFIG={SafeMode=false}")
	else
		say("mode: FULL (saveinstance + native decompile enabled)")
	end
	if fileApi.append ~= nil and CFG.XmlUseAppend == true then
		say("appendfile: streamed XML (only if CFG.XmlUseAppend=true)")
	else
		say("xml writer: single writefile (safe on Xeno - appendfile drops chunks)")
	end
	if CFG.UseSaveInstance then
		say("saveinstance: available" .. (CFG.UseSaveInstance and "" or " (disabled)"))
	end
	if requestFn ~= nil then
		say("request: available" .. (RUN.safeMode and " (online script recovery disabled by SafeMode)" or ""))
	end
	setupAntiIdle()
	freeMemoryNow()
	local memAfterFreeze = clientMemoryMB()
	if memAfterFreeze ~= nil then
		say(string.format("client memory after render freeze: %.0f MB", memAfterFreeze))
		if (CFG.AbortMemoryMB or 0) > 0 and memAfterFreeze > CFG.AbortMemoryMB then
			local msg = string.format(
				"client memory %.0f MB is above %d MB: Roblox would crash on any dump. Rejoin the game (or lower graphics) and run again.",
				memAfterFreeze, CFG.AbortMemoryMB)
			RUN.state = "failed"
			pcall(writeFailedFile, msg)
			pcall(function() rawWrite(STATUS_PATH, buildStatusText()) end)
			print("NYX_DUMP_ABORTED: " .. msg)
			return
		end
	end

	runPhase("place_info", readPlaceInfo)
	writeEnvFile()

	local onlyPlace = CFG.OnlyPlaceFile == true
	RUN.onlyPlace = onlyPlace

	runPhase("collect", function()
		collectAll()
		finalizeCollection()
		say("instances: " .. tostring(#entries) .. " services: " .. tostring(#serviceRoots))
	end)
	if RUN.streaming == true then
		say("WARNING: workspace streaming is ON -> only loaded map chunks can be dumped")
	end
	gcNow("after_collect")

	if CFG.UseSaveInstance and saveInstanceFn ~= nil and not RUN.safeMode then
		runPhase("saveinstance", trySaveInstance)
	end
	if CFG.DumpXml then
		gcNow("before_xml")
		runPhase("xml", dumpPlaceXml)
		gcNow("after_xml")
		say("built-in place file ready: " .. xmlSummaryText())
	end
	if RUN.placeMode ~= "none" then
		say("place file ready: " .. placeSummaryText())
	end
	runPhase("report-early", writeReports)

	if not onlyPlace then
		runPhase("data", function()
			dumpJsonData()
			writeServicesTxt()
		end)
		runPhase("guis", dumpGuiModels)
		runPhase("models", dumpTopModels)
		if CFG.DumpScripts and not RUN.safeMode then
			runPhase("scripts", dumpScripts)
		end
		gcNow("after_scripts")
		runPhase("assets", dumpAssets)
		gcNow("after_assets")
	end

	restoreRendering()
	setState("done", "report")
	say("writing final report...")
	local okReport, summary = pcall(writeReports)
	if not okReport then
		addError("report", tostring(summary))
	end
	writeDoneFile(type(summary) == "table" and summary or nil)
	printDoneBanner()
	if RUN.safeMode then
		print("")
		print("[NyxDump] SafeMode was on: native place file and script decompile were disabled.")
		print("    If your executor already supports the current Roblox version, run again with")
		print("    _G.NYX_DUMP_CONFIG = { SafeMode = false }  (before the dumper script).")
	end
	if scriptStats.bytecodeOnly > 0 then
		print("")
		print("[NyxDump] " .. tostring(scriptStats.bytecodeOnly)
			.. " script(s) still have no source (.bytecode only).")
		if requestFn ~= nil then
			print("    online recovery inside the script did not finish them; optional extra pass:")
		else
			print("    this executor has no request(), so run one optional pass on PC:")
		end
		print("    python tools\\decompile_remaining.py \"" .. rootPath .. "\"")
	end
	print("NYX_DUMP_DONE")
end

local okMain, mainErr = pcall(main)
if not okMain then
	RUN.state = "failed"
	pcall(writeFailedFile, tostring(mainErr))
	pcall(function() rawWrite(STATUS_PATH, buildStatusText()) end)
	if type(G) == "table" then
		pcall(function() G.NYX_DUMP_SUMMARY = { tool = "NyxDump", version = VERSION, ok = false, root = rootName, error = tostring(mainErr) } end)
	end
	print("NYX_DUMP_FAILED: " .. tostring(mainErr))
	pcall(function() print("look at STATUS.txt / FAILED.txt in " .. rootPath) end)
end
