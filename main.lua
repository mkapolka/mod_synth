require "love"

local T = love.timer.getTime()
local PORT_RADIUS = 10
local KNOB_RADIUS = 8

local module_types = {}
local modules = {}
local ports = {}
local knobs = {}
local edges = { }
local cells = {}

local _click_id = 0

local clicking_port = nil
local removing = false
-- other ports that I'm connected to
local holding_connections = {}

-- Initialized in love.load
local screen = nil
local NORM_FACTOR = 600

local fullscreen = false

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

local function module2_part(part, x, y)
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
        output.value = .5
        table.insert(knobs, output)
    end
    return output
end

local mx = 0
local my = 0
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

    local mw = #template.layout[1] * 40
    local mh = #template.layout[1] * 50

    if mx + mw > love.graphics.getWidth() then
        mx = 0
        my = my + mh
    end

    template.target = {}
    template.x = mx
    template.y = my
    
    local new_parts = {}
    local yoffset = my
    for ly=1,#template.layout do
        if ly == 1 then
            yoffset = yoffset + 30
        else
            yoffset = yoffset + 40
        end

        local row = template.layout[ly]
        for lx=1,#row do
            local key = row[lx]
            local part = template.parts[key]
            if part then
                new_parts[key] = module2_part(part, mx + lx * 30, yoffset)
            end
        end
    end

    mx = mx + mw

    for k in pairs(template.parts) do
        if not new_parts[k] then
            error(string.format("Part %s is not included in the layout", k))
        end
    end

    template.parts = new_parts
    table.insert(modules, template)
end

local function module2(template)
    module_types[template.name] = template
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

