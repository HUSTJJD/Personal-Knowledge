```Lua
local recursionsetmetatable
recursionsetmetatable = function(t, index)
    local mt = getmetatable(t)
    if not mt then mt = {} end
    if not mt.__index then
        mt.__index = index
        setmetatable(t, mt)
    elseif mt.__index ~= index then
        recursionsetmetatable(mt, index)
    end
end

local function Class(clsName, ...)
    local cls = { __type = clsName }
    local supers = { ... }
    for _, super in ipairs(supers) do
        local superType = type(super)
        if superType == 'function' then
            cls.__create = super
        elseif superType == 'table' then
            cls.__supers = cls.__supers or {}
            cls.__supers[#cls.__supers + 1] = super
        end
    end
    cls.__index = cls
    if cls.__supers then
        setmetatable(cls, {
            __index = function(_, key)
                for i, super in ipairs(cls.__supers) do
                    if super[key] then return super[key] end
                end
            end
        })
    end
    -- 必然是成员函数
    cls.CallSuper = function(self, funcName, ...)
        local stack = { self }
        local pc = 1
        while pc > 0 do
            local from = #stack - pc + 1
            pc = 0
            for i = from, #stack do
                local super = stack[i]
                if super.__supers then
                    for _, grandSuper in ipairs(super.__supers) do
                        pc = pc + 1
                        table.insert(stack, grandSuper)
                    end
                end
            end
        end
        for i = #stack, 2, -1 do
            local superFunc = stack[i][funcName]
            if type(superFunc) == 'function' then
                superFunc(self, ...)
            end
        end
    end
    if not cls.Construct then
        cls.Construct = function() end
    end
    cls.New = function(...)
        local instance = cls.__create and cls.__create(...) or {}
        recursionsetmetatable(instance, cls)
        if cls.__supers then
            instance:CallSuper('Construct', ...)
            instance:Construct(...)
        else
            instance:Construct(...)
        end
        return instance
    end
    return cls
end

local function IsA(self, cls)
    return self.__type == cls.__type
end

_G.Class = Class
_G.IsA = IsA

-- Test Code
local clsA = _G.Class('a')
function clsA:Construct()
    self.name = 'clsA'
    self.sec_name = 'clsA'
end

function clsA:Print()
    print('sec_name', self.sec_name)
    print('name', self.name)
end

local clsB = _G.Class('b', clsA)
function clsB:Construct()
    self.name = 'clsB'
end

function clsB:Print(...)
    self:CallSuper('Print', ...)
end

local clsC = _G.Class('c', clsA, clsB)
function clsC:Construct()
    self.name = 'clsC'
end

function clsC:Print(...)
    self:CallSuper('Print', ...)
end

local objA = clsA.New()
local objB = clsB.New()
local objC = clsC.New()
objA:Print()
objB:Print()
objC:Print()
print(_G.IsA(objA, clsA))
print(_G.IsA(objA, clsB))
print(_G.IsA(objA, clsC))

```
