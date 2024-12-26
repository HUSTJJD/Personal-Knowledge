# 源码

```Lua
local recursionsetmetatable
recursionsetmetatable = function(t, index)
    local mt = getmetatable(t)
    if not mt then mt = {} end
    if not mt.__index then
        mt.__index = index
        mt.__gc = function(self) self:Dtor() end
        setmetatable(t, mt)
    elseif mt.__index ~= index then
        recursionsetmetatable(mt, index)
    end
end

local function Class(clsName, ...)
    local cls = { __cname = clsName }
    local supers = { ... }
    -- super 可以是table 可以是function
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
    local mt = {
        __call = function(cls, ...) return cls.New(...) end,
        -- __gc = function(cls) end
    }
    if cls.__supers then
        mt.__index = function(_, key)
            for i, super in ipairs(cls.__supers) do
                if super[key] then return super[key] end
            end
        end
    end
    setmetatable(cls, mt)
    -- 必然是成员函数
    cls.CallSuper = function(self, funcName, ...)
        if cls.__supers then
            for _, super in ipairs(cls.__supers) do
                local superFunc = super[funcName]
                if type(superFunc) == 'function' then
                    superFunc(self, ...)
                end
            end
        end
    end
    if not cls.Ctor then
        cls.Ctor = function(self, ...) end
    end
    if not cls.Dtor then
        cls.Dtor = function(self, ...) end
    end
    cls.New = function(...)
        local self = cls.__create and cls.__create(...) or {}
        recursionsetmetatable(self, cls)
        self:Ctor(...)
        return self
    end
    return cls
end

local function IsA(self, cls)
    local recursionIsA
    recursionIsA = function(clsXX, clsB)
        if clsXX.__supers then
            for _, super in ipairs(clsXX.__supers) do
                if recursionIsA(super, clsB) or super.__cname == clsB.__cname then
                    return true
                end
            end
        end
    end
    return recursionIsA(self, cls) or self.__cname == cls.__cname
end

_G.Class = Class
_G.IsA = IsA
```

# 测试代码

```Lua
-- Test Code
local clsXX = _G.Class('clsXX')
function clsXX:Ctor(...)
    self.name = 'objXX'
    print(self.__cname, clsXX.__cname, 'Ctor', ...)
end

function clsXX:Print(...)
    print('clsXX Print', self.name, ...)
end

function clsXX:Dtor()
    print('Dtor', self.name, self.__cname, clsXX.__cname)
end

local clsYY = _G.Class('clsYY')
function clsYY:Ctor(...)
    self.name = 'objYY'
    print(self.__cname, clsYY.__cname, 'Ctor', ...)
end

function clsYY:Print(...)
    print('clsYY Print', self.name, ...)
end

function clsYY:Dtor()
    print('Dtor', self.name, self.__cname, clsYY.__cname)
end

local clsB = _G.Class('clsB', clsXX)
function clsB:Ctor(...)
    clsB.CallSuper(self, 'Ctor', ...)
    self.name = 'objB'
end

function clsB:Print(...)
    clsB.CallSuper(self, 'Print', ...)
end

function clsB:Dtor()
    clsB.CallSuper(self, 'Dtor')
end

local clsC = _G.Class('clsC', clsB, clsYY)
function clsC:Ctor(...)
    clsC.CallSuper(self, 'Ctor', ...)
    self.name = 'objC'
end

function clsC:Print(...)
    clsC.CallSuper(self, 'Print', ...)
end

function clsC:Dtor()
    clsC.CallSuper(self, 'Dtor')
end

local objXX = clsXX.New()
local objB = clsB(1)
local objC = clsC(1, 2, 3)
objXX:Print()
objB:Print()
objC:Print()
print('IsA(objB, clsB)', _G.IsA(objB, clsB))
print('IsA(objB, clsC)', _G.IsA(objB, clsC))
print('IsA(objC, clsXX)', _G.IsA(objC, clsXX))
print('IsA(objC, clsYY)', _G.IsA(objC, clsYY))
local clsFunc = _G.Class('clsFunc', function()
    return {}
end, clsB)
local objFunc = clsFunc()
```
