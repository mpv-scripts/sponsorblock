-- Copyright: 2021 Vadim "mva" Misbakh-Soloviov
-- License: GNU AGPLv3 (for text see LICENSE file)
-- Contact me if you need it to be licensed under another license for you company.
--
-- This script is a plugin for mediaplayer called "mpv".
-- It allows to skip some video segments (usually advertisement) bundled in videos.
--
-- Currently, it only activates on YouTube videos only, but support for other platforms may be added in future.
-- Some blocks of code may be taken or written under impression of https://codeberg.org/jouni/mpv_sponsorblock_minimal
-- in such cases cretits goes to that guy (I don't know neither name, nor even sex/pronounces,
-- as at the time of writing that profile on codeberg is not filled with such info
-- Motivation to write this plugin was disagreement with that author about whether user needs config file
-- and refusing my PR with config file implementations

-- Sugar {{{
local bool = function(inp)
	if type(inp) == "string" then
		if inp == "0" or inp == "false" then
			return false
		else
			return true
		end
	end
	return not(not(inp))
end
local str = tostring
local num = tonumber
-- }}}

-- Variables (definitions) {{{
-- luacheck: read_globals mp
local config = {}
config.file = "script-opts/sponsor.mpv.lua.conf"
config.defaults = {
	-- TODO: add servername?
	skipsegments_url = "https://sponsor.ajay.app/api/skipSegments",
	categories = {
		"sponsor",
		"intro",
		"outro",
		"interaction",
		"selfpromo",
	},
	enabled = true
}
config.options = config.defaults
config.cache = {}
config.metadata = {}
local msg = require "mp.msg"
-- }}}

-- Functions {{{
-- Throw an error {{{
local function throw(kind,text,...)
	local mesg = str(text):format(...)
	msg[kind](mesg)
	mp.osd_message(("[sponsor] %s"):format(mesg))
end
-- Throw an error }}}

-- Load Config {{{
function config:load()
	-- Credit: Code of this function is based on the similar function from "skip-logo" script from mpv source base.
	local conf_file = mp.find_config_file(config.file)
	local conf_fn
	local cfg = {}
	local err = nil

	if conf_file then -- {{{
		if setfenv then
			conf_fn, err = loadfile(conf_file)
			if conf_fn then
				setfenv(conf_fn, cfg)
			end
		else
			conf_fn, err = loadfile(conf_file, "t", cfg)
		end
	end -- }}}

	if conf_fn and (not err) then
			local _, err2 = pcall(conf_fn)
			err = err2
	end

	if err then
		msg.error("Failed to load config file:", err)
	end

	for k,_ in pairs(self.options) do -- {{{
		if cfg[k] then -- {{{
			if k == "skipsegments_url" then -- {{{
				self.options[k] = cfg[k]:match("^(.+)/?$")
			elseif k == "categories" then
				if type(cfg[k]) == "table" then
					self.options[k] = ([["%s"]]):format(table.concat(cfg.categories,[[","]]))
				else
					throw("warn",
						[[Option named "%s" should be a table (but somewhy it is %s). Using default value.]],
						k, type(cfg[k])
					)
				end
			elseif k == "enabled" then
				self.options[k] = bool(cfg[k])
			else
				self.options[k] = cfg[k]
			end -- if (individual options) }}}
			-- TODO: more checks?
		end -- if cfg[k] }}}
	end -- for options }}}
end
-- Load Config }}}

-- Save Config {{{
function config:save()
	local conf_file = mp.find_config_file(config.file)
	local f = io.open(conf_file,"w+")
	local config_s
	local function t2s(t,l_arg)
		local lvl = l_arg or 0
		local ret, nl = "", ""
		local v_s
		for k,v in pairs(t) do
			if type(v) == "table" then
				v_s = ("{\n%s\n}"):format(t2s(v,lvl+1))
			else
				v_s = ("%q"):format(str(v))
			end
			if type(k) == "number" then
				ret = ("%s%s%s%s,"):format(ret,nl,("\t"):rep(lvl),v_s)
			else
				ret = ("%s%s%s%s = %s,"):format(ret,nl,("\t"):rep(lvl),k,v_s)
			end
			nl = "\n"
		end
		return ret
	end
	config_s = t2s(self.options)
	msg.warn(config_s)
	f:write(config_s)
	f:close()
end
-- Save Config }}}

-- "Get YouTube URL" Function {{{
local function get_yt_id()
	if config.cache.ytid then
		return config.cache.ytid
	else
		local urls = {
			"https?://youtu%.be/([%w-_]+).*",
			"https?://w?w?w?%.?youtube%.com/v/([%w-_]+).*",
			"/watch.*[?&]v=([%w-_]+).*",
			"/embed/([%w-_]+).*",
			"-([%w-_]+)%."
		}
		local v_urls = {
			str(config.metadata.path),
			str(config.metadata.referer),
			str(config.metadata.purl),
		}
		for _,url in ipairs(urls) do
			for _,u in ipairs(v_urls) do
				local m = u:match(url)
				if m then
					config.cache.ytid = m
					return config.cache.ytid
				end -- if m
			end -- for u
		end -- for url
	end -- if not cached
end
-- "Get YouTube URL" Function }}}

-- "Get ranges" function {{{
local function get_ranges(id)
	if config.cache[config.metadata.path] and config.cache[config.metadata.path].ranges then
		return config.cache[config.metadata.path].ranges
	else
		local res
		local UA = "sponsorblock.mpv.lua/0.0.0"
		local luacurl_available, cURL = pcall(require,'cURL')

		id = id:sub(1, 11)

		local args = {
			([=[categories=["%s"]]=]):format(table.concat(config.options.categories, [[","]])),
			([=[videoID=%s]=]):format(id),
		}
		local API = ("%s?%s"):format(config.options.skipsegments_url, table.concat(args, "&"))
		if luacurl_available then
			local buf={}
			local c = cURL.easy_init()
			c:setopt_followlocation(1)
			c:setopt_useragent(UA)
			c:setopt_url(API)
			c:setopt_writefunction(function(chunk) table.insert(buf,chunk); return true; end)
			c:perform()
			res = table.concat(buf)
		else
			local curl_cmd = {
				"curl",
				"-L", "-S", "-s",
				"-A", UA,
				("%q"):format(API),
			}
			local sponsors = mp.command_native{
				name = "subprocess",
				capture_stdout = true,
				playback_only = false,
				args = curl_cmd
			}
			res = sponsors.stdout
		end -- if luacurl

		local ranges = {}
		if res:match"%[(.-)%]" then
			for r in res:sub(2,-2):gmatch"%[(.-)%]" do
				local k, v = r:match"(%d+.?%d*),(%d+.?%d*)"
				ranges[k] = v
			end -- for r
		end -- if res:match
		config.cache[config.metadata.path] = {}
		config.cache[config.metadata.path].ranges = ranges
		return ranges
	end -- if ranges
end
-- "Get ranges" function }}}

-- "skip ads" function {{{
local function skip_ads(_, pos)
	if pos ~= nil then
		local id = get_yt_id()
		local ranges = get_ranges(id)
		for k,v in pairs(ranges) do
			k, v = num(k), num(v)
			if k <= pos and v > pos then
				throw("info",("skipping %ds"):format(math.floor(v - pos)))
				mp.set_property("time-pos", v)
				return
			end -- if k<=pos,v>pos
		end -- for ranges
	end -- if pos!=nil
	return
end
-- "skip ads" function }}}

-- "enable/disable/toggle" {{{
local function enable()
	mp.observe_property("time-pos", "native", skip_ads)
	throw("info","on")
	config.options.enabled = true
end
local function disable()
	mp.unobserve_property(skip_ads)
	throw("info","off")
	config.options.enabled = false
end
local function toggle()
	if config.options.enabled then
		disable()
	else
		enable()
	end
end
-- "en-dis-toggle" }}}

-- Fill metadata {{{
function config.metadata:fill()
	self.path = mp.get_property("path")
	self.referer = mp.get_property("http-header-fields", ""):match("Referer:([^,]+)")
	self.purl = mp.get_property("metadata/by-key/PURL")
end
-- fill metadata }}}

-- "on file load" hook {{{
local function on_load_hook() -- luacheck: ignore 2
	config:load()
	if not(config.options.enabled) then
		throw("warn","Not starting: disabled in config")
		return
	end
	config.metadata:fill()
	local id = get_yt_id()
	if not(id) or #id < 11 then -- not YouTube ID
		-- TODO: think about proper way to make sure getting the ID was correct,
		-- because someday google will change length of IDs and this code will shoot in the leg
		return
	end

	local ranges = get_ranges(id)
	if ranges then
		mp.add_key_binding("b", "sponsorblock", toggle)
		mp.observe_property("time-pos", "native", skip_ads)
	end
	return
end
-- "on file load" hook }}}

-- "on file end" hook {{{
local function on_end_hook()
	if not(config.options.enabled) then
		return
	end
	mp.unobserve_property(skip_ads)
	config.cache[(config.metadata.path or "")] = nil
end
-- "on file end" hook }}}
-- }}}

mp.register_event("file-loaded", on_load_hook)
mp.register_event("end-file", on_end_hook)
