--[[
Copyright (C) 2013  simplex

This program is free software; you can redistribute it and/or
modify it under the terms of the GNU General Public License
as published by the Free Software Foundation; either version 2
of the License, or (at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program.  If not, see <http://www.gnu.org/licenses/>.
]]--

local function uuid()
	return {}
end

local NewGetter = (function()
	local function doget_wrapper(self, k)
		local v = self[self](k)
		if v == nil then
			return error(("Required variable %s not set."):format(k), 3)
		end
		return v
	end

	local getter_meta = {
		__index = doget_wrapper,
		__call = doget_wrapper,
	}

	return function(kernel)
		local function doget(k)
			local v = kernel[k]
			if v == nil then
				v = kernel._G[k]
			end
			return v
		end

		local rawget = doget "rawget"

		local function doget_opt(k, dflt_v)
			local v = kernel[k]
			if v == nil then
				v = rawget(kernel._G, k)
			end
			if v == nil then
				if dflt_v == nil then
					return error(("Required variable %s not set."):format(k), 2)
				end
				return dflt_v
			else
				return v
			end
		end

		local setmetatable = doget "setmetatable"

		local ret = {}
		ret[ret] = doget
		ret.opt = doget_opt

		return setmetatable(ret, getter_meta)
	end
end)()

local function lambdaif(p)
	return function(a, b)
		if p() then
			return a
		else
			return b
		end
	end
end
local function immutable_lambdaif(p)
	if p() then
		return function(a, b)
			return a
		end
	else
		return function(a, b)
			return b
		end
	end
end

local function const(x)
	return function()
		return x
	end
end

local Nil = const()
local True, False = const(true), const(false)
local Zero, One = const(0), const(1)

local function id(x) return x end

local function bindfst(f, x)
	return function(...)
		return f(x, ...)
	end
end

local function compose(f, g)
	return function(...)
		return f(g(...))
	end
end

local function NewLazyComposer(env)
	return function(f, gkey)
		return function(...)
			return f(env[gkey](...))
		end
	end
end

----------

-- "tee" here refers to the Unix utility tee.
-- We provide similar functionality where environment newindexing takes place
-- of text output.
local tee, clear_tee = (function()
	local env_data = {}

	local function get_env_data(env)
		local data = env_data[env]
		if data == nil then
			data = { get = NewGetter(env) }
			env_data[env] = data
		end
		return data
	end

	local tee
	local get_tees, clear_tees
	local get_tree_newindex

	local function get_tees_meta(env)
		local data = get_env_data(env)
		local meta = data.teesmeta
		if meta == nil then
			meta = {
				__call = function()
					clear_tees(env)
				end
			}
			data.teesmeta = meta
		end
		return meta
	end

	get_tees = function(env)
		local data = get_env_data(env)
		local tees = data.tees
		if tees == nil then
			tees = data.get.setmetatable({}, get_tees_meta(env))
			data.tees = tees

			local env_meta = data.get.getmetatable(env)
			if env_meta == nil then
				env_meta = {}
				data.get.setmetatable(env, env_meta)
				data.had_meta = false
			else
				data.had_meta = true
				data.oldnewindex = env_meta.__newindex
			end

			env_meta.__newindex = get_tree_newindex(env)
		end
		return tees
	end

	clear_tees = function(env)
		local data = env_data[env]
		if data then
			env_data[env] = nil
			local tees = data.tees
			if tees then
				if not data.had_meta then
					data.get.setmetatable(env, nil)
				else
					data.get.getmetatable(env).__newindex = data.oldnewindex
				end
			end
		end
	end

	local function clear_tee(env, t)
		local data = get_env_data(env)
		local tees = get_tees(env)
		tees[t] = nil
		if data.get.next(tees) == nil then
			return clear_tees(env)
		end
	end

	get_tree_newindex = function(env)
		local data = get_env_data(env)
		local newindex = data.newindex
		if newindex == nil then
			local tees = get_tees(env)
			
			local pairs = data.get.pairs
			local rawset = data.get.rawset

			newindex = function(t, k, v)
				for tee in pairs(tees) do
					tee[k] = v
				end
				rawset(t, k, v)
			end

			data.newindex = newindex
		end
		return newindex
	end

	local function get_tee_meta(env)
		local data = get_env_data(env)
		local meta = data.teemeta
		if meta == nil then
			meta = {
				__call = function(self)
					clear_tee(env, self[self])
				end,
			}
			data.teemeta = meta
		end
		return meta
	end

	local function tee(env, t)
		t = t or {}

		local data = get_env_data(env)

		local ret = {}
		ret[ret] = t
		data.get.setmetatable(ret, get_tee_meta(env))

		local tees = get_tees(env)
		tees[t] = true

		return ret
	end

	return tee, clear_tee
end)()

local function make_inner_env(kernel)
	local get = NewGetter(kernel)

	local inner_env = {}
	inner_env._M = inner_env
	inner_env.lazy_compose = NewLazyComposer(inner_env)

	local inner_meta = {
		__index = kernel,
	}
	get.setmetatable(inner_env, inner_meta)

	local proto = tee(inner_env, kernel)
	inner_meta.__call = function(...) proto(...) return inner_env end

	get.setfenv(2, inner_env)

	return inner_env
end

----------

local function include_corelib(kernel)
	local get = NewGetter(kernel)

	local _G = get._G

	local assert, error = get.assert, get.error
	local VarExists = get.VarExists

	local type = get.type
	local rawget, rawset = get.rawget, get.rawset

	local getmetatable, setmetatable = get.getmetatable, get.setmetatable
	local table, math = get.table, get.math

	local pairs, ipairs = get.pairs, get.ipairs
	local next = get.next

	local tostring = get.tostring

	local unpack = get.unpack

	---

	local CORELIB_ENV = make_inner_env(kernel)

	---
	
	local function IsCallable(x)
		if type(x) == "function" then
			return true
		end
		local mt = getmetatable(x)
		return mt and mt.__call
	end
	local IsFunctional = IsCallable
	_M.IsCallable = IsCallable
	_M.IsFunctional = IsFunctional

	---

	local function listify_higherorder(F)
		return function(f, ...)
			local function g(...)
				local frets = {f(...)}
				if frets[1] == nil then
					return nil
				else
					return frets
				end
			end

			local rets = F(g, ...)
			if rets ~= nil then
				return unpack(rets)
			end
		end
	end

	local MEMOIZE_NIL = uuid()

	local memoize_cache_meta = {__mode = "k"}

	local function make_cache()
		return setmetatable({}, memoize_cache_meta)
	end

	--[[
	-- This is optimized compared to the (n >= 1)-ary versions in that if the
	-- clear function is not stored, then the memoized function will have
	-- their references freed once the computation is done, allowing for
	-- memory reclaim by the GC.
	--]]
	local function memoize_0ary(f, dont_retry)
		local y = nil
		local f0 = f

		local function clear()
			local old = y
			y = nil
			f = f0
			return old
		end

		return function()
			if y == nil and f ~= nil then
				y = f()
				if y ~= nil or dont_retry then
					f = nil
				end
			end
			return y
		end, clear
	end

	--[[
	-- This one is reimplemented in full for efficiency.
	--]]
	local function memoize_0ary_inplace(cachekey, f, dont_retry)
		local NIL = MEMOIZE_NIL

		local function clear(mastercache)
			local old = mastercache[cachekey]
			mastercache[cachekey] = nil
			return old
		end

		return function(mastercache)
			local y = mastercache[cachekey]
			if y == nil then
				y = f()
				if y == nil and dont_retry then
					mastercache[cachekey] = NIL
				end
			elseif y == NIL then
				y = nil
			end
			return y
		end, clear
	end

	local function lift_inplace_memoize(inplace_memoize)
		local function process_memoized(g, clear, ...)
			-- We do *not* use a weak table at the top level.
			-- Note we only use a single key into it (1).
			local mastercache = {}

			local function h(...)
				return g(mastercache, ...)
			end

			local function clear2(...)
				return clear(mastercache, ...)
			end

			return h, clear2, ...
		end

		return function(...)
			return process_memoized(inplace_memoize(1, ...))
		end
	end

	local function memoize_1ary_inplace(cachekey, f, dont_retry)
		local NIL = MEMOIZE_NIL

		local function clear(mastercache)
			local old = mastercache[cachekey]
			mastercache[cachekey] = nil
			return old
		end

		return function(mastercache, x)
			local cache = mastercache[cachekey]
			if cache == nil then
				cache = make_cache()
				mastercache[cachekey] = cache
			end

			if x == nil then
				x = NIL
			end
			local y = cache[x]
			if y == nil then
				y = f(x)
				if y ~= nil then
					cache[x] = y
				elseif dont_retry then
					cache[x] = NIL
				end
			elseif y == NIL then
				y = nil
			end
			return y
		end, clear
	end
	local memoize_1ary = lift_inplace_memoize(memoize_1ary_inplace)

	local function raw_memoize_nary_inplace(cachekey, f, n, dont_retry)
		local NIL = MEMOIZE_NIL

		local function clear(mastercache)
			local old = mastercache[cachekey]
			mastercache[cachekey] = nil
			return old
		end
		
		return function(mastercache, ...)
			local args = {...}

			local NIL = NIL

			local last_subroot = mastercache
			local last_key = cachekey
			for i = 1, n do
				local xi = args[i]
				if xi == nil then
					xi = NIL
				end

				local subroot = last_subroot[last_key]
				if subroot == nil then
					subroot = make_cache()
					last_subroot[last_key] = subroot
				end

				last_subroot = subroot
				last_key = x1
			end

			local y = last_subroot[last_key]
			if y == nil then
				y = f(...)
				if y ~= nil then
					last_subroot[last_key] = y
				elseif dont_retry then
					last_subroot[last_key] = NIL
				end
			elseif y == NIL then
				y = nil
			end

			return y
		end, clear
	end

	local raw_memoize_nary = lift_inplace_memoize(raw_memoize_nary_inplace)

	local memoize_inplace = function(cachekey, n)
		if n < 1 then
			return bindfst(memoize_0ary, cachekey)
		elseif n < 2 then
			return bindfst(memoize_1ary, cachekey)
		else
			return function(f, ...)
				return raw_memoize_nary(cachekey, f, n, ...)
			end
		end
	end

	local function memoize_nary_inplace(cachekey, f, n, ...)
		return memoize_inplace(cachekey, n)(f, ...)
	end

	local memoize = memoize_1ary(function(n)
		if n < 1 then
			return memoize_0ary
		elseif n < 2 then
			return memoize_1ary
		else
			return function(f, ...)
				return raw_memoize_nary(f, n, ...)
			end
		end
	end)

	local function memoize_nary(f, n, ...)
		return memoize(n)(f, ...)
	end

	_M.memoize_0ary_inplace = memoize_0ary_inplace
	_M.memoize_1ary_inplace = memoize_1ary_inplace
	_M.memoize_nary_inplace = memoize_nary_inplace
	_M.memoize_inplace = memoize_inplace

	_M.memoize_0ary = memoize_0ary
	_M.memoize_1ary = memoize_1ary
	_M.memoize_nary = memoize_nary
	_M.memoize = memoize

	---
	
	_M.tee, _M.clear_tee = tee, clear_tee

	---

	local function ShallowInject(tgt, src)
		for k, v in pairs(src) do
			tgt[k] = v
		end
		return tgt
	end
	_M.ShallowInject = ShallowInject

	local function ShallowCopy(t)
		return ShallowInject({}, t)
	end
	_M.ShallowCopy = ShallowCopy

	local function DeepTreeInject(tgt, src)
		for k, v in pairs(src) do
			if type(v) == "table" then
				local tgt_k = tgt[k]
				if type(tgt_k) ~= "table" then
					tgt_k = {}
					tgt[k] = tgt_k
				end
				DeepTreeInject(tgt_k, v)
			else
				tgt[k] = v
			end
		end
	end
	_M.DeepTreeInject = DeepTreeInject
	_M.DeepInject = DeepTreeInject

	local function DeepTreeCopy(t)
		return DeepTreeInject({}, t)
	end
	_M.DeepTreeCopy = DeepTreeCopy
	_M.DeepCopy = DeepCopy

	local function DeepGraphInject_internal(tgt, src, refmap)
		for k, v in pairs(src) do
			if type(v) == "table" then
				local tgt_k = refmap[v]
				if tgt_k ~= nil then
					tgt[k] = tgt_k
				else
					tgt_k = tgt[k]
					if type(tgt_k) ~= "table" then
						tgt_k = {}
						tgt[k] = tgt_k
					end

					refmap[v] = tgt_k

					DeepGraphInject_internal(tgt_k, v, refmap)
				end
			end
		end
	end

	local function DeepGraphInject(tgt, src)
		return DeepGraphInject_internal(tgt, src, {[src] = tgt})
	end
	_M.DeepGraphInject = DeepGraphInject

	local function DeepGraphCopy(t)
		return DeepGraphInject({}, t)
	end
	_M.DeepGraphCopy = DeepGraphCopy

	-- Returns the size of a table including *all* entries.
	local function cardinal(t)
		local sz = 0
		for _ in pairs(t) do
			sz = sz + 1
		end
		return sz
	end
	_M.cardinal = cardinal

	local function cardinalset(n)
		if type(n) == "table" then
			n = cardinal(n)
		end
		local s = {}
		for i = 1, n do
			s[i] = true
		end
		return s
	end
	_M.cardinalset = cardinalset

	-- Compares cardinal(t) and n.
	--
	-- Returns -1 if cardinal(t) < n
	-- Returns 0 if cardinal(t) == n
	-- Returns +1 if cardinal(t) > n
	local function withnum_cardinalcmp(t, n)
		-- cardinal(t) - n
		local difference = -n
		for _ in pairs(t) do
			difference = difference + 1
			if difference > 0 then
				return 1
			end
		end
		if difference == 0 then
			return 0
		else
			return -1
		end
	end

	local function withtable_cardinalcmp(t, u)
		-- cardinal(t) - cardinal(n)
		local difference = 0

		local k_t, k_u = next(t), next(u)
		while k_t ~= nil and k_u ~= nil do
			k_t, k_u = next(t), next(u)
		end

		if k_t == nil then
			if k_u == nil then
				return 0
			else
				return -1
			end
		else
			return 1
		end
	end

	local function card_type_error(x)
		return "Value '"..tostring(x).."' has no cardinal.", 2
	end

	local function cardinalcmp(m, n)
		local ty_m, ty_n = type(m), type(n)

		if ty_m == "number" then
			if ty_n == "number" then
				return m - n
			else
				return -cardinalcmp(n, m)
			end
		else
			if ty_m ~= "table" then
				return error(card_type_error(m))
			end
			if ty_n == "number" then
				return withnum_cardinalcmp(m, n)
			else
				if ty_n ~= "table" then
					return error(card_type_error(n))
				end
				return withtable_cardinalcmp(m, n)
			end
		end
	end
	_M.cardinalcmp = cardinalcmp

	local function value_dump(t)
		require "dumper"

		local str = _G.DataDumper(t, nil, false)
		return ( str:gsub("^return%s*", "") )
	end
	_M.value_dump = value_dump
	_M.table_dump = value_dump

	---
	
	return CORELIB_ENV()
end

----------

local function include_platform_detection_functions(kernel)
	local get = NewGetter(kernel)

	local _G = get._G

	local assert, error = get.assert, get.error
	local VarExists = get.VarExists

	local type = get.type
	local rawget, rawset = get.rawget, get.rawset

	local getmetatable, setmetatable = get.getmetatable, get.setmetatable
	local table, math = get.table, get.math

	local pairs, ipairs = get.pairs, get.ipairs
	local next = get.next

	---

	local GetModDirectoryName = get.GetModDirectoryName

	---
	
	local PLATFORM_DETECTION = make_inner_env(kernel, _G)

	---

	IsDST = memoize_0ary(function()
		return _G.kleifileexists("scripts/networking.lua") and true or false
	end)
	local IsDST = IsDST
	IsMultiplayer = IsDST

	IfDST = immutable_lambdaif(IsDST)
	IfMultiplayer = IfDST

	function IsSingleplayer()
		return not IsDST()
	end
	local IsSingleplayer = IsSingleplayer

	IfSingleplayer = immutable_lambdaif(IsSingleplayer)

	---

	IsDLCEnabled = get.opt("IsDLCEnabled", False)
	IsDLCInstalled = get.opt("IsDLCInstalled", IsDLCEnabled)

	REIGN_OF_GIANTS = get.opt("REIGN_OF_GIANTS", 1)
	CAPY_DLC = get.opt("CAPY_DLC", 2)

	---

	IsRoG = memoize_0ary(function()
		if IsDST() then
			return true
		else
			return IsDLCEnabled(REIGN_OF_GIANTS) and true or false
		end
	end)
	IsROG = IsRoG

	IsSW = memoize_0ary(function()
		return IsDLCEnabled(CAPY_DLC) and true or false
	end)

	IfRoG = immutable_lambdaif(IsRoG)
	IfROG = IfRoG

	IfSW = immutable_lambdaif(IsSW)

	---

	return PLATFORM_DETECTION()
end

----------

local function include_constants(kernel)
	local get = NewGetter(kernel)

	local _G = get._G

	local assert, error = get.assert, get.error
	local VarExists = get.VarExists

	local type = get.type
	local rawget, rawset = get.rawget, get.rawset

	local getmetatable, setmetatable = get.getmetatable, get.setmetatable
	local table, math = get.table, get.math

	local pairs, ipairs = get.pairs, get.ipairs
	local next = get.next

	local tostring = get.tostring

	---

	local CONSTANTS_ENV = make_inner_env(kernel, _G)

	---
	
	local function addConstants(name, t)
		if t == nil then
			return bindfst(addConstants, name)
		end

		local t2 = ShallowCopy(t)

		local _N
		if name == nil then
			_N = _M
		else
			_N = _M[name]
			if not _N then
				_N = {}
				_M[name] = _N
			end
		end

		ShallowInject(_N, t)
	end

	local dflts = {}
	local function addDefaultConstants(name, t)
		if t == nil then
			return bindfst(addDefaultConstants, name)
		end

		addConstants(name, t)

		local _N
		if name == nil then
			_N = dflts
		else
			_N = dflts[name]
			if not _N then
				_N = {}
				dflts[name] = _N
			end
		end

		ShallowInject(_N, t)
	end

	local validateConstants = (function()
		local function atomic_error(val)
			return {tostring(val)}
		end

		local function rec_find_error(dflt_subroot, check_subroot)
			local dflt_type = type(dflt_subroot)
			local check_type = type(check_subroot)

			if dflt_type ~= check_type then
				return atomic_error(check_subroot)
			end

			if dflt_type ~= "table" then
				if dflt_subroot ~= check_subroot then
					return atomic_error(check_subroot)
				end
			else
				for name, v in pairs(dflt_subroot) do
					local err = rec_find_error(v, check_subroot[name])
					if err then
						local myerr = atomic_error(name)
						myerr.next = err
						return myerr
					end
				end
			end
		end

		return function()
			local err = rec_find_error(dflts, _M)
			if err then
				local push = table.insert
				
				local keys = {}
				local val = nil

				while err.next do
					push(keys, err[1])
					err = err.next
				end
				val = assert( err[1] )
				err = err.next
				assert( err == nil )

				local msg = ("Constant %s = %s violates default assumptions.")
					:format(table.concat(keys, "."), val)

				return error(msg, 0)
			end
		end
	end)()

	---
	

	addConstants (nil) {
		DONT_STARVE_APPID = get.opt("DONT_STARVE_APPID", 219740),
		DONT_STARVE_TOGETHER_APPID = get.opt("DONT_STARVE_TOGETHER_APPID", 322330),
	}

	addDefaultConstants "SHARDID" {
		INVALID = "0", 
		MASTER = "1",
	}

	addDefaultConstants "REMOTESHARDSTATE" {
		OFFLINE = 0, 
		READY = 1, 
	}

	if IsDST() then
		_M.SHARDID = assert(_G.SHARDID)
		_M.REMOTESHARDSTATE = assert(_G.REMOTESHARDSTATE)
	else
		addConstants "SHARDID" {
			CAVE_PREFIX = "2",
		}
	end

	---
	
	validateConstants()
	return CONSTANTS_ENV()
end

---

local function include_introspectionlib(kernel)
	local get = NewGetter(kernel)

	local _G = get._G

	local assert, error = get.assert, get.error
	local VarExists = get.VarExists

	local type = get.type
	local rawget, rawset = get.rawget, get.rawset

	local getmetatable, setmetatable = get.getmetatable, get.setmetatable
	local table, math = get.table, get.math

	local pairs, ipairs = get.pairs, get.ipairs
	local next = get.next

	---
	
	local INTRO_ENV = make_inner_env(kernel)

	---
	
	IsWorldgen = memoize_0ary(function()
		return rawget(_G, "SEED") ~= nil
	end)
	local IsWorldgen = IsWorldgen
	IsWorldGen = IsWorldgen
	AtWorldgen = IsWorldgen
	AtWorldGen = IsWorldgen

	IfWorldgen = immutable_lambdaif(IsWorldgen)
	IfWorldGen = IfWorldgen

	---

	GetWorkshopId = memoize_0ary(function()
		local dirname = GetModDirectoryName():lower()
		local strid = dirname:match("^workshop%s*%-%s*(%d+)$")
		if strid ~= nil then
			return tonumber(strid)
		end
	end)
	GetSteamWorkshopId = GetWorkshopId
	local GetWorkshopId = GetWorkshopId

	IsWorkshop = function()
		return GetWorkshopId() ~= nil
	end
	IsSteamWorkshop = IsWorkshop
	local IsWorkshop = IsWorkshop


	---

	local GetSteamAppID
	local has_TheSim = VarExists("TheSim")
	if has_TheSim and _G.TheSim.GetSteamAppID then
		GetSteamAppID = function()
			return _G.TheSim:GetSteamAppID()
		end
	else
		GetSteamAppID = function()
			if IsDST() then
				return DONT_STARVE_TOGETHER_APPID
			else
				return DONT_STARVE_APPID
			end
		end
		if has_TheSim then
			getmetatable(_G.TheSim).__index.GetSteamAppID = GetSteamAppID
		end
	end
	GetSteamAppId = GetSteamAppID

	---

	if IsDST() then
		GetPlayerId = function(player)
			return player.userid
		end
	else
		GetPlayerId = One
	end
	GetPlayerID = GetPlayerId
	GetUserId = GetPlayerId
	GetUserID = GetPlayerID

	---

	local is_vacuously_host = memoize_0ary(function()
		return IsWorldgen() or not IsMultiplayer()
	end)

	IsHost = function()
		if is_vacuously_host() then
			return true
		else
			return _G.TheNet:GetIsServer() and true or false
		end
	end
	local IsHost = IsHost
	IsServer = IsHost

	IsMasterSimulation = function()
		if is_vacuously_host() then
			return true
		else
			return _G.TheNet:GetIsMasterSimulation() and true or false
		end
	end
	IsMasterSim = IsMasterSimulation

	IfHost = immutable_lambdaif(IsHost)
	IfServer = IfHost

	IfMasterSimulation = immutable_lambdaif(IsMasterSimulation)
	IfMasterSim = IfMasterSimulation

	IsClient = function()
		if is_vacuously_host() then
			return false
		else
			return _G.TheNet:GetIsClient() and true or false
		end
	end

	IfClient = immutable_lambdaif(IsClient)

	IsDedicated = (function()
		if IsWorldgen() then
			return true
		elseif IsSingleplayer() then
			return false
		else
			return _G.TheNet:IsDedicated() and true or false
		end
	end)
	local IsDedicated = IsDedicated
	IsDedicatedHost = IsDedicated
	IsDedicatedServer = IsDedicated

	IfDedicated = immutable_lambdaif(IsDedicated)

	---

	local function can_be_shard()
		return IsDST() and IsServer() and not IsWorldgen() and VarExists("TheShard")
	end

	IsMasterShard = memoize_0ary(function()
		return can_be_shard() and _G.TheShard:IsMaster()
	end)

	IsSlaveShard = memoize_0ary(function()
		return can_be_shard() and _G.TheShard:IsSlave()
	end)

	IsShardedServer = memoize_0ary(function()
		return IsMasterShard() or IsSlaveShard()
	end)
	IsShard = IsShardedServer

	IfMasterShard = immutable_lambdaif(IsMasterShard)

	IfSlaveShard = immutable_lambdaif(IsSlaveShard)

	IfShardedServer = immutable_lambdaif(IsShardedServer)
	IfShard = IfShardedServer

	---
	
	local function GetSaveIndex()
		return rawget(_G, "SaveGameIndex")
	end
	_M.GetSaveIndex = GetSaveIndex

	local function current_wrap(fn)
		return function(...)
			return fn(nil, ...)
		end
	end

	local function GetCurrentSaveSlot()
		local slot = nil

		local sg = GetSaveIndex()
		if sg then
			slot = sg:GetCurrentSaveSlot()
		end

		return slot or 1
	end
	_M.GetCurrentSaveSlot = GetCurrentSaveSlot

	local GetSlotMode
	if IsDST() then
		GetSlotMode = const "survival"
	else
		GetSlotMode = function(slot)
			slot = slot or GetCurrentSaveSlot()
			local sg = GetSaveIndex()
			if sg then
				return sg:GetCurrentMode(slot)
			end
		end
	end
	_M.GetSlotMode = GetSlotMode

	local GetCurrentMode = current_wrap(GetSlotMode)
	_M.GetCurrentMode = GetCurrentMode

	local function GetSlotData(slot)
		slot = slot or GetCurrentSaveSlot()
		local sg = GetSaveIndex()
		if sg and sg.data and sg.data.slots then
			return sg.data.slots[slot]
		end
	end
	_M.GetSlotData = GetSlotData

	local GetCurrentSlotData = current_wrap(GetSlotData)
	_M.GetCurrentSlotData = GetCurrentSlotData

	-- In DS, returns current mode data.
	local GetSlotWorldData
	if IsDST() then
		GetSlotWorldData = function(slot)
			local slot_data = GetSlotData(slot)
			if slot_data then
				return slot_data.world
			end
		end
	else
		GetSlotWorldData = function(slot)
			slot = slot or GetCurrentSaveSlot()
			local sg = GetSaveIndex()
			if sg then
				return sg:GetModeData(slot, GetSlotMode(slot))
			end
		end
	end

	local GetSlotCaveNum
	if IsDST() then
		GetSlotCaveNum = One
	else
		GetSlotCaveNum = function(slot)
			local sg = GetSaveIndex()
			if sg then
				return sg:GetCurrentCaveNum(slot)
			end
		end
	end

	local GetCurrentCaveNum = current_wrap(GetSlotCaveNum)
	_M.GetCurrentCaveNum = GetCurrentCaveNum

	local GetSlotCaveLevel
	if IsDST() then
		GetSlotCaveLevel = Nil
	else
		GetSlotCaveLevel = function(slot, cavenum)
			local sg = GetSaveIndex()
			if sg and GetSlotMode(slot) == "cave" then
				slot = slot or GetCurrentSaveSlot()
				cavenum = cavenum or GetSlotCaveNum(slot)
				return sg:GetCurrentCaveLevel(slot, cavenum)
			end
		end
	end

	---

	IsSWLevel = memoize_0ary(function()
		local sg = GetSaveIndex()
		if sg then
			return sg:IsModeShipwrecked()
		end
	end)
	
	IfSWLevel = lambdaif(IsSWLevel)

	---

	local doGetShardId = memoize_0ary(function()
		if can_be_shard() then
			local id = _G.TheShard:GetShardId()
			assert( type(id) == "string" )
			return id
		else
			if IsWorldgen() or not IsServer() then
				return SHARDID.INVALID
			end

			if IsDST() or not GetSaveIndex() then
				return nil
			end

			local cavenum = GetCurrentCaveNum()
			local cavelevel = GetCurrentCaveLevel()

			if cavenum and cavelevel then
				local prefix = assert( SHARDID.CAVE_PREFIX )
				return ("%s.%d.%d"):format(prefix, cavenum, cavelevel)
			else
				return SHARDID.MASTER
			end
		end
	end)

	local function GetShardId()
		local id = doGetShardId()
		if id == nil then
			assert(SHARDID.INVALID)
			id = SHARDID.INVALID
		end
		return id
	end
	_M.GetShardId = GetShardId
	_M.GetShardID = GetShardId

	---
	
	return INTRO_ENV()
end

---

local function include_metatablelib(kernel)
	local get = NewGetter(kernel)

	local _G = get._G

	local assert, error = get.assert, get.error
	local VarExists = get.VarExists

	local type = get.type
	local rawget, rawset = get.rawget, get.rawset

	local getmetatable, setmetatable = get.getmetatable, get.setmetatable
	local table, math = get.table, get.math

	local pairs, ipairs = get.pairs, get.ipairs
	local next = get.next

	local tostring = get.tostring

	local debug = get.debug

	local IsFunctional = get.IsFunctional

	---
	
	local METATABLELIB_ENV = make_inner_env(kernel)

	---
	
	-- Returns an __index metamethod followed by a function which flushes the
	-- copy (basically a particular version of Haskell's seq).
	function LazyCopier(source, filter, is_late_filter)
		local cp_index, seq

		local iterate_filter = false

		local ty = type(filter)

		if filter == nil then
			cp_index = function(t, k)
				local v = source[k]
				if v ~= nil then
					rawset(t, k, v)
				end
				return v
			end
		elseif ty == "table" then
			if cardinalcmp(source, filter) > 0 then
				iterate_filter = true
			end

			cp_index = function(t, k)
				if filter[k] then
					local v = source[k]
					if v ~= nil then
						rawset(t, k, v)
					end
					return v
				end
			end
		elseif ty == "function" then
			cp_index = function(t, k)
				if is_late_filter or filter(k) then
					local v = source[k]
					if v ~= nil and (not is_late_filter or filter(k, v)) then
						rawset(t, k, v)
						return v
					end
				end
			end
		else
			return error("Invalid filter given to LazyCopier.", 2)
		end

		if not iterate_filter then
			seq = function(t)
				for k, v in pairs(keys_set) do
					if rawget(t, k) == nil then
						rawset(t, k, t[k])
					end
				end
			end
		else
			seq = function(t)
				for k, p in pairs(filter) do
					if p then
						if t[k] == nil then
							local v = source[k]
							rawset(t, k, v)
						end
					end
				end
			end
		end

		return cp_index, seq
	end

	-- Returns an objects metatable, creating a setting an empty one if it
	-- doesn't exist.
	local function require_metatable(object)
		local meta = getmetatable( object )
		if meta == nil then
			meta = {}
			setmetatable( object, meta )
		end
		return meta
	end
	_M.require_metatable = require_metatable

	-- Normalizes a metamethod name, prepending a "__" if necessary.
	local normalize_metamethod_name = (function()
		local cache = {}

		return function(name)
			local long_name = cache[name]
			if long_name == nil then
				assert(type(name) == "string")

				long_name = name

				local short_name = name:match("^__(.+)$")
				if not short_name then
					short_name = name
					long_name = "__"..name
				end

				cache[short_name] = long_name
				cache[long_name] = long_name
			end
			return long_name
		end
	end)()

	local function table_get(t, k)
		return t[k]
	end

	local function table_set(t, k, v)
		t[k] = v
	end

	local function table_call(t, ...)
		return t(...)
	end

	local function check_metamethod(x, name)
		local meta = getmetatable(x)
		return meta ~= nil and meta[name] ~= nil
	end

	--[[
	-- Table of functions mapping metamethod names to function handling a
	-- non-function metamethod.
	--]]
	local metamethod_get_handler = {
		__index = function(x)
			local ok = table_get
			if type(x) == "table" or check_metamethod(x, "__index") then
				return ok
			end
		end,
		__newindex = function(x)
			local ok = table_set
			if type(x) == "table" or check_metamethod(x, "__newindex") then
				return ok
			end
		end,
		__call = function(x)
			if check_metamethod(x, "__call") then
				return table_call
			end
		end,
	}

	local default_metamethods = {
		__index = rawget,
		__newindex = rawset,
	}

	--[[
	-- Receives the name of a metamethod, which may include or not the "__"
	-- prefix.
	--
	-- It returns a function that attaches a new metamethod of the given type
	-- to a chain of such metamethods. This chain will keep calling
	-- metamethods queued into it until a non-nil return value is obtained.
	--]]
	NewMetamethodManager = memoize_1ary(function(name)
		local metakey = normalize_metamethod_name(name)
		local metachainkey = uuid()
		local metastackkey = uuid()

		local get_handler = metamethod_get_handler[metakey]
		assert(get_handler == nil or type(get_handler) == "function")

		local function fromJust(meta, t)
			if meta == nil then
				meta = {}
				setmetatable(t, meta)
			end
			return meta
		end

		local mgr = {}

		local function clear(t)
			local meta = getmetatable(t)
			if meta ~= nil then
				local rawset = rawset

				rawset(meta, metachainkey, nil)
				rawset(meta, metakey, nil)
			end
			return meta
		end
		mgr.clear = clear

		local function fullclear(t)
			local meta = clear(t)
			if meta ~= nil then
				rawset(meta, metastackkey, nil)
			end
			return meta
		end

		local function truncate(t)
			return fromJust(clear(t), t)
		end

		local function overwrite(t, fn)
			local meta = truncate(t)
			return rawset(meta, metakey, fn)
		end
		mgr.set = overwrite

		function mgr.get(t)
			local meta = getmetatable(t)
			if meta ~= nil then
				return rawget(meta, metakey)
			end
		end
		local get = mgr.get

		function mgr.has(t)
			return get(t) ~= nil
		end

		local function push(t, fn)
			local meta = getmetatable(t)

			local oldmethod
			if meta ~= nil then
				oldmethod = rawget(meta, metakey)
			end

			if oldmethod ~= nil then
				local stack = rawget(meta, metastackkey)
				if stack == nil then
					stack = {}
					rawset(meta, metastackkey, stack)
				end

				local oldchain = rawget(meta, metachainkey)
				table.insert(stack, {oldmethod, oldchain})
			end

			meta = fromJust(meta, t)
			rawset(meta, metakey, fn)
		end
		mgr.push = push

		local function pop(t)
			local meta = getmetatable(t)

			if meta ~= nil then
				local stack = rawget(meta, metastackkey)
				if stack ~= nil then
					local old = table.remove(stack)
					if old ~= nil then
						rawset(meta, metakey, old[1])
						rawset(meta, metachainkey, old[2])
					end	
				end
			end
		end
		mgr.pop = pop

		local function accessor(t, ...)
			local chain = rawget(getmetatable(t), metachainkey)
			if not chain then return end

			for i = #chain, 1, -1 do
				local metamethod = chain[i]
				local meta_ty = type(metamethod)
				local v
				if meta_ty == "function" then
					v = metamethod(t, ...)
				else
					local handler = get_handler(metamethod)
					if handler then
						v = handler(metamethod, ...)
					else
						local msg = ("Invalid %s metamethod '%s'"):format(metakey, tostring(v))
						return error(msg, 2)
					end
				end
				if v ~= nil then
					return v
				end
			end
		end

		-- If last, it is put in front, because we are using a stack.
		local function include(chain, newv, last)
			if last then
				table.insert(chain, 1, newv)
			else
				table.insert(chain, newv)
			end
			return chain
		end

		local function attach(t, fn, last)
			local meta = require_metatable(t)

			local chain = rawget(meta, metachainkey)
			if chain then
				include(chain, fn, last)
			else
				local oldfn = rawget(meta, metakey)
				if type(fn) == "table" and type(oldfn) == "table" then
					for k, v in pairs(fn) do
						oldfn[k] = v
					end
				else
					if oldfn == nil then
						oldfn = default_metamethods[metakey]
					end
					if oldfn ~= nil then
						rawset(meta, metachainkey, include({oldfn, nil}, fn, last))
						rawset(meta, metakey, accessor)
					else
						rawset(meta, metakey, fn)
					end
				end
			end

			return t
		end
		mgr.attach = attach

		local function detach(t, fn)
			local meta = getmetatable(t)
			if not meta then return end

			local chain = rawget(meta, metachainkey)
			if chain then
				for i, v in ipairs(chain) do
					if v == fn then
						table.remove(chain, i)
						if #chain == 0 then
							rawset(meta, metachainkey, nil)
							rawset(meta, metakey, nil)
						end
						return fn
					end
				end
			end
		end
		mgr.detach = detach
		mgr.dettach = detach

		return mgr
	end)

	local parse_metamethod_args = (function()
		local valid_types = {
			name = {string = true},
			t = {table = true, userdata = true},
		}

		local function fn_test(fn, ty_fn)
			if fn == nil or ty_fn == "function" or ty_fn == "table" then
				return true
			else
				local meta = getmetatable(fn)
				return meta ~= nil and meta.__call ~= nil
			end
		end

		return function(name, t, fn)
			local ty_name, ty_t, ty_fn = type(name), type(t), type(fn)

			if not valid_types.name[ty_name] then
				name, t = t, name
				ty_name, ty_t = ty_t, ty_name
			end

			assert( valid_types.name[ty_name] )
			assert( valid_types.t[ty_t] )
			assert( fn_test(fn, ty_fn) )

			return name, t, fn
		end
	end)()

	local curried_managers = {}

	for methodname in pairs(NewMetamethodManager "DUMMY") do
		local funcname = methodname.."metamethod"

		local curried = memoize_1ary(function(name)
			local op = NewMetamethodManager(name)[methodname]
			return function(t, fn, ...)
				local name2
				name2, t, fn = parse_metamethod_args(name, t, fn)
				assert( name == name2, "Logic error." )
				return op(t, fn, ...)
			end
		end)

		curried_managers[methodname] = curried
		_M[methodname.."metamethod"] = curried

		local function generic(x)
			local ty_x = type(x)
			if ty_x == "string" then
				return curried(x)
			else
				return function(name, ...)
					return curried(name)(...)
				end
			end
		end

		_M["metamethod"..methodname.."er"] = generic
	end

	_M.metamethodpopper = _M.metamethodpoper

	local function capitalize(str)
		return str:sub(1, 1):upper()..str:sub(2):lower()
	end

	local sample_attachers = {
		__index = "Index",
		__newindex = "NewIndex",
		__call = "Call",
		__tostring = "ToString",
	}

	for name, label in pairs(sample_attachers) do
		for methodname, func in pairs(NewMetamethodManager(name)) do
			local basic_prefix = capitalize(methodname)
			
			local prefixes = {
				basic_prefix,
				basic_prefix.."Meta",
			}

			for _, prefix in ipairs(prefixes) do
				local basic_funcname = prefix..label

				local func = curried_managers[methodname](name)

				local funcnames = {
					basic_funcname,
					basic_funcname.."To",
				}

				for _, funcname in ipairs(funcnames) do
					_M[funcname] = func
					_M[funcname:lower()] = func
				end
			end
		end
	end

	---

	local function access_error_msg(kind, self, k)
		return ("Attempt to %s '%s' in readonly table %s."):format(kind, tostring(self), tostring(k))
	end

	local function new_access_error(kind)
		return function(self, k)
			return error(access_error_msg(kind, self, k), 2)
		end
	end

	local write_new_error = new_access_error "create new entry"

	local function freeze(t)
		AttachMetaNewIndexTo(t, write_new_error)
		return t
	end
	_M.freeze = freeze

	local function thaw(t)
		DetachMetaNewIndexFrom(t, write_new_error)
		return t
	end
	_M.thaw = thaw

	local newaccessor = (function()
		local function new_meta(get, set)
			return {
				__index = get or nil,
				__newindex = set or write_new_error,
			}
		end

		return function(get, set)
			return setmetatable({}, new_meta(get, set))
		end
	end)()
	_M.newaccessor = newaccessor

	local props_getters_metakey = {}
	local props_setters_metakey = {}

	local function property_index(object, k)
		local props = rawget(getmetatable(object), props_getters_metakey)
		if props == nil then return end

		local fn = props[k]
		if fn ~= nil then
			return fn(object, k, props)
		end
	end

	local function property_newindex(object, k, v)
		local props = rawget(getmetatable(object), props_setters_metakey)
		if props == nil then return end

		local fn = props[k]
		if fn ~= nil then
			fn(object, k, v, props)
			return true
		end
	end

	function AddPropertyTo(object, k, getter, setter)
		local meta = require_metatable(object)
		if getter ~= nil then
			local getters = rawget(meta, props_getters_metakey)
			if not getters then
				getters = {}
				rawset(meta, props_getters_metakey, getters)
				AttachMetaIndexTo(object, property_index)
			end
			getters[k] = getter
		end
		if setter ~= nil then
			local setters = rawget(meta, props_setters_metakey)
			if not setters then
				setters = {}
				rawset(meta, props_setters_metakey, setters)
				AttachMetaNewIndexTo(object, property_newindex)
			end
			setters[k] = setter
		end
	end
	local AddPropertyTo = AddPropertyTo

	function AddLazyVariableTo(object, k, fn)
		local function getter(object, k, props)
			local v = fn(k, object)
			if v ~= nil then
				props[k] = nil
				rawset(object, k, v)
			end
			return v
		end

		return AddPropertyTo(object, k, getter)
	end
	local AddLazyVariableTo = AddLazyVariableTo

	---
	
	return METATABLELIB_ENV()
end

---

local function include_auxlib(kernel)
	local get = NewGetter(kernel)

	local _G = get._G

	local assert, error = get.assert, get.error
	local VarExists = get.VarExists

	local type = get.type
	local rawget, rawset = get.rawget, get.rawset

	local getmetatable, setmetatable = get.getmetatable, get.setmetatable
	local table, math = get.table, get.math

	local pairs, ipairs = get.pairs, get.ipairs
	local next = get.next

	---

	local AUXLIB_ENV = make_inner_env(kernel)

	---
	
	GetTick = get.opt("GetTick", Zero)
	GetTime = get.opt("GetTime", get.os.clock or Zero)
	GetTimeReal = get.opt("GetTimeReal", GetTime)
	FRAMES = get.opt("FRAMES", 1/60)

	if VarExists "FRAMES" then
		FRAMES = _G.FRAMES
	else
		FRAMES = 1/60
	end

	if VarExists "TheSim" then
		GetTickTime = memoize_0ary(function()
			return _G.TheSim:GetTickTime()
		end)
	else
		GetTickTime = function()
			return 1/30
		end
	end
	local GetTickTime = GetTickTime

	GetTicksPerSecond = memoize_0ary(function()
		return 1/GetTickTime()
	end)
	local GetTicksPerSecond = GetTicksPerSecond

	GetTicksForInterval = (function()
		local floor = math.floor
		return function(dt)
			return floor(dt*GetTicksPerSecond())
		end
	end)()
	GetTicksInInterval = GetTicksForInterval

	GetTicksCoveringInterval = (function()
		local ceil = math.ceil
		return function(dt)
			return ceil(dt*GetTicksPerSecond())
		end
	end)()

	do
		local next = assert( _G.next )
		local type = assert( _G.type )
		local sbyte = assert( _G.string.byte )
		local sfind = assert( _G.string.find )
		local us = sbyte("_", 1)

		function IsPrivateString(x)
			return type(x) == "string" and sbyte(x, 1) == us
		end
		local IsPrivateString = IsPrivateString

		function IsNotPrivateString(x)
			return type(x) ~= "string" or sbyte(x, 1) ~= us
		end
		local IsNotPrivateString = IsNotPrivateString

		function IsPublicString(x)
			return type(x) == "string" and sbyte(x, 1) ~= us
		end
		local IsPublicString = IsPublicString

		local function new_conditional_iterate(p)
			return function(f, s, var)
				local function g(fs, k)
					local v = nil
					repeat
						k, v = f(fs, k)
					until k == nil or p(k, v)
					return k, v
				end

				return g, s, var
			end
		end
		NewConditionalIterate = new_conditional_iterate

		public_iterate = new_conditional_iterate(IsPublicString)
		private_iterate = new_conditional_iterate(IsPrivateString)
		nonprivate_iterate = new_conditional_iterate(IsNotPrivateString)

		local function is_string_matching(patt)
			assert(type(patt) == "string")
			return function(k)
				return type(k) == "string" and sfind(k, patt)
			end
		end

		matched_iterate = compose(new_conditional_iterate, is_string_matching)
	end

	local public_iterate, private_iterate = public_iterate, private_iterate
	local nonprivate_iterate = nonprivate_iterate
	publicly_iterate = public_iterate
	privately_iterate = private_iterate
	nonprivately_iterate = nonprivately_iterate

	public_pairs = lazy_compose(public_iterate, "pairs")
	publicpairs = public_pairs

	private_pairs = lazy_compose(private_iterate, "pairs")
	privatepairs = private_pairs

	nonprivate_pairs = lazy_compose(nonprivate_iterate, "pairs")
	nonprivatepairs = nonprivate_pairs

	matched_pairs = function(patt)
		local do_iterate = matched_iterate(patt)
		return function(t)
			return do_iterate(pairs(t))
		end
	end
	matchedpairs = matched_pairs
	
	function InjectNonPrivatesIntoTableIf(p, t, f, s, var)
		for k, v in nonprivate_iterate(f, s, var) do
			if p(k, v) then
				t[k] = v
			end
		end
		return t
	end
	local InjectNonPrivatesIntoTableIf = InjectNonPrivatesIntoTableIf
	
	function InjectNonPrivatesIntoTable(t, f, s, var)
		t = InjectNonPrivatesIntoTableIf(True, t, f, s, var)
		return t
	end

	---
	
	_M.rawget = _G.debug.getmetatable
	_M.rawset = _G.debug.setmetatable
	
	_M.get = _G.getmetatable
	_M.set = _G.setmetatable
	_M.require = require_metatable

	---
	
	return AUXLIB_ENV()
end

----------

return function()
	local kernel = _M
	local _G = kernel._G

	---
	
	PLATFORM_DETECTION = {}
	INTROSPECTION_LIB = {}

	tee(kernel, PLATFORM_DETECTION)
	tee(kernel, INTROSPECTION_LIB)

	---

	include_corelib(kernel)

	include_platform_detection_functions(kernel)

	include_constants(kernel)
	clear_tee(kernel, PLATFORM_DETECTION)

	include_introspectionlib(kernel)
	clear_tee(kernel, INTROSPECTION_LIB)

	_M.metatable = include_metatablelib(kernel)

	include_auxlib(kernel)

	---

	assert( IsDST )
end
