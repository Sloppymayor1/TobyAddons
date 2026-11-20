local MAJOR, MINOR = "ForeverDualGathering-CallbackHandler-1.0", 8
local CallbackHandler = LibStub:NewLibrary(MAJOR, MINOR)
if not CallbackHandler then return end

local function safecall(func, ...)
    if securecallfunction then
        return securecallfunction(func, ...)
    end
    local ok, err = pcall(func, ...)
    if not ok and geterrorhandler then
        geterrorhandler()(err)
    end
end

function CallbackHandler:New(target, RegisterName, UnregisterName, UnregisterAllName)
    target = target or {}
    RegisterName = RegisterName or "RegisterCallback"
    UnregisterName = UnregisterName or "UnregisterCallback"
    if UnregisterAllName == nil then UnregisterAllName = "UnregisterAllCallbacks" end

    local events = {}
    local registry = {}

    function registry:Fire(eventname, ...)
        local handlers = events[eventname]
        if not handlers then return end
        for _, func in pairs(handlers) do
            safecall(func, eventname, ...)
        end
    end

    target[RegisterName] = function(self, eventname, method, arg)
        if type(eventname) ~= "string" then
            error("Usage: RegisterCallback(eventname, method[, arg])", 2)
        end
        method = method or eventname
        local func
        if type(method) == "string" then
            if type(self) ~= "table" or type(self[method]) ~= "function" then
                error("Callback method not found: " .. tostring(method), 2)
            end
            if arg ~= nil then
                func = function(...) return self[method](self, arg, ...) end
            else
                func = function(...) return self[method](self, ...) end
            end
        elseif type(method) == "function" then
            if arg ~= nil then
                func = function(...) return method(arg, ...) end
            else
                func = function(...) return method(...) end
            end
        else
            error("Callback method must be a function or method name", 2)
        end
        events[eventname] = events[eventname] or {}
        events[eventname][self] = func
    end

    target[UnregisterName] = function(self, eventname)
        local handlers = events[eventname]
        if handlers then
            handlers[self] = nil
            if not next(handlers) then events[eventname] = nil end
        end
    end

    if UnregisterAllName then
        target[UnregisterAllName] = function(...)
            for i = 1, select("#", ...) do
                local owner = select(i, ...)
                for eventname, handlers in pairs(events) do
                    handlers[owner] = nil
                    if not next(handlers) then events[eventname] = nil end
                end
            end
        end
    end

    return registry
end
