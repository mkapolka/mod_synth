require "love"

local T = love.timer.getTime()
local PORT_RADIUS = 10
local KNOB_RADIUS = 8

local modules = {}
local ports = {}
local knobs = {}
local edges = { }
local cells = {}

local function Cell(default)
    return setmetatable({
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
end

local function get_looped(a, k)
    if #a > 0 then
        return a[(k - 1) % #a + 1]
    else
        return nil
    end
end

local NORM_FACTOR = 600
local function norm_point(x, y)
    return (x - NORM_FACTOR / 2) / NORM_FACTOR, (y - NORM_FACTOR / 2) / NORM_FACTOR
end

local function denorm_point(x, y)
    return x * NORM_FACTOR + NORM_FACTOR / 2, y * NORM_FACTOR + NORM_FACTOR / 2
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

function pva(dt, initial_positions, position, velocity, acceleration, vk, ak)
    for k, _ in all_keys(initial_positions, position) do
        if not initial_positions[k] then
            position[k] = nil
        else
            position[k] = position[k] or initial_positions[k]
            local p = position[k]
            local v = velocity[k] or {x=0, y=0}
            local a = acceleration[k]
            if a then
                v.x = v.x + a.x * dt * ak
                v.y = v.y + a.y * dt * ak
                velocity[k] = v
            end

            p.x = p.x + v.x * dt * vk
            p.y = p.y + v.y * dt * vk
        end
    end
end

local function vmag(v)
    return math.sqrt(v.x * v.x + v.y * v.y)
end

function vector(from, to, delta, mult)
    for k, _ in all_keys(from, to) do
        local f = from[k] or {x=0, y=0}
        local t = to[k] or {x=0, y=0}
        local m = mult[k] or 1
        local dd = delta[k] or {x=0, y=0}
        dd.x = (f.x - t.x) * m
        dd.y = (f.y - t.y) * m
        delta[k] = dd
    end
end

-- TODO: mult is wrong
function vector_math(input, add, mult, output, mag)
    for k, v in pairs(input) do
        local a = add[k] or {x=0, y=0}
        local m = mult[k] or 1
        local out = output[k] or {x=0, y=0}
        out.x = (v.x + a.x) * m
        out.y = (v.y + a.y) * m
        output[k] = out
        mag[k] = math.sqrt(out.x * out.x + out.y * out.y)
    end
end

-- ca * a + cb * b
function math_node(ca, a, cb, b, output)
    return {
        update = function(dt)
            for k in all_keys(ca, a, cb, b) do
                local ca = ca[k] or 1
                local a = a[k] or 0
                local cb = cb[k] or 1
                local b = b[k] or 0
                output[k] = ca * a + cb * b
            end
        end
    }
end

function sin_wave(dt, thetas, freq, amplitude, offset, output, ids)
    output.default = output.default or 0
    for k in all_keys(freq, offset, output, ids) do
        local f = freq[k] or 1
        local o = offset[k] or 0
        --local t = thetas[k] or 0
        local t = rawget(thetas, k) or 0
        local amp = amplitude[k] or 1

        output[k] = math.sin(t - o) * amp

        if k == 'default' or ids[k] then
            thetas[k] = t + dt * math.pi * f
        else
            thetas[k] = nil
            output[k] = nil
        end

    end
end

function remove(from, trigger)
    for k in all_keys(from, trigger) do
        local t = trigger[k] or 0
        if t > .8 then
            from[k] = nil
        end
    end
end

local function combine(a, b, c, output)
    for k, v in pairs(a) do
        output[k] = v
    end

    for k, v in pairs(b) do
        output[k] = v
    end

    for k, v in pairs(c) do
        output[k] = v
    end
end

local next_module = 25

local function module(name, module_ports)
    local y = next_module
    local x = 10
    local created_ports = {}

    for _, port in pairs(module_ports) do
        local m = {x = x, y = y, type=port[2], name = port[1]}
        if port[3] then
            m.knob = .5
        end
        table.insert(created_ports, m)
        table.insert(ports, m)
        x = x + 30
    end

    table.insert(modules, {
        name = name
    })

    next_module = next_module + 55
    return unpack(created_ports)
end

local function module2_part(part, x, y)
    local name, part_type = part[1], part[2]
    local output = {x=x, y=y, name=name, part_type=part_type}
    if part_type == 'port' then
        output.type = part[3]
        table.insert(ports, output)
    end

    if part_type == 'knob' then
        output.value = .5
        table.insert(knobs, output)
    end
    return output
end

local my = 0
local function module2(template)
    template.target = {}
    template.x = 0
    template.y = my
    my = my + 30
    local new_parts = {}
    for ly=1,#template.layout do
        local row = template.layout[ly]
        for lx=1,#row do
            local key = row[lx]
            local part = template.parts[key]
            if part then
                new_parts[key] = module2_part(part, lx * 30, my)
            end
        end
        my = my + 40
    end

    for k in pairs(template.parts) do
        if not new_parts[k] then
            error(string.format("Part %s is not included in the layout", k))
        end
    end

    template.parts = new_parts
    table.insert(modules, template)
end

local function visit_module(module, method, ...)
    if module[method] then
        local target = module.target
        for key, v in pairs(module.parts) do
            if v.part_type == 'port' then
                target[key] = v.cell
            end

            if v.part_type == 'knob' then
                target[key] = v.value
            end
        end

        module[method](target, ...)
    end
end

function circle()
    module2 {
        name = 'circles',
        parts = {
            points = {'V', 'port', 'vector'},
            radii = {'R', 'port', 'number'},
            radius_knob = {'R', 'knob'},
        },
        layout = {
            {'points', 'radii'},
            {'', 'radius_knob'}
        },
        draw = function(self)
            for k, v in pairs(self.points) do
                local r = (self.radii[k] or 1) * self.radius_knob * 100
                local nx, ny = denorm_point(v.x, v.y)
                love.graphics.circle('fill', nx, ny, r)
            end
        end
    }
end
circle()
circle()

local mclicks = Cell()
module2 {
    name = 'mouse',
    parts = {
        clicks = {'CLK', 'port', 'vector'},
        position = {'POS', 'port', 'vector'}
    },
    layout = {
        {'clicks', 'position'}
    },
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
        local mx, my = norm_point(love.mouse.getPosition())
        self.position.default.x = mx
        self.position.default.y = my
    end
}

local function touch_radius(r, rk)
    return r or 1 * .1 * rk
end

module2 {
    name = 'touch',
    parts = {
        a_positions = {'A', 'port', 'vector'},
        a_radii = {'Ar', 'port', 'number'},
        a_radii_knob = {'Ar*', 'knob', 'number'},
        b_positions = {'B', 'port', 'vector'},
        b_radii = {'Br', 'port', 'number'},
        b_radii_knob = {'Br*', 'knob', 'number'},
        a_touches = {'At', 'port', 'number'},
        b_touches = {'Bt', 'port', 'number'},
    },
    layout = {
        {'a_positions', 'b_positions', 'a_radii', 'b_radii'},
        {'', '', 'a_radii_knob', 'b_radii_knob'},
        {'a_touches', 'b_touches'},
    },
    update = function(self, dt)
        local a = self.a_positions
        local b = self.b_positions
        local atouch = self.a_touches
        local btouch = self.b_touches
        local aradius = self.a_radii
        local bradius = self.b_radii
        local arknob = self.a_radii_knob
        local brknob = self.b_radii_knob

        for k, _ in pairs(atouch) do
            if not a[k] then
                atouch[k] = nil
            end
        end

        for j, _ in pairs(btouch) do
            if not b[j] then
                btouch[j] = nil
            end
        end

        atouch.default = 0
        btouch.default = 0

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
                        atouch[k] = 1
                        btouch[j] = 1
                    else
                        atouch[k] = 0
                        btouch[j] = 0
                    end
                end
            end
        end
    end,
    draw = function(self)
        for k, v in pairs(self.a_positions) do
            local x, y = denorm_point(v.x, v.y)
            local r = touch_radius(self.a_radii[k], self.a_radii_knob)
            love.graphics.circle('line', x, y, r * 600)
        end
        for k, v in pairs(self.b_positions) do
            local x, y = denorm_point(v.x, v.y)
            local r = touch_radius(self.b_radii[k], self.b_radii_knob)
            love.graphics.circle('line', x, y, r * 600)
        end
    end
}

module2 {
    name = 'grid',
    parts = {
        resolution = {'Res', 'port', 'number'},
        res_knob = {'', 'knob', 'number'},
        points = {'Out', 'port', 'vector'},
    },
    layout = {
        {'resolution'},
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
                local key = x * rx + y
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

--[[local m2point, m2delta, mclicks, mclicktime = module('mouse', {
    {'mp', 'vector'},
    {'md', 'vector'},
    {'clicks', 'vector'},
    {'ctime', 'number'},
})

local pvai, pvap, pvav, pvaa = module('pva', {
    {'i', 'vector'},
    {'p', 'vector'},
    {'v', 'vector', true},
    {'a', 'vector', true},
})

local c2points, c2radius = module('circle', {
    {'cv', 'vector'},
    {'cr', 'number', true}
})

local sin_freq, sin_amp, sin_offset, sin_output, sin_ids = module('sin', {
    {'f', 'number'},
    {'a', 'number'},
    {'o', 'number'},
    {'out', 'number'},
    {'id', '*'},
})

local vec_from, vec_to, vec_mult, vec_delta = module('vector', {
    {'from', 'vector'},
    {'to', 'vector'},
    {'*', 'number'},
    {'delta', 'vector'},
})

local vecm_input, vecm_add, vecm_mult, vecm_mag, vecm_output = module('vecm', {
    {'in', 'vector'},
    {'+', 'vector'},
    {'*', 'number'},
    {'mag', 'number'},
    {'out', 'vector'},
})

local rem_from, rem_trigger = module('rem', {
    {'from', '*'},
    {'trig', 'number'}
})

local touch_a, touch_arad, touch_b, touch_brad, touch_atouch, touch_btouch = module('touch', {
    {'a', 'vector'},
    {'ar', 'number', true},
    {'b', 'vector'},
    {'br', 'number', true},
    {'at', 'number'},
    {'bt', 'number'},
})

local grid_resolution, grid_points = module('grid', {
    {'res', 'number', true},
    {'points', 'vector'},
})

local comb_a, comb_b, comb_c, comb_output = module('combine', {
    {'a', '*'},
    {'b', '*'},
    {'c', '*'},
    {'out', '*'}
})]]--


local clicking_port = nil
local removing = false

local function point_in(point, p2, r)
    local dx = point.x - p2.x
    local dy = point.y - p2.y
    return dx * dx + dy * dy < r * r
end

local function draw_ports()
    for i=1,#ports do
        local port = ports[i]
        local mode = 'line'
        local mx, my = love.mouse.getPosition()
        if point_in({x=mx, y=my}, port, PORT_RADIUS) then
            mode = 'fill'
        end
        if port.name then
            local width = love.graphics.getFont():getWidth(port.name)
            love.graphics.print(port.name, math.floor(port.x - width / 2), port.y + 10)
        end
        local colors = {
            vector = {1, 1, 1, 1},
            number = {1, .8, .8, 1},
        }
        local color = colors[port.type or ''] or {1, 1, 1, .8}
        love.graphics.setColor(color)
        love.graphics.circle(mode, port.x, port.y, PORT_RADIUS)
        love.graphics.circle(mode, port.x, port.y, PORT_RADIUS / 2)
        love.graphics.setColor(1, 1, 1, 1)
    end
end

local function draw_knobs()
    for i=1,#knobs do
        local knob = knobs[i]
        local knob_mode = 'line'
        local mx, my = love.mouse.getPosition()
        local hovering = point_in({x=mx, y=my}, knob, KNOB_RADIUS)
        fill_mode = hovering and 'fill' or 'line'
        love.graphics.circle(fill_mode, knob.x, knob.y, KNOB_RADIUS)
        local t = math.pi / 2 + knob.value * math.pi * 2
        local ox, oy = math.cos(t) * KNOB_RADIUS, math.sin(t) * KNOB_RADIUS
        if fill_mode == 'fill' then
            love.graphics.setColor(0, 0, 0, 1)
        end
        love.graphics.line(knob.x, knob.y, knob.x + ox, knob.y + oy) 
        love.graphics.setColor(1, 1, 1, 1)
    end
end

local function draw_connections()
    for i=1,#edges do
        local conn = edges[i]
        local p1 = ports[conn[1]]
        local p2 = ports[conn[2]]
        love.graphics.line(p1.x, p1.y, p2.x, p2.y)
    end
end

local function get_connection_id(pid1, pid2)
    for i=1,#edges do
        local e = edges[i]
        if (e[1] == pid1 and e[2] == pid2) or (e[1] == pid2 and e[2] == pid1) then
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

local function disconnect1(pid)
    for i=1,#edges do
        local e = edges[i]
        if e[1] == pid or e[2] == pid then
            table.remove(edges, i)
            return
        end
    end
end

local function connect(pid1, pid2)
    local cid = get_connection_id(pid1, pid2)
    if not cid then
        table.insert(edges, {pid1, pid2})
    end
end

local function get_hovering_port_id()
    local mx, my = love.mouse.getPosition()
    local mp = {x=mx, y=my}
    for i=1,#ports do
        if point_in(mp, ports[i], PORT_RADIUS) then
            return i
        end
    end
    return nil
end

local function get_hovering_knob_id()
    local mx, my = love.mouse.getPosition()
    local mp = {x=mx, y=my}
    for i=1,#knobs do
        local knob = knobs[i]
        if point_in(mp, knob, KNOB_RADIUS) then
            return i
        end
    end
    return nil
end

local function update_ports()
    local edge_group = {}

    -- Connected components
    for i=1,#ports do
        edge_group[i] = i
    end

    local changed = true
    while changed do
        changed = false
        for i=1,#edges do
            local edge = edges[i]
            local min = math.min(edge_group[edge[1]], edge_group[edge[2]])
            if edge_group[edge[1]] ~= min then
                edge_group[edge[1]] = min
                changed = true
            end
            if edge_group[edge[2]] ~= min then
                edge_group[edge[2]] = min
                changed = true
            end
        end
    end

    local cc = {}
    for i=1,#edge_group do
        cells[edge_group[i]] = cells[edge_group[i]] or Cell()
        ports[i].cell = cells[edge_group[i]]
    end
end

function love.load()
    love.window.setMode(800, 600)
    update_ports()
end

local sin_thetas = Cell()
function love.update(dt)
    T = T + dt

    for i=1,#modules do
        local module = modules[i]
        visit_module(module, 'update', dt)
    end

    if tweaking_port then
        local cell = ports[tweaking_port].cell
        cell.default = cell.default or {x=0, y=0}
        for k, v in pairs(cell) do
            v.x = v.x - m2delta.cell.default.x * dt
            v.y = v.y - m2delta.cell.default.y * dt
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
    end
end

function love.draw(dt)
    --circles(c2points.cell, c2radius.cell, c2radius.knob)
    for i=1,#modules do
        visit_module(modules[i], 'draw')
    end

    for i=1,#modules do
        local module = modules[i]
        love.graphics.print(module.name, module.x, module.y)
    end

    love.graphics.setColor(0, 0, 0, .1)
    love.graphics.rectangle('fill', 0, 0, 200, 300)
    love.graphics.setColor(1, 1, 1, 1)
    draw_ports()
    draw_knobs()
    draw_connections()

    if clicking_port then
        local p = ports[clicking_port]
        local mx, my = love.mouse.getPosition()
        if removing then
            love.graphics.setColor(1, 0, 0, 1)
        end
        love.graphics.line(p.x, p.y, mx, my)
        love.graphics.setColor(1, 1, 1, 1)
    end

    if tweaking_port then
        local p = ports[tweaking_port]
        local mx, my = love.mouse.getPosition()
        love.graphics.line(p.x, p.y, mx, my)
        local v = p.cell.default
        love.graphics.print(string.format('%s, %s', v.x, v.y), mx, my)
    end
end

local _click_id = 0
function love.mousepressed(x, y, which)
    if which == 1 or which == 2 then
        clicking_port = get_hovering_port_id()
        removing = which == 2
        if not clicking_port then
            local x2, y2 = norm_point(x, y)
            mclicks[_click_id] = {x=x2, y=y2}
            --mclicktime.cell[_click_id] = T
            _click_id = _click_id + 1
        end
    elseif which == 3 then
        tweaking_port = get_hovering_port_id()
    end
end

function love.wheelmoved(x, y)
    kid = get_hovering_knob_id()
    if kid then
        local knob = knobs[kid]
        knob.value = math.min(math.max(knob.value + (y / 20), 0), 1)
    end
end

function love.mousereleased(x, y)
    hovering_port = get_hovering_port_id()

    if hovering_port and clicking_port then
        local type1, type2 = ports[hovering_port].type, ports[clicking_port].type
        if type1 == type2 or type1 == '*' or type2 == '*' then
            if removing then
                disconnect(clicking_port, hovering_port)
            else
                connect(hovering_port, clicking_port)
            end
            update_ports()
        end
    end

    clicking_port = nil
    tweaking_port = nil
end
