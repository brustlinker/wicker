local assert = assert

local _K = assert( _K )

local _G = assert( _G )
local error = assert( error )

local coroutine = assert( coroutine )

---

local function dflt_boot_params(modenv)
    return {
        id = modenv.modinfo.id,

        modcode_root = "code",

        debug = true, 
    }
end

---

local COMMON_DSMODULES = {
    "constants",
    "instrospection",
    "platform_detection",
    "pseudo_packages",
}

---

local function apply_game_tweaks(modenv)
    local getmetatable = assert(getmetatable)
    local setmetatable = assert(setmetatable)

    require "vector3"

    -- This optimizes vector operations a bit since it prevents the
    -- reallocations of the vector's table hash part from sizes
    -- 0 -> 1 -> 2 -> 4
    local Vector3 = assert(_G.Vector3)

    local vec3_meta = shallow_copy(assert(getmetatable(Vector3)))
    vec3_meta.__call = function(RealVector3, x, y, z)
        return setmetatable({
            x = x or 0,
            y = y or 0,
            z = z or 0,
        }, RealVector3)
    end
    setmetatable(Vector3, vec3_meta)
end

---

local function check_pristine(boot_params)
    for k in pairs(boot_params) do
        assert(type(k) == "string")
        assert(not k:lower():find "mod")
    end
end

---

local function wrap_print(print)
    local tostring = assert(tostring)
    local table_concat = assert(table.concat)
    local select = assert(select)

    return function(...)
        local n = select("#", ...)
        if n == 0 then
            return print ""
        elseif n == 1 then
            return print(tostring(...))
        else
            local sargs = {...}
            for i = 1, n do
                sargs[i] = tostring(sargs[i])
            end
            return print(table_concat(sargs, "\t"))
        end
    end
end

---

return krequire("profile_d.common")(function(resume_kernel)
    local modenv, boot_params = coroutine.yield()

    assert(modenv, "Please provide the mod environment as the first argument to the dontstarve profile.")

    boot_params = weakMerge(boot_params or {}, dflt_boot_params(modenv))

    ---

    boot_params.usercode_root =
        boot_params.modcode_root or boot_params.usercode_root
    boot_params.modcode_root = nil

    check_pristine(boot_params)
    apply_game_tweaks(modenv)

    _K.Point = assert( _G.Point )
    _K.Vector3 = assert( _G.Vector3 )

    _K.env = modenv
    _K.modenv = modenv

    _K.print = wrap_print(rawget(_G, "nolineprint") or _G.print)
    _K.nolineprint = _K.print

    function _K.GetModDirectoryName()
        return modenv.modname
    end

    local TheUser = assert( resume_kernel(boot_params) )
    local dsmodprobe = NewModProber("dsmodules.", "Don't Starve kernel module")
    _K.dsmodprobe = dsmodprobe

    local TheMod = TheUser
    _K.TheMod = TheUser

    for _, module_name in ipairs(COMMON_DSMODULES) do
        dsmodprobe(module_name)
    end

    while true do
        embedEnvSomehow(modenv)
        assert( TheMod )
        modenv = coroutine.yield( TheMod )
    end
end)
