local Utils = require "utils"
local vim = require "vim"

local PORT_RADIUS = 10
local KNOB_RADIUS = 8
local BUTTON_RADIUS = 9

local CELL_WIDTH = 35
local CELL_HEIGHT = 40
local GRID_WIDTH = 0 -- filled in in load
local GRID_HEIGHT = 0 -- filled in in load
local GRID = {}

local module_types = {}
local modules = {}
local ports = {}
local knobs = {}
local buttons = {}
local edges = {}
local cells = {}

local grab_mode = false

local _click_id = 0

local clicking_port = nil
local removing = false
-- other ports that I'm connected to
local holding_connections = {}

-- Initialized in love.load
local screen = nil
local NORM_FACTOR = 600
local SLACK = 30

local fullscreen = false
local playing = true

local function types_match(t1, t2)
    return t1 == t2 or t1 == '*' or t2 == '*'
end

local function Cell(default)
    local output = setmetatable({
        default=default
    }, {
        __index = function(self, key)
            if rawget(self, 'default') then
                return self.default
            else
                return nil
            end
        end
    })
    table.insert(cells, output)
    return output
end

local function get_looped(a, k)
    if #a > 0 then
        return a[(k - 1) % #a + 1]
    else
        return nil
    end
end

local function norm_point(x, y)
    return (x - NORM_FACTOR / 2) / NORM_FACTOR, (y - NORM_FACTOR / 2) / NORM_FACTOR
end

local function denorm_point(x, y)
    return x * NORM_FACTOR + NORM_FACTOR / 2, y * NORM_FACTOR + NORM_FACTOR / 2
end

local function module_dimensions(module)
    local x = module.x * CELL_WIDTH
    local y = module.y * CELL_HEIGHT
    local w = (#module.layout[1] + 1) * CELL_WIDTH
    local h = (#module.layout + 1) * CELL_HEIGHT
    return x, y, w, h
end

local function part_screen_position(module, part)
    return (module.x + part.x + 1) * CELL_WIDTH, (module.y + part.y + 1) * CELL_HEIGHT
end

local function part_keys_equal(pk1, pk2)
    return pk1[1] == pk2[1] and pk1[2] == pk2[2]
end

local function get_part(part_id)
    if part_id then
        local module = modules[part_id[1]]
        return module.parts[part_id[2]]
    end
    return nil
end

local function reify_pid(part_id)
    local module = modules[part_id[1]]
    local part = module.parts[part_id[2]]
    return module, part
end

-- iterator that returns all the keys in the given collections
-- TODO: Optimize this into a proper iterator
local function all_keys(...)
    local keys = {}
    for i, collection in pairs({...}) do
        for key, _ in pairs(collection) do
            keys[key] = true
        end
        if collection.default then
            keys.default = true
        end
    end
    return pairs(keys)
end

local CLICKS = Cell()

local function get_cells(...)
    local output = {}
    for k, v in pairs({...}) do
        output[k] = v.cell
    end
    return unpack(output)
end

local function vmag(v)
    return math.sqrt(v.x * v.x + v.y * v.y)
end

local function module_part(part, x, y)
    local name, part_type = part[1], part[2]
    local output = {x=x, y=y, name=name, part_type=part_type}
    if part_type == 'port' then
        output.type = part[3]
        output.output = part[4] == 'out'
        output.own_cell = Cell()
        output.cell = output.own_cell
        table.insert(ports, output)
    end

    if part_type == 'knob' then
        output.value = part.default or .5
        table.insert(knobs, output)
    end

    if part_type == 'button' then
        output.value = part.default or false
        table.insert(buttons, output)
    end

    return output
end

local gmx = 0
local gmy = 0

local function can_place_module_at(x, y, width, height)
    for w=0,width-1 do
        for h=0,height-1 do
            if x+w > GRID_WIDTH-1 or y+h > GRID_HEIGHT-1 or GRID[x+w][y+h] then
                return false
            end
        end
    end
    return true
end

local function find_module_place(width, height)
    for y=0,GRID_HEIGHT-1 do
        for x=0,GRID_WIDTH-1 do
            if can_place_module_at(x, y, width, height) then
                return x, y
            end
        end
    end
    return nil
end

local function place_module(module, x, y)
    module.x = x
    module.y = y
    for w=0,#module.layout[1] do
        for h=0,#module.layout do
            GRID[x+w][y+h] = true
        end
    end
end

local function uproot_module(module)
    local x, y = module.x, module.y
    for w=0,#module.layout[1] do
        for h=0,#module.layout do
            GRID[x+w][y+h] = false
        end
    end
end

local function module_cell_dimensions(module)
    return #module.layout[1] + 1, #module.layout + 1
end


local function rack(name)
    if not module_types[name] then
        error("No such module: " .. name)
    end
    local t = module_types[name]

    local template = {}
    -- Clone the template
    for k, v in pairs(t) do
        template[k] = t[k]
    end

    local mw, mh = #template.layout[1] + 1, #template.layout + 1
    local mx, my = find_module_place(mw, mh)

    template.target = {}
    place_module(template, mx, my)
    
    local new_parts = {}
    local yoffset = my
    for ly=1,#template.layout do
        local row = template.layout[ly]
        for lx=1,#row do
            local key = row[lx]
            local part = template.parts[key]
            if part then
                new_parts[key] = module_part(part, lx-1, ly-1)
            elseif key ~= '' then
                error("Unknown part in layout: " .. key)
            end
        end
    end

    for k in pairs(template.parts) do
        if not new_parts[k] then
            error(string.format("Part %s is not included in the layout", k))
        end
    end

    template.parts = new_parts
    table.insert(modules, template)
    template.id = #modules
end

local function module(template)
    module_types[template.name] = template
end

local function visit_module(module, method, ...)
    if module[method] then
        local target = module.target
        target.id = module.id
        for key, v in pairs(module.parts) do
            if v.part_type == 'port' then
                target[key] = v.cell
            end

            if v.part_type == 'knob' then
                target[key] = v.value
            end

            if v.part_type == 'button' then
                target[key] = v.value
            end
        end

        module[method](target, ...)
    end
end

module {
    name = 'circles',
    parts = {
        points = {'V', 'port', 'vector'},
        radii = {'R', 'port', 'number'},
        color = {'C', 'port', 'color', 'in'},
        radius_knob = {'R', 'knob'},
        fill_mode = {'fill', 'button', default=false},
    },
    layout = {
        {'points', 'radii', 'color'},
        {'fill_mode', 'radius_knob', ''}
    },
    draw = function(self)
        for k, v in pairs(self.points) do
            local c = self.color[k] or {1, 1, 1, 1}
            local r = (self.radii[k] or 1) * self.radius_knob * 100
            local nx, ny = denorm_point(v.x, v.y)
            love.graphics.setColor(unpack(c))
            local mode = 'line'
            if self.fill_mode then
                mode = 'fill'
            end
            love.graphics.circle(mode, nx, ny, r)
            love.graphics.setColor(1, 1, 1, 1)
        end
    end
}

local mclicks = Cell()
module {
    name = 'mouse',
    parts = {
        clicks = {'CLK', 'port', 'vector', 'out'},
        position = {'POS', 'port', 'vector', 'out'}
    },
    layout = {
        {'clicks', 'position'}
    },
    restart = function(self)
        for k, v in pairs(mclicks) do
            mclicks[k] = nil
        end
    end,
    update = function(self, dt)
        for k, v in pairs(self.clicks) do
            if not mclicks[k] then
                self.clicks[k] = nil
            end
        end

        for k, v in pairs(mclicks) do
            self.clicks[k] = v
        end

        self.position.default = self.position.default or {}
        local mx, my = love.mouse.getPosition()
        if not fullscreen then
            local sw, sh = love.graphics.getDimensions()
            mx = (mx - (2 * sw / 3)) * 3
            my = (my - (2 * sh / 3)) * 3
        end
        local nx, ny = norm_point(mx, my)
        self.position.default.x = nx
        self.position.default.y = ny
    end
}

local function touch_radius(r, rk)
    return r or 1 * .1 * rk
end

module {
    name = 'touch',
    parts = {
        a_positions = {'A', 'port', 'vector', 'in'},
        a_radii = {'Ar', 'port', 'number', 'in'},
        a_radii_knob = {'Ar*', 'knob', 'number'},
        b_positions = {'B', 'port', 'vector', 'in'},
        b_radii = {'Br', 'port', 'number', 'in'},
        b_radii_knob = {'Br*', 'knob', 'number'},
        touches = {'T', 'port', 'number', 'out'},
        gooshiness = {'Goosh', 'knob', default=0},
        debug_switch = {'DBG', 'button', default=true},
    },
    layout = {
        {'a_positions', 'b_positions', 'a_radii', 'b_radii'},
        {'gooshiness', '', 'a_radii_knob', 'b_radii_knob'},
        {'touches', '', '', 'debug_switch'},
    },
    update = function(self, dt)
        local a = self.a_positions
        local b = self.b_positions
        local touch = self.touches
        local aradius = self.a_radii
        local bradius = self.b_radii
        local arknob = self.a_radii_knob
        local brknob = self.b_radii_knob

        for k, _ in pairs(touch) do
            if not a[k] and not b[k] then
                touch[k] = nil
            else
                touch[k] = 0
            end
        end

        touch.default = 0

        for k in pairs(a) do
            for j in pairs(b) do
                if a[k] ~= b[j] then
                    local ar = touch_radius(aradius[k], arknob)
                    local br = touch_radius(bradius[k], brknob)

                    local av = a[k]
                    local bv = b[j]

                    local dx, dy = av.x - bv.x, av.y - bv.y
                    local d = math.sqrt(dx * dx + dy * dy)
                    if d < (ar + br) then
                        local f = d / (ar + br)
                        if self.gooshiness == 0 then
                            touch[k] = 1
                            touch[j] = 1
                        else
                            local g = 2 + ((1 - self.gooshiness) * 100)
                            local v = (2.0 / (1.0 + math.exp(-g * (1 - f)))) - 1
                            local tk = rawget(touch, k) or 0
                            local tj = rawget(touch, j) or 0
                            touch[k] = math.max(tk, v)
                            touch[j] = math.max(tj, v)
                        end
                    else
                        local tk = rawget(touch, k) or 0
                        local tj = rawget(touch, j) or 0
                        touch[k] = math.max(tk, 0)
                        touch[j] = math.max(tj, 0)
                    end
                end
            end
        end
    end,
    draw = function(self)
        if self.debug_switch then
            for k, v in pairs(self.a_positions) do
                local x, y = denorm_point(v.x, v.y)
                local r = touch_radius(self.a_radii[k], self.a_radii_knob)
                local t = self.touches[k]
                love.graphics.setColor(1, 1-t, 1-t, 1)
                love.graphics.circle('line', x, y, r * NORM_FACTOR)
            end
            for k, v in pairs(self.b_positions) do
                local x, y = denorm_point(v.x, v.y)
                local r = touch_radius(self.b_radii[k], self.b_radii_knob)
                local t = self.touches[k]
                love.graphics.setColor(1, 1-t, 1-t, 1)
                love.graphics.circle('line', x, y, r * NORM_FACTOR)
            end
            love.graphics.setColor(1, 1, 1, 1)
        end
    end
}

module {
    name = 'grid',
    parts = {
        resolution = {'Res', 'port', 'number', 'in'},
        res_knob = {'', 'knob', 'number'},
        points = {'Out', 'port', 'vector', 'out'},
    },
    layout = {
        {'resolution', ''},
        {'res_knob', 'points'}
    },
    update = function(self, dt)
        local res = ((self.resolution.default or .5) + 1) * .5
        res = res * self.res_knob
        local rx = math.floor(20 * res)
        local ry = math.floor(20 * res)
        local seen = {}
        for x=0,rx do
            for y = 0,ry do
                local fx = (x / rx) * 2 - 1
                local fy = (y / ry) * 2 - 1
                local key = 'grid_' .. self.id .. '_' .. (x * rx + y)
                local p = self.points[key] or {}
                p.x = fx
                p.y = fy
                self.points[key] = p
                seen[key] = true
            end
        end
        for key, value in pairs(self.points) do
            if not seen[key] then
                self.points[key] = nil
            end
        end
    end
}

module {
    name = 'guys',
    parts = {
        positions = {'V', 'port', 'vector', 'in'},
        targets = {'Targ', 'port', 'vector', 'in'},
        speed = {'Spd', 'port', 'number', 'in'},
        speed_knob = {'', 'knob', 'number'},
        min_knob = {'MIN', 'knob', 'number', default=0},
        max_knob = {'MAX', 'knob', 'number', default=1},
        positions_out = {'Vout', 'port', 'vector', 'out'},
        distance_out = {'D', 'port', 'number', 'out'},
        respawn = {'Respawn', 'port', 'number', 'in'},
        debug = {'DBG', 'button', default=false}
    },
    layout = {
        {'positions', 'targets', 'speed', 'speed_knob'},
        {'min_knob', 'max_knob', '', 'respawn'},
        {'debug', '', 'positions_out', 'distance_out'}
    },
    start = function(self)
        self.offsets = Cell()
    end,
    update = function(self, dt)
        for k, v in pairs(self.positions_out) do
            if not self.positions[k] then
                self.positions_out[k] = nil
                self.offsets[k] = nil
                self.distance_out[k] = nil
            end
        end

        for k, v in pairs(self.positions) do
            if self.respawn[k] and self.respawn[k] > .8 then
                self.offsets[k] = {x=0, y=0}
            end

            local speed = (self.speed[k] or 1) * self.speed_knob
            self.offsets[k] = self.offsets[k] or {x=0, y=0}
            local offset = self.offsets[k]

            local guyx = v.x + offset.x
            local guyy = v.y + offset.y
            local target = self.targets[k] or {x=guyx, y=guyy}

            local dx = target.x - guyx
            local dy = target.y - guyy
            local d = math.sqrt(dx * dx + dy * dy)
            local min = self.min_knob
            local max = self.max_knob
            if self.max_knob == 1 then
                max = 100000
            end

            if d < max and d > min then
                offset.x = offset.x + dx * speed * dt
                offset.y = offset.y + dy * speed * dt
            end
            self.distance_out[k] = d
            
            self.positions_out[k] = self.positions_out[k] or {x=0, y=0}
            local pout = self.positions_out[k]
            pout.x = v.x + offset.x
            pout.y = v.y + offset.y
        end
    end,
    draw = function(self)
        if self.debug then
            for k, v in pairs(self.positions) do
                local offset = self.offsets[k] or {x=0, y=0}
                local px, py = denorm_point(v.x + offset.x, v.y + offset.y)
                love.graphics.print(k, px, py + 10)
                love.graphics.circle('line', px, py, 10)
            end
        end
    end
}

module {
    name = 'death',
    parts = {
        members = {'Input', 'port', '*', 'in'},
        living = {'Living', 'port', '*', 'out'},
        die = {'Die', 'port', 'number', 'in'},
    },
    layout = {
        {'members'},
        {'die'},
        {'living'},
    },
    start = function(self)
        self._deaths = {}
    end,
    restart = function(self)
        self._deaths = {}
    end,
    update = function(self, dt)
        for k, v in pairs(self.living) do
            if not self.members[k] then
                self.living[k] = nil
                self._deaths[k] = nil
            end
        end

        for k, v in pairs(self.members) do
            if self.die[k] and self.die[k] > .8 then
                self._deaths[k] = true
                self.living[k] = nil
            end

            if not self._deaths[k] then
                self._deaths[k] = false
                self.living[k] = v
            end
        end
    end
}

-- output = a in + c
module {
    name = 'math',
    parts = {
        a = {'A', 'port', 'number', 'in'},
        b = {'B', 'port', 'number', 'in'},
        c = {'C', 'port', 'number', 'in'},
        cknob = {'C', 'knob', 'number'},
        out = {'a+bc', 'port', 'number', 'out'},
        invert_a = {'1-a', 'port', 'number', 'out'},
    },
    layout = {
        {'a', 'b', 'c'},
        {'', '', 'cknob'},
        {'out', '', 'invert_a'},
    },
    update = function(self, dt)
        for key in pairs(self.out) do
            if not self.a[key] and not self.b[key] and not self.c[key] then
                self.out[key] = nil
            end
        end

        for key in pairs(self.invert_a) do
            if not self.a[key] then
                self.invert_a[key] = nil
            end
        end

        for key in all_keys(self.a, self.b, self.c) do
            local a = self.a[key] or 0
            local b = self.b[key] or 1
            local c = self.c[key] or 1
            local cknob = (self.cknob - .5) * 2
            c = c * cknob
            self.out[key] = a * b + c
        end

        for key, value in pairs(self.a) do
            self.invert_a[key] = 1 - value
        end
    end
}

module {
    name = 'color',
    parts = {
        hue_target_knob = {'HT', 'knob'},
        saturation_target_knob = {'ST', 'knob'},
        value_target_knob = {'VT', 'knob'},
        hue = {'H', 'port', 'number', 'in'},
        saturation = {'S', 'port', 'number', 'in'},
        value = {'V', 'port', 'number', 'in'},
        hue_knob = {'H*', 'knob'},
        saturation_knob = {'S*', 'knob'},
        value_knob = {'V*', 'knob'},
        output = {'Out', 'port', 'color', 'out'},
    },
    layout = {
        {'hue_target_knob', 'saturation_target_knob', 'value_target_knob'},
        {'hue', 'saturation', 'value'},
        {'hue_knob', 'saturation_knob', 'value_knob'},
        {'', '', 'output'},
    },
    update = function(self)
        local function f(key)
            local ht = self.hue_target_knob or 1
            local st = self.saturation_target_knob or 1
            local vt = self.value_target_knob or 1
            local h = self.hue[key] or 1
            local s = self.saturation[key] or 1
            local v = self.value[key] or 1
            h = h * self.hue_knob
            s = s * self.saturation_knob
            v = v * self.value_knob
            local hout = (ht * (1 - self.hue_knob)) + (h * self.hue_knob)
            local sout = (st * (1 - self.saturation_knob)) + (s * self.saturation_knob)
            local vout = (vt * (1 - self.value_knob)) + (v * self.value_knob)
            self.output[key] = {Utils.hsv(hout, sout, vout)}
        end
        for key in all_keys(self.hue, self.saturation, self.value) do
            f(key)
        end
        f('default')
    end
}

module {
    name = 'simplex',
    parts = {
        roughness = {'Rough', 'knob'},
        vectors = {'V', 'port', 'vector', 'in'},
        drift = {'Drift', 'knob', 'number'},
        output = {'Out', 'port', 'number', 'out'},
    },
    layout = {
        {'vectors', ''},
        {'drift', 'roughness'},
        {'', 'output'}
    },
    update = function(self, dt)
        local rough = self.roughness * 10
        self._drift = self._drift or 0
        self._drift = self._drift + dt * self.drift
        for key, value in pairs(self.vectors) do
            self.output[key] = love.math.noise(value.x * rough, value.y * rough, self._drift)
        end
        self.output.default = love.math.noise(self._drift * rough)
    end
}

module {
    name = 'lfo',
    parts = {
        ids = {'Id', 'port', '*', 'in'},
        sin = {'Sin', 'button'},
        freq = {'F', 'knob', 'number'},
        out = {'Out', 'port', 'number', 'out'}
    },
    layout = {
        {'ids', 'freq'},
        {'sin', 'out'},
    },
    restart = function(self)
        self._offsets = {}
    end,
    update = function(self, dt)
        self._offsets = self._offsets or {}

        for key in pairs(self.out) do
            if key ~= 'default' and not self.ids[key] then
                self._offsets[key] = nil
                self.out[key] = nil
            end
        end

        local function f(key)
            local offset = self._offsets[key] or 0
            local freq = self.freq
            self._offsets[key] = offset + dt * freq
            offset = self._offsets[key]
            if self.sin then
                self.out[key] = 1 + math.sin(offset * math.pi) / 2
            else
                self.out[key] = offset % 1
            end
        end
        for key in pairs(self.ids) do
            f(key)
        end
        if not self.ids.default then
            f('default')
        end
    end
}

local function point_in(point, p2, r)
    local dx = point.x - p2.x
    local dy = point.y - p2.y
    return dx * dx + dy * dy < r * r
end


local function draw_port(module, port_name)
    local port = module.parts[port_name]
    local px, py = part_screen_position(module, port)
    local mode = 'line'
    local mx, my = love.mouse.getPosition()
    if point_in({x=mx, y=my}, {x=px, y=py}, PORT_RADIUS) then
        mode = 'fill'
    end
    if port.name then
        local width = love.graphics.getFont():getWidth(port.name)
        love.graphics.print(port.name, math.floor(px - width / 2), py + 10)
    end
    local colors = {
        vector = {1, 1, 1, 1},
        number = {1, .8, .8, 1},
        color = {.8, 1, .8, 1},
    }
    local color = colors[port.type or ''] or {1, 1, 1, .8}
    if clicking_port then
        local clicking = get_part(clicking_port)
        if clicking.output == port.output or not types_match(clicking.type, port.type) then
            color[4] = .3
        end
    end
    love.graphics.setColor(color)
    love.graphics.circle(mode, px, py, PORT_RADIUS)
    love.graphics.circle(mode, px, py, PORT_RADIUS / 2)
    if port.output then
        local fx, fy = math.floor(px), math.floor(py)
        love.graphics.rectangle('line', fx - PORT_RADIUS, fy-PORT_RADIUS, PORT_RADIUS*2, PORT_RADIUS*2)
    end
    love.graphics.setColor(1, 1, 1, 1)
end

local function draw_knob(module, key)
    local knob = module.parts[key]
    local kx, ky = part_screen_position(module, knob)
    if knob.name then
        local width = love.graphics.getFont():getWidth(knob.name)
        love.graphics.print(knob.name, math.floor(kx - width / 2), ky + 10)
    end

    local knob_mode = 'line'
    local mx, my = love.mouse.getPosition()
    local hovering = point_in({x=mx, y=my}, {x=kx, y=ky}, KNOB_RADIUS)
    fill_mode = hovering and 'fill' or 'line'
    love.graphics.circle(fill_mode, kx, ky, KNOB_RADIUS)
    local t = math.pi / 2 + knob.value * math.pi * 2
    local ox, oy = math.cos(t) * KNOB_RADIUS, math.sin(t) * KNOB_RADIUS
    if fill_mode == 'fill' then
        love.graphics.setColor(0, 0, 0, 1)
    end
    love.graphics.line(kx, ky, kx + ox, ky + oy) 
    love.graphics.setColor(1, 1, 1, 1)
end

local function draw_button(module, key)
    local button = module.parts[key]
    local bx, by = part_screen_position(module, button)

    if button.name then
        local width = love.graphics.getFont():getWidth(button.name)
        love.graphics.print(button.name, math.floor(bx - width / 2), by + 10)
    end

    local mode = 'line'
    if button.value then
        mode = 'fill'
    end
    love.graphics.circle(mode, bx, by, BUTTON_RADIUS)
end

local function draw_connections()
    for i=1,#edges do
        local conn = edges[i]
        local m1, p1 = reify_pid(conn[1])
        local m2, p2 = reify_pid(conn[2])
        local p1x, p1y = part_screen_position(m1, p1)
        local p2x, p2y = part_screen_position(m2, p2)
        local d = math.sqrt(math.pow(p1x - p2x, 2) + math.pow(p1y - p2y, 2))
        love.graphics.setColor(Utils.hsv(d / 800, 1, 1))
        love.graphics.line(conn.curve:render(3))
    end
    love.graphics.setColor(1, 1, 1, 1)
end

local function get_connection_id(pid1, pid2)
    for i=1,#edges do
        local e = edges[i]
        if (part_keys_equal(e[1], pid1) and part_keys_equal(e[2], pid2)) or 
           (part_keys_equal(e[1], pid2) and part_keys_equal(e[2], pid1)) then
            return i
        end
    end
end

local function disconnect(pid1, pid2)
    local cid = get_connection_id(pid1, pid2)
    if cid then
        table.remove(edges, cid)
    end
end

local function disconnect_all(pid)
    local to_remove = {}
    for i=1,#edges do
        local e = edges[i]
        if part_keys_equal(e[1], pid) or part_keys_equal(e[2], pid) then
            table.insert(to_remove, i)
        end
    end

    for i=#to_remove,1,-1 do
        table.remove(edges, to_remove[i])
    end
end

local function update_bezier(connection)
    local m1, p1 = reify_pid(connection[1])
    local m2, p2 = reify_pid(connection[2])
    local p1x, p1y = part_screen_position(m1, p1)
    local p2x, p2y = part_screen_position(m2, p2)
    local mx, my = (p1x + p2x) / 2, (p1y + p2y) / 2
    my = my + SLACK
    local bezier = love.math.newBezierCurve(p1x, p1y, mx, my, p2x, p2y)
    connection.curve = bezier
end

local function connect(pid1, pid2)
    local cid = get_connection_id(pid1, pid2)
    if not cid then
        -- create a new connection
        local connection = {pid1, pid2}
        update_bezier(connection)

        table.insert(edges, connection)
    end
end

local function get_hovering_module_id()
    local mouse_x, mouse_y = love.mouse.getPosition()
    for key, module in pairs(modules) do
        local mx, my, mw, mh = module_dimensions(module)
        if Utils.point_in_rectangle(mouse_x, mouse_y, mx, my, mw, mh) then
            return key
        end
    end
end

local function get_hovering_module()
    local module_id = get_hovering_module_id()
    if module_id then
        return modules[module_id]
    end
end

-- return {mod_id, part_id}, part_type
local function get_hovering_part_id()
    local x, y = love.mouse.getPosition()
    local mp = {x=x, y=y}
    for module_id, module in pairs(modules) do
        local mx, my, mw, mh = module_dimensions(module)
        if Utils.point_in_rectangle(x, y, mx, my, mw, mh) then
            for key, part in pairs(module.parts) do
                local px, py = part_screen_position(module, part)
                local pp = {x=px, y=py}
                local radius = ({
                    knob=KNOB_RADIUS,
                    port=PORT_RADIUS,
                    button=BUTTON_RADIUS,
                })[part.part_type]
                if point_in(mp, pp, radius) then
                    return {module_id, key}, part.part_type
                end
            end
        end
    end
end

local function get_hovering_knob()
    local part_id, part_type = get_hovering_part_id()
    if part_type == 'knob' then
        return get_part(part_id)
    end
end

local function update_ports()
    for _, m in pairs(modules) do
        for key, part in pairs(m.parts) do
            if part.part_type == 'port' then
                part.cell = part.own_cell
            end
        end
    end

    for i=1,#edges do
        local edge = edges[i]
        local left = get_part(edge[1])
        local right = get_part(edge[2])
        local out_port = left.output and left or right
        local in_port = not left.output and left or right
        in_port.cell = out_port.cell
    end
end


local function setup_vim_binds()
    vim.init()
    vim.bind("normal", "a", function()
        vim.enter_textinput("Module name?", "", function(name)
            if module_types[name] then
                rack(name)
            else
                vim.show_message("No such module: " .. name)
            end
        end)
    end)
end

function love.load()
    setup_vim_binds()
    love.window.setMode(1024, 768)

    NORM_FACTOR, _ = love.graphics.getDimensions()
    local ww, wh = love.graphics.getDimensions()
    GRID_WIDTH = math.floor(ww / CELL_WIDTH)
    GRID_HEIGHT = math.floor(wh / CELL_HEIGHT)
    for x=0,GRID_WIDTH-1 do
        GRID[x] = {}
        for y=0,GRID_HEIGHT-1 do
            GRID[x][y] = false
        end
    end

    screen = love.graphics.newCanvas()

    -- Rack the modules we want
    rack('mouse')
    rack('grid')
    rack('guys')
    rack('death')
    rack('touch')
    rack('simplex')
    rack('color')
    rack('circles')
    rack('circles')
    rack('math')
    
    update_ports()
    for i=1,#modules do
        local module = modules[i]
        visit_module(module, 'start')
    end
end

function love.update(dt)
    if playing then
        for i=1,#modules do
            local module = modules[i]
            visit_module(module, 'update', dt)
        end
    end
end

function love.keypressed(key)
    if key == 'r' then
        for k, v in pairs(cells) do
            for k2 in pairs(v) do
                v[k2] = nil
            end
        end
        for _, module in pairs(modules) do
            visit_module(module, 'restart')
        end
    end

    if key == 'f' then
        fullscreen = not fullscreen
    end

    if key == 'space' then
        playing = not playing
    end

    if key == 'g' then
        grab_mode = not grab_mode
        if grab_mode then
            love.mouse.setCursor(love.mouse.getSystemCursor('hand'))
        else
            love.mouse.setCursor(love.mouse.getSystemCursor('arrow'))
            holding_module = nil
        end
    end
end

function love.draw(dt)
    if not fullscreen then
        for i=1,#modules do
            local module = modules[i]
            local mx, my, mw, mh = module_dimensions(module)
            love.graphics.print(module.name, mx + 5, my + 5)
            love.graphics.rectangle('line', mx, my, mw, mh)

            for key, value in pairs(module.parts) do
                if value.part_type == 'port' then
                    draw_port(module, key)
                elseif value.part_type == 'knob' then
                    draw_knob(module, key)
                elseif value.part_type == 'button' then
                    draw_button(module, key)
                end
            end
        end

        if holding_module then
            local mx, my = love.mouse.getPosition()
            local mcx, mcy = math.floor(mx / CELL_WIDTH), math.floor(my / CELL_HEIGHT)
            local mw, mh = module_cell_dimensions(holding_module)
            if can_place_module_at(mcx, mcy, mw, mh) then
                love.graphics.setColor(0, 1, 0, 1)
            else
                love.graphics.setColor(1, 0, 0, 1)
            end
            love.graphics.rectangle('fill', mcx * CELL_WIDTH, mcy * CELL_HEIGHT, mw * CELL_WIDTH, mh * CELL_HEIGHT)
        end

        draw_connections()

        if clicking_port then
            local mx, my = love.mouse.getPosition()
            for i=1,#holding_connections do
                local hcid = holding_connections[i]
                local module = modules[hcid[1]]
                local port = module.parts[hcid[2]]
                local px, py = part_screen_position(module, port)
                love.graphics.line(mx, my, px, py)
            end
        end

        local sw, sh = love.graphics.getDimensions()
        love.graphics.rectangle('line', sw - (sw / 3), sh - (sh / 3), sw / 3, sh / 3)
        love.graphics.draw(screen, sw - (sw / 3), sh - (sh / 3), 0, 1/3, 1/3)

        love.graphics.setCanvas(screen)
        love.graphics.clear()
    else -- fullscreen
        local sw, sh = love.graphics.getDimensions()
        love.graphics.rectangle('line', 0, 0, sw, sh)
    end

    for i=1,#modules do
        visit_module(modules[i], 'draw')
    end
    love.graphics.setCanvas(nil)

    local ww, wh = love.graphics.getDimensions()
    if playing then
        local TRI_SIZE = 10
        local lx = ww - TRI_SIZE
        local ly = TRI_SIZE
        local my = TRI_SIZE / 2
        love.graphics.polygon('fill', lx, 0, lx, ly, ww, my)
    else
        local font = love.graphics.getFont()
        local width = font:getWidth('||')
        love.graphics.print('||', ww - width, 0)
    end
end

function love.mousepressed(x, y, which)
    if grab_mode then
        local module = get_hovering_module()
        if module then
            holding_module = module
            uproot_module(module)
        end
    elseif which == 1 then
        clicking, clicking_type = get_hovering_part_id()

        if clicking_type == 'port' then
            -- immediatly disconnect
            clicking_port = clicking
            local port = get_part(clicking)
            holding_connections = {}
            for i=1,#edges do
                local edge = edges[i]
                if part_keys_equal(edge[1], clicking) then
                    table.insert(holding_connections, edge[2])
                end

                if part_keys_equal(edge[2], clicking) then
                    table.insert(holding_connections, edge[1])
                end
            end

            disconnect_all(clicking)
            update_ports()

            if #holding_connections == 0 then
                table.insert(holding_connections, clicking)
            else
                clicking_port = holding_connections[1]
            end
        elseif clicking_type == 'button' then
            local button = get_part(clicking)
            button.value = not button.value
        else
            local sw, sh = love.graphics.getDimensions()
            local mx, my = love.mouse.getPosition()
            if not fullscreen then
                mx = (mx - (2 * sw / 3)) * 3
                my = (my - (2 * sh / 3)) * 3
            end

            local x2, y2 = norm_point(mx, my)
            local key = 'click_' .. _click_id
            mclicks[key] = {x=x2, y=y2}
            _click_id = _click_id + 1
            mclicks.default = mclicks.default or {}
            mclicks.default.x = x2
            mclicks.default.y = y2
        end
    end
end

function love.mousereleased(x, y)
    if holding_module then
        local mcx, mcy = math.floor(x / CELL_WIDTH), math.floor(y / CELL_HEIGHT)
        local mw, mh = module_cell_dimensions(holding_module)
        if can_place_module_at(mcx, mcy, mw, mh) then
            place_module(holding_module, mcx, mcy)
            for _, edge in pairs(edges) do
                if edge[1][1] == holding_module.id or edge[2][1] == holding_module.id then
                    update_bezier(edge)
                end
            end
        end
        holding_module = nil
    else
        local hovering_pid = get_hovering_part_id()
        local hovering_part = get_part(hovering_pid)
        if hovering_part and hovering_part.part_type == 'port' and clicking_port then
            hovering_part = get_part(hovering_pid) or {}
            local clicking = get_part(clicking_port)
            local type1, type2 = hovering_part.type, clicking.type
            if types_match(type1, type2) and hovering_part.output ~= clicking.output then
                for i=1,#holding_connections do
                    connect(hovering_pid, holding_connections[i])
                end
                update_ports()
            end
        end
    end

    clicking_port = nil
end

function love.wheelmoved(x, y)
    local knob = get_hovering_knob()
    if knob then
        knob.value = math.min(math.max(knob.value + (y / 20), 0), 1)
    end
end