local mclicks = Cell()
module2 {
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

module2 {
    name = 'touch',
    parts = {
        a_positions = {'A', 'port', 'vector', 'in'},
        a_radii = {'Ar', 'port', 'number', 'in'},
        a_radii_knob = {'Ar*', 'knob', 'number'},
        b_positions = {'B', 'port', 'vector', 'in'},
        b_radii = {'Br', 'port', 'number', 'in'},
        b_radii_knob = {'Br*', 'knob', 'number'},
        touches = {'T', 'port', 'number', 'out'},
    },
    layout = {
        {'a_positions', 'b_positions', 'a_radii', 'b_radii'},
        {'', '', 'a_radii_knob', 'b_radii_knob'},
        {'touches'},
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
            if not a[k] then
                touch[k] = nil
            end
        end

        for j, _ in pairs(touch) do
            if not b[j] then
                touch[j] = nil
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
                        touch[k] = 1
                        touch[j] = 1
                    else
                        touch[k] = 0
                        touch[j] = 0
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
                local key = 'grid_' .. (x * rx + y)
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

module2 {
    name = 'guys',
    parts = {
        positions = {'V', 'port', 'vector', 'in'},
        targets = {'Targ', 'port', 'vector', 'in'},
        speed = {'Spd', 'port', 'number', 'in'},
        speed_knob = {'', 'knob', 'number'},
        min_knob = {'MIN', 'knob', 'number'},
        max_knob = {'MAX', 'knob', 'number'},
        positions_out = {'Vout', 'port', 'vector', 'out'},
        distance_out = {'D', 'port', 'number', 'out'}
    },
    layout = {
        {'positions', 'targets', 'speed', 'speed_knob'},
        {'min_knob', 'max_knob'},
        {'positions_out', 'distance_out'}
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
    end
}

module2 {
    name = 'death',
    parts = {
        members = {'Input', 'port', '*', 'in'},
        living = {'Living', 'port', '*', 'out'},
        die = {'Die', 'port', 'number', 'in'}
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
        if clicking_port then
            local clicking = ports[clicking_port]
            if clicking.output == port.output or not types_match(clicking.type, port.type) then
                color[4] = .3
            end
        end
        love.graphics.setColor(color)
        love.graphics.circle(mode, port.x, port.y, PORT_RADIUS)
        love.graphics.circle(mode, port.x, port.y, PORT_RADIUS / 2)
        if port.output then
            local fx, fy = math.floor(port.x), math.floor(port.y)
            love.graphics.rectangle('line', fx - PORT_RADIUS, fy-PORT_RADIUS, PORT_RADIUS*2, PORT_RADIUS*2)
        end
        love.graphics.setColor(1, 1, 1, 1)
    end
end

local function draw_knobs()
    for i=1,#knobs do
        local knob = knobs[i]
        if knob.name then
            local width = love.graphics.getFont():getWidth(knob.name)
            love.graphics.print(knob.name, math.floor(knob.x - width / 2), knob.y + 10)
        end

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

local function disconnect_all(pid)
    local to_remove = {}
    for i=1,#edges do
        local e = edges[i]
        if e[1] == pid or e[2] == pid then
            table.insert(to_remove, i)
        end
    end

    for i=#to_remove,1,-1 do
        table.remove(edges, to_remove[i])
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
    for k, v in pairs(ports) do
        v.cell = v.own_cell
    end

    for i=1,#edges do
        local edge = edges[i]
        local left = ports[edge[1]]
        local right = ports[edge[2]]
        local out_port = left.output and left or right
        local in_port = not left.output and left or right
        in_port.cell = out_port.cell
    end
end

function love.load()
    love.window.setMode(1024, 768)
    NORM_FACTOR, _ = love.graphics.getDimensions()
    screen = love.graphics.newCanvas()

    -- Rack the modules we want
    rack('mouse')
    rack('grid')
    rack('guys')
    rack('death')
    rack('touch')
    rack('circles')
    rack('circles')
    
    update_ports()
    for i=1,#modules do
        local module = modules[i]
        visit_module(module, 'start')
    end
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

    if key == 'f' then
        fullscreen = not fullscreen
    end
end

function love.draw(dt)
    if not fullscreen then
        for i=1,#modules do
            local module = modules[i]
            love.graphics.print(module.name, module.x, module.y)
            local mw = #module.layout[1] * 40
            local mh = #module.layout * 50
            love.graphics.rectangle('line', module.x, module.y, mw, mh)
        end

        draw_ports()
        draw_knobs()
        draw_connections()

        if clicking_port then
            local mx, my = love.mouse.getPosition()
            for i=1,#holding_connections do
                local port = ports[holding_connections[i]]
                love.graphics.line(mx, my, port.x, port.y)
            end
        end

        if tweaking_port then
            local p = ports[tweaking_port]
            local mx, my = love.mouse.getPosition()
            love.graphics.line(p.x, p.y, mx, my)
            local v = p.cell.default
            love.graphics.print(string.format('%s, %s', v.x, v.y), mx, my)
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
end

function love.mousepressed(x, y, which)
    if which == 1 then
        clicking_port = get_hovering_port_id()

        if clicking_port then
            -- immediatly disconnect
            local cp = ports[clicking_port]
            holding_connections = {}
            for i=1,#edges do
                local edge = edges[i]
                if edge[1] == clicking_port then
                    table.insert(holding_connections, edge[2])
                end

                if edge[2] == clicking_port then
                    table.insert(holding_connections, edge[1])
                end
            end

            if #holding_connections == 0 then
                table.insert(holding_connections, clicking_port)
            end

            disconnect_all(clicking_port)
            update_ports()
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
        end
    end
end

function love.mousereleased(x, y)
    hovering_port = get_hovering_port_id()

    if hovering_port and clicking_port then
        local hovering = ports[hovering_port]
        local clicking = ports[clicking_port]
        local type1, type2 = hovering.type, clicking.type
        if types_match(type1, type2) and hovering.output ~= clicking.output then
            for i=1,#holding_connections do
                connect(hovering_port, holding_connections[i])
            end
            update_ports()
        end
    end

    clicking_port = nil
    tweaking_port = nil
end

function love.wheelmoved(x, y)
    kid = get_hovering_knob_id()
    if kid then
        local knob = knobs[kid]
        knob.value = math.min(math.max(knob.value + (y / 20), 0), 1)
    end
end

