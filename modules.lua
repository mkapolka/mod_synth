local Utils = require "utils"
local socket = require "socket"
local Mouse = require "mouse"

-- n is a number between -1 and 1,
-- output is between 0 and 1
function z1(n)
    return (n + 1) / 2
end

-- n is a number between zero and one
-- output is between -1 and 1
function np1(n)
    return n * 2 - 1
end

local function module(template)
    module_types[template.name] = template
end

local function attenuvert(input, knob, to_np1)
    if to_np1 then
        return np1(input) * np1(knob)
    else
        if knob < .5 then
            return (1 - input) * -np1(knob)
        end
        return input * np1(knob)
    end
end

-- Experimental port / knob logic: If no input, knob = value
-- With input, knob = attenuverter
local function supervert(key, port, knob, to_np1)
    if port[key] ~= undefined then
        return attenuvert(port[key], knob, to_np1)
    end
    if to_np1 then
        return np1(knob)
    end
    return knob
end

module {
    name = 'wrap',
    parts = {
        points = {'V', 'port', 'vector'},
        output = {'Vout', 'port', 'vector', 'out'},
        give = {'Give', 'knob', default=1}
    },
    layout = {
        {'points', 'output'},
        {'give', ''}
    },
    update = function(self, dt)
        -- 0 -> 2
        local give = 1 + np1(self.give)
        for k, v in pairs(self.points) do
            local x, y = v.x, v.y
            x = (x + give) % (give * 2) - give
            y = (y + give) % (give * 2) - give
            local v = self.output[k] or {}
            v.x = x
            v.y = y
            self.output[k] = v
        end

        Utils.cell_trim(self.points, self.output)
    end
}

module {
    name = 'keyboard',
    parts = {
        joystick = {'J', 'port', 'vector', 'out'},
        shoot = {'S', 'port', 'number', 'out'},
        horizontal = {'H', 'port', 'number', 'out'},
        vertical = {'V', 'port', 'number', 'out'},
        --goosh = {'SFT', 'knob'}
    },
    layout = {
        {'joystick', 'shoot'},
        {'horizontal', 'vertical'},
    },
    update = function(self, dt)
        local vertical = 0
        local horizontal = 0

        if love.keyboard.isDown('down') then
            vertical = vertical - 1
        end

        if love.keyboard.isDown('up') then
            vertical = vertical + 1
        end

        if love.keyboard.isDown('left') then
            horizontal = horizontal - 1
        end

        if love.keyboard.isDown('right') then
            horizontal = horizontal + 1
        end

        self.joystick.default = {x=horizontal, y=vertical}
        self.joystick.value = {x=horizontal, y=vertical}

        self.horizontal.default = horizontal
        self.horizontal.value = horizontal

        self.vertical.default = vertical
        self.vertical.value = vertical

        local shoot = 0
        if love.keyboard.isDown("z") then
            shoot = 1
        end

        self.shoot.default = shoot
        self.shoot.value = shoot
    end
}

function _update_spaceship(self, k, v, dt)
    -- Deltas from starting position
    local old_point = self._points[k] or v
    local output_point = rawget(self.position, k) or {x=v.x, y=v.y}
    local delta = {x = v.x - old_point.x, y = v.y - old_point.y}
    output_point.x = output_point.x + delta.x
    output_point.y = output_point.y + delta.y

    local forward = self.forward[k] or 0
    local turn = self.turn[k] or 0
    local rotation = self.rotation[k] or 0

    -- Driving
    self.rotation[k] = rotation + turn * self.turning_speed * dt % 1
    output_point.x = output_point.x + math.cos(self.rotation[k] * math.pi * 2) * forward * self.speed * dt
    output_point.y = output_point.y + math.sin(self.rotation[k] * math.pi * 2) * forward * self.speed * dt
    self.position[k] = output_point
end

module {
    name = 'spaceships',
    parts = {
        points = {'Vs', 'port', 'vector'},
        forward = {'Go', 'port', 'number'},
        turn = {'Trn', 'port', 'number'},

        speed = {'Go*', 'knob'},
        turning_speed = {'Trn*', 'knob'},

        position = {'Vo', 'port', 'vector', 'out'},
        rotation = {'Ro', 'port', 'number', 'out'},
        default = {'+1', 'button', default=true},
    },
    layout = {
        {'points', 'forward', 'turn'},
        {'default', 'speed', 'turning_speed'},
        {'', 'position', 'rotation'},
    },
    start = function(self, dt)
        self._points = {}
    end,
    restart = function(self)
        self._points = {}
    end,
    update = function(self, dt)
        self._points = self._points or {}
        for k, v in pairs(self.points) do
            _update_spaceship(self, k, v, dt)
        end

        if self.default then
            _update_spaceship(self, "spaceship", {x=0, y=0}, dt)
            self.position.default = self.position.spaceship
            self.rotation.default = self.rotation.spaceship
        elseif #self.points > 0 then
            local avg_pos = 0
            local avg_rotation = 0
            for key in pairs(self.points) do
                avg_pos = avg_pos + self.position[key]
                avg_rotation = avg_rotation + self.rotation[key]
            end
            self.position.default = avg_pos / #self.points
            self.rotation.default = avg_rotation / #self.points
        end

        for k, _ in pairs(self.position) do
            if k ~= "spaceship" and not self.points[k] then
                self.position[k] = nil
                self.rotation[k] = nil
            end
        end
    end
}

module {
    name = 'circles',
    parts = {
        points = {'V', 'port', 'vector'},
        radii = {'R', 'port', 'number'},
        color = {'C', 'port', 'color', 'in'},
        radius_knob = {'R', 'knob', default=.75},
        fill_mode = {'fill', 'button', default=false},
        draw_order = {'DO', 'knob'},
    },
    layout = {
        {'points', 'radii', 'color'},
        {'fill_mode', 'radius_knob', 'draw_order'}
    },
    draw = function(self)
        local function f(k)
            local v = self.points[k] or {x=0, y=0}
            local c = self.color[k] or {1, 1, 1, 1}
            local r = 1
            local radius = supervert(k, self.radii, self.radius_knob) * 400
            local nx, ny = Utils.denorm_point(v.x, v.y)
            love.graphics.setColor(unpack(c))
            local mode = 'line'
            if self.fill_mode then
                mode = 'fill'
            end
            love.graphics.circle(mode, nx, ny, radius)
            love.graphics.setColor(1, 1, 1, 1)
        end
        local default = true
        for k, v in pairs(self.points) do
            f(k)
            default = false
        end
        if default then
            f("default")
        end
    end
}

module {
    name = 'mouse',
    parts = {
        clicks = {'CLK', 'port', 'vector', 'out'},
        position = {'POS', 'port', 'vector', 'out'},
        down = {'DWN', 'port', 'number', 'out'}
    },
    layout = {
        {'clicks', 'position', 'down'}
    },
    restart = function(self)
        for k, v in pairs(mclicks) do
            mclicks[k] = nil
        end
    end,
    update = function(self, dt)
        for k, v in pairs(self.clicks) do
            k = self.id .. k
            if not mclicks[k] then
                self.clicks[k] = nil
            end
        end

        for k, v in pairs(mclicks) do
            k = self.id .. k
            self.clicks[k] = v
        end
        self.clicks.default = mclicks.default

        self.position.default = self.position.default or {}
        self.position.point = self.position.point or {}

        local mx, my = love.mouse.getPosition()
        if not FULLSCREEN then
            local sw, sh = love.graphics.getDimensions()
            if mx > 2 * sw / 3 and my > 2 * sh / 3 then
                mx = (mx - (2 * sw / 3)) * 3
                my = (my - (2 * sh / 3)) * 3
            end
        end
        local nx, ny = Utils.norm_point(mx, my)
        self.position.default.x = nx
        self.position.default.y = ny
        self.position.point.x = nx
        self.position.point.y = ny

        self.down.default = love.mouse.isDown(1) and 1 or 0
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
            if not rawget(a, k) and not rawget(b, k) then
                touch[k] = nil
            else
                touch[k] = 0
            end
        end

        touch.default = 0

        local function touchSet(key, value)
            local existing = rawget(touch, key) or 0
            if key == "default" then
                existing = touch.default or 0
            end
            touch[key] = math.max(existing, value or 0, 0)
        end

        for k in Utils.all_keys(a) do
            for j in Utils.all_keys(b) do
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
                            touchSet(k, v)
                            touchSet(j, v)
                        end
                    else
                        touchSet(k, v)
                        touchSet(j, v)
                    end
                end
            end
        end
    end,
    draw = function(self)
        local w, h = love.window.getMode()
        local normy = math.max(w, h)
        if self.debug_switch then
            for k, v in pairs(self.a_positions) do
                local x, y = Utils.denorm_point(v.x, v.y)
                local r = touch_radius(self.a_radii[k], self.a_radii_knob) / 2
                local t = self.touches[k]
                love.graphics.setColor(1, 1-t, 1-t, 1)
                love.graphics.circle('line', x, y, r * normy)
            end
            for k, v in pairs(self.b_positions) do
                local x, y = Utils.denorm_point(v.x, v.y)
                local r = touch_radius(self.b_radii[k], self.b_radii_knob) / 2
                local t = self.touches[k]
                love.graphics.setColor(1, 1-t, 1-t, 1)
                love.graphics.circle('line', x, y, r * normy)
            end
            love.graphics.setColor(1, 1, 1, 1)
        end
    end
}

module {
    name = 'grid',
    parts = {
        res_knob_x = {'ResX', 'knob', 'number'},
        res_knob_y = {'ResY', 'knob', 'number'},
        width = {'Width', 'knob'},
        height = {'Height', 'knob'},
        wobble = {'Wob', 'knob', 'number', default=0},
        points = {'Out', 'port', 'vector', 'out'},
    },
    layout = {
        {'res_knob_x', 'res_knob_y'},
        {'width', 'height'},
        {'wobble', 'points'}
    },
    update = function(self, dt)
        --local res = ((self.resolution.default or .5) + 1) * .5
        local res_x = self.res_knob_x
        local res_y = self.res_knob_y
        local rx = math.floor(20 * res_x)
        local ry = math.floor(20 * res_y)
        local width = 1 + np1(self.width)
        local height = 1 + np1(self.height)
        local wobble_x = self.wobble * width
        local wobble_y = self.wobble * height
        local seen = {}
        if rx > 0 and ry > 0 then
            for x=0,rx do
                for y = 0,ry do
                    local fx = np1(x / rx) * width
                    local fy = np1(y / ry) * height
                    local key = 'grid_' .. self.id .. '_' .. (x * (ry + 1) + y)
                    local p = self.points[key] or {}
                    p.x = fx + np1(love.math.noise(fx, fy)) * wobble_x
                    p.y = fy + np1(love.math.noise(fx + 1000, fy + 1000)) * wobble_y
                    self.points[key] = p
                    seen[key] = true
                end
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
        speed_knob = {'Spd', 'knob', 'number'},
        acceleration = {'Acc', 'knob'},
        drag = {'Drg', 'knob'},
        return_btn = {'RTN', 'button'},
        min_knob = {'MIN', 'knob', 'number', default=0},
        max_knob = {'MAX', 'knob', 'number', default=1},
        positions_out = {'Vout', 'port', 'vector', 'out'},
        distance_out = {'D', 'port', 'number', 'out'},
        respawn = {'Respawn', 'port', 'number', 'in'},
        debug = {'DBG', 'button', default=false}
    },
    layout = {
        {'positions', 'targets', 'speed_knob', 'acceleration'},
        {'min_knob', 'max_knob', 'drag', 'respawn'},
        {'debug', 'return_btn', 'positions_out', 'distance_out'}
    },
    start = function(self)
        self.offsets = {}
        self.velocities = {}
    end,
    restart = function(self)
        self.offsets = {}
        self.velocities = {}
    end,
    update = function(self, dt)
        for k, v in pairs(self.positions_out) do
            if not self.positions[k] then
                self.positions_out[k] = nil
                self.offsets[k] = nil
                self.distance_out[k] = nil
            end
        end

        for k in Utils.all_keys(self.positions, {default=true}) do
            local p = self.positions[k] or {x=0, y=0}
            if self.respawn[k] and self.respawn[k] > .8 then
                self.offsets[k] = {x=0, y=0}
            end

            --local speed = (self.speed[k] or 1) * self.speed_knob
            local speed = math.pow(self.speed_knob, 2) * 4
            self.offsets[k] = self.offsets[k] or {x=0, y=0}
            local offset = self.offsets[k]

            local guyx = p.x + offset.x
            local guyy = p.y + offset.y
            local target = self.targets[k] or {x=guyx, y=guyy}

            local dx = target.x - guyx
            local dy = target.y - guyy
            local d = math.sqrt(dx * dx + dy * dy)
            local dout = d
            local min = self.min_knob
            local max = self.max_knob
            if self.max_knob == 1 then
                max = 100000
            end

            local v = self.velocities[k] or {x=0, y=0}

            -- Avoid if too close
            local avoid = false
            if d < min then
                avoid = true
                target = {
                    x = target.x - (dx / d) * min,
                    y = target.y - (dy / d) * min,
                }
                dx = target.x - guyx
                dy = target.y - guyy
                d = math.sqrt(dx * dx + dy * dy)
            elseif d > max and self.return_btn then
                target = p
                dx = target.x - guyx
                dy = target.y - guyy
                d = math.sqrt(dx * dx + dy * dy)
                avoid = true
            end

            local drag = self.drag * 40
            if (d < max or avoid) and d > .05 then
                local dxn = dx / d
                local dyn = dy / d
                local velocity = math.sqrt(v.x * v.x + v.y * v.y)
                local rel_vel = dxn * v.x + dyn * v.y -- dot product
                if rel_vel < speed * 5 then
                    v.x = v.x + (dx / d) * (self.acceleration * 50) * dt
                    v.y = v.y + (dy / d) * (self.acceleration * 50) * dt
                end
                drag = self.drag * 10
            end

            --local drag = self.drag * 20
            v.x = v.x - (v.x * drag * dt)
            v.y = v.y - (v.y * drag * dt)

            self.velocities[k] = v
            self.distance_out[k] = dout / 2

            offset.x = offset.x + v.x * dt
            offset.y = offset.y + v.y * dt
            
            self.positions_out[k] = rawget(self.positions_out, k) or {x=0, y=0}
            local pout = self.positions_out[k]
            pout.x = p.x + offset.x
            pout.y = p.y + offset.y
        end
    end,
    draw = function(self)
        if self.debug then
            for k, v in pairs(self.positions) do
                local offset = self.offsets[k] or {x=0, y=0}
                local px, py = Utils.denorm_point(v.x + offset.x, v.y + offset.y)
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
        health = {'HP', 'port', 'number', 'out'},
        die = {'Die', 'port', 'number', 'in'},
        poison = {'PSN', 'port', 'number', 'in'},
        poison_knob = {'', 'knob'},
    },
    layout = {
        {'members', ''},
        {'die', 'poison'},
        {'', 'poison_knob'},
        {'health', 'living'},
    },
    start = function(self)
        self._deaths = {}
        self.health = {}
    end,
    restart = function(self)
        self._deaths = {}
        self.health = {}
    end,
    update = function(self, dt)
        for k, v in pairs(self.living) do
            if not self.members[k] then
                self.living[k] = nil
                self._deaths[k] = nil
                self.health[k] = nil
            end
        end

        local pk = math.pow(self.poison_knob, 2) * 4
        for k, v in pairs(self.members) do
            self.health[k] = self.health[k] or 1

            if self.poison[k] then
                local p = self.poison[k] * pk
                self.health[k] = math.max(0, self.health[k] - p * dt)
            end

            if not self._deaths[k] then
                self._deaths[k] = false
                self.living[k] = v
            end

            if (self.die[k] and self.die[k] > .8) or self.health[k] < 0 then
                self._deaths[k] = true
                self.living[k] = nil
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

        for key in Utils.all_keys(self.a, self.b, self.c) do
            local a = self.a[key] or 0
            local b = self.b[key] or 1
            local c = self.c[key] or 1
            local cknob = np1(self.cknob)
            c = c * cknob
            self.out[key] = a + b * c
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
        alpha_target_knob = {'AT', 'knob'},
        hue = {'H', 'port', 'number', 'in'},
        saturation = {'S', 'port', 'number', 'in'},
        value = {'V', 'port', 'number', 'in'},
        alpha = {'A', 'port', 'number', 'in'},
        hue_knob = {'H*', 'knob'},
        saturation_knob = {'S*', 'knob'},
        value_knob = {'V*', 'knob'},
        alpha_knob = {'A*', 'knob'},
        output = {'Out', 'port', 'color', 'out'},
    },
    layout = {
        {'hue_target_knob', 'saturation_target_knob', 'value_target_knob', 'alpha_target_knob'},
        {'hue', 'saturation', 'value', 'alpha'},
        {'hue_knob', 'saturation_knob', 'value_knob', 'alpha_knob'},
        {'', '', '', 'output'},
    },
    update = function(self)
        local function f(key)
            local h = self.hue_target_knob + supervert(key, self.hue, self.hue_knob)
            local s = self.saturation_target_knob + supervert(key, self.saturation, self.saturation_knob)
            local v = self.value_target_knob + supervert(key, self.value, self.value_knob)
            local a = self.alpha_target_knob + supervert(key, self.alpha, self.alpha_knob)
            local r, g, b = Utils.hsv(h, s, v)
            self.output[key] = {r, g, b, a}
        end
        local keys = {}
        for key in Utils.all_keys(self.hue, self.saturation, self.value, self.alpha) do
            f(key)
            keys[key] = true
        end
        f('default')
        Utils.cell_trim(keys, self.hue, {self.saturation, self.value, self.alpha})
    end
}

module {
    name = 'color-s',
    parts = {
        hue_knob = {'H', 'knob'},
        saturation_knob = {'S', 'knob'},
        value_knob = {'V', 'knob'},
        alpha_knob = {'A', 'knob'},
        output = {'Out', 'port', 'color', 'out'},
    },
    layout = {
        {'hue_knob', 'saturation_knob', 'value_knob', 'alpha_knob', 'output'}
    },
    update = function(self, dt)
        self.output.default = self.output.default or {}
        local d = self.output.default
        r, g, b = Utils.hsv(self.hue_knob, self.saturation_knob, self.value_knob)
        d[1] = r
        d[2] = g
        d[3] = b
        d[4] = self.alpha_knob
    end
}

module {
    name = 'simplex',
    parts = {
        roughness = {'Rough', 'knob'},
        vectors = {'V', 'port', 'vector', 'in'},
        drift = {'Drift', 'knob', 'number'},
        output = {'Out', 'port', 'number', 'out'},
        output_vector = {'OutV', 'port', 'vector', 'out'},
    },
    layout = {
        {'vectors', ''},
        {'drift', 'roughness'},
        {'output', 'output_vector'}
    },
    update = function(self, dt)
        local rough = self.roughness * 10
        self._drift = self._drift or math.random() * 1000
        self._drift = self._drift + dt * math.pow(self.drift, 3) * 20

        for key in pairs(self.output) do
            if not self.vectors[key] then
                self.output[key] = nil
                self.output_vector[key] = nil
            end
        end

        for key in Utils.all_keys(self.vectors, {default=true}) do
            local value = self.vectors[key] or {x=0, y=0}
            local nx, ny = value.x * rough, value.y * rough
            self.output[key] = love.math.noise(nx, ny, self._drift)
            local dx = love.math.noise(nx, ny, self._drift)
            local dy = love.math.noise(nx + 100, ny + 100, self._drift)
            self.output_vector[key] = {x=np1(dx), y=np1(dy)}
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
            local offset = self._offsets[key] or love.math.random()
            local freq = math.pow(np1(self.freq), 3) * 30
            self._offsets[key] = offset + dt * freq
            offset = self._offsets[key]
            if self.sin then
                self.out[key] = (1 + math.sin(offset * math.pi)) / 2
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

local function sinWave(d)
    return z1(math.sin(d * math.pi * 2))
end

local function triWave(d)
    if d < .5 then
        return d * 2
    else
        return 1 - (d - .5) * 2
    end
end

local function sawWave(d)
    return d % 1
end

local shapes = {sinWave, triWave, sawWave}

module {
    name = 'lfo2',
    parts = {
        ids = {'Id', 'port', '*', 'in'},
        random_start_1 = {'Rand', 'button'},
        random_start_2 = {'Rand', 'button'},
        sync_knob = {'Sync', 'knob'},
        shape_1 = {'Shape', 'knob'},
        freq_1 = {'F', 'port', 'number', 'in'},
        freq_knob_1 = {'*', 'knob', default=.75},
        amp_1 = {'A', 'port', 'number', 'in'},
        amp_knob_1 = {'*', 'knob'},
        shape_2 = {'Shape', 'knob'},
        freq_2 = {'F', 'port', 'number', 'in'},
        freq_knob_2 = {'*', 'knob'},
        amp_2 = {'A', 'port', 'number', 'in', default=.75},
        amp_knob_2 = {'*', 'knob'},
        x_out = {'X', 'port', 'number', 'out'},
        y_out = {'Y', 'port', 'number', 'out'},
        xpy_out = {'X+Y', 'port', 'number', 'out'},
        vector_out = {'V', 'port', 'vector', 'out'}
    },
    layout = {
        {'ids', 'sync_knob', 'random_start_1', '' ,'' ,'random_start_2'},
        {'shape_1', 'freq_1', 'amp_1', 'shape_2', 'freq_2', 'amp_2'},
        {'', 'freq_knob_1', 'amp_knob_1', '', 'freq_knob_2', 'amp_knob_2'},
        {'x_out', 'y_out', 'xpy_out', 'vector_out'}
    },
    update = function(self, dt)
        self._offsets = self._offsets or {}
        self._offsets_2 = self._offsets_2 or {}

        local function f(key, offsets, shape, freq, freq_knob, amp, amp_knob, sync, rand, out)
            local offset = offsets[key] or (rand and math.random() or 0)
            local f = freq[key] or 1
            local a = amp[key] or 1

            local shape_f = shapes[1+math.floor(shape * (#shapes-1))]

            local frequency = math.pow(supervert(key, freq, freq_knob), 2) * 10
            local amplitude = supervert(key, amp, amp_knob)
            local shape_output = shape_f((offset + sync) % 1)
            out[key] = shape_output * amplitude

            offset = (offset + frequency * dt) % 1
            offsets[key] = offset

            return np1(shape_output) * amplitude
        end

        for key in Utils.all_keys(self.ids, {default=true}) do
            local x = f(key, self._offsets, self.shape_1, self.freq_1, self.freq_knob_1, self.amp_1, self.amp_knob_1, 0, self.random_start_1, self.x_out)
            local y = f(key, self._offsets_2, self.shape_2, self.freq_2, self.freq_knob_2, self.amp_2, self.amp_knob_2, self.sync_knob * .5, self.random_start_2, self.y_out)

            self.xpy_out[key] = self.x_out[key] / 2 + self.y_out[key] / 2
            local vout = rawget(self.vector_out, key) or {}
            vout.x = x
            vout.y = y
            self.vector_out[key] = vout
        end

        Utils.cell_trim(self.ids, self.x_out, {self.y_out, self.vector_out})
    end
}

module {
    name = 'rerange',
    parts = {
        input = {'In', 'port', 'number', 'in'},
        min = {'Min', 'knob', default=0},
        max = {'Max', 'knob', default=1},
        output = {'Out', 'port', 'number', 'out'}
    },
    layout = {
        {'input', 'min', 'max', 'output'}
    },
    update = function(self)
        Utils.cell_map(self.input, function(key, value)
            value = value or 0
            self.output[key] = self.min + value * (self.max - self.min)
        end)
        Utils.cell_trim(self.input, self.output)
    end
}

module {
    name = 'clear',
    parts = {
        color = {'C', 'port', 'color', 'in'}
    },
    layout = {
        {'color'}
    },
    update = function(self)
        CLEAR_COLOR = self.color.default or {0, 0, 0, 1}
    end
}

local function buttonToNumber(b1, b2, b3, b4)
    local which = 0
    which = which + (b1 and 1 or 0)
    which = which + (b2 and 2 or 0)
    which = which + (b3 and 4 or 0)
    which = which + (b4 and 8 or 0)
    return which + 1
end

local function parseBank(bank)
    local output = {}
    for line in love.filesystem.lines(bank) do
        if not line:match("^#") then
            local row = {}
            for m in string.gmatch(line, "%S+") do
                table.insert(row, m)
            end
            table.insert(output, row)
        end
    end
    return output
end

local images = {}
local i = 0
-- for line in love.filesystem.lines("images/bank_1") do
--[[for line in love.filesystem.lines("images/bank_2") do
    -- comments
    if not line:match("^#") then
        images[i] = love.graphics.newImage("images/" .. line)
        images[i]:setFilter('nearest')
        i = i + 1
    end
end]]--

for i, line in pairs(parseBank("images/bank_2")) do
    images[i] = love.graphics.newImage("images/" .. line[1])
    images[i]:setFilter("nearest")
end

module {
    name = 'sprites',
    parts = {
        positions = {'V', 'port', 'vector', 'in'},
        rotations = {'R', 'port', 'number', 'in'},
        scales = {'S', 'port', 'number', 'in'},
        colors = {'C', 'port', 'color', 'in'},
        draw_order = {'DO', 'knob'},
        btn_1 = {'Sprite', 'button', default=false},
        btn_2 = {'', 'button', default=false},
        btn_3 = {'', 'button', default=false},
        btn_4 = {'', 'button', default=false},
    },
    layout = {
        {'draw_order', '', '', ''},
        {'positions', 'rotations', 'scales', 'colors'},
        {'btn_1', 'btn_2', 'btn_3', 'btn_4'},
    },
    draw = function(self)
        for key, position in pairs(self.positions) do
            local r = self.rotations[key] or 0
            local c = self.colors[key] or {1, 1, 1, 1}
            local s = self.scales[key] or .5
            s = math.pow(s, 2) * 4
            local which = buttonToNumber(self.btn_1, self.btn_2, self.btn_3, self.btn_4)
            local sx, sy = Utils.denorm_point(position.x, position.y)
            local sprite = images[which]
            local sw, sh = sprite:getDimensions()
            love.graphics.setColor(c)
            love.graphics.draw(images[which], sx, sy, r * math.pi * 2, s, s, sw / 2, sh / 2)
        end
        love.graphics.setColor(1, 1, 1, 1)
    end
}

local sfx = {}

for i, line in pairs(parseBank("sfx/bank_1")) do
    local sources = {}
    for j, filename in pairs(line) do
        table.insert(sources, love.audio.newSource("sfx/" .. filename, "static"))
    end
    sfx[i] = sources
end

module {
    name = 'sfx',
    parts = {
        play = {'Play', 'port', 'number', 'in'},
        pitch = {'Pitch', 'port', 'number', 'in', default=.5},
        pitch_k = {'', 'knob', default=.5},
        volume = {'Vol', 'port', 'number', 'in', default=.5},
        volume_k = {'', 'knob', default=.5},
        btn_1 = {'Sfx', 'button', default=false},
        btn_2 = {'', 'button', default=false},
        btn_3 = {'', 'button', default=false},
        btn_4 = {'', 'button', default=false},
    },
    layout = {
        {'play', 'pitch', 'volume', ''},
        {'', 'pitch_k', 'volume_k', ''},
        {'btn_1', 'btn_2', 'btn_3', 'btn_4'},
    },
    start = function(self)
        self._pv = {}
    end,
    restart = function(self)
        self._pv = {}
    end,
    update = function(self)
        local sfxi = buttonToNumber(self.btn_1, self.btn_2, self.btn_3, self.btn_4)
        local function updateKey(key, v)
            local pv = self._pv[key] or 0
            if v > .5 and pv <= .5 then
                local sources = sfx[sfxi]
                local source = sources[love.math.random(1, #sources)]
                local pitchv = self.pitch[key] or .5
                local volumev = self.volume[key] or .5
                local pitch = .5 + supervert(key, self.pitch, self.pitch_k)
                --local pitch = (pitchv + .5) * (self.pitch_k + .5)
                local volume = (volumev + .5) * (self.volume_k + .5)
                source:setPitch(pitch)
                source:setVolume(volume)
                source:stop()
                love.audio.play(source)
            end
            self._pv[key] = v
        end
        for key, v in pairs(self.play) do
            updateKey(key, v)
        end
        updateKey("default", self.play.default or 0)
    end,
}

local animations = {}

for i, line in pairs(parseBank("animations/bank_1")) do
    local path, width, height = line[1], line[2], line[3]
    path = "animations/" .. path
    local quads = {}
    local image = love.graphics.newImage(path)
    local iw, ih = image:getDimensions()
    for j=0,image:getHeight()/height-1 do
        for i=0,image:getWidth()/width-1 do
            table.insert(quads, love.graphics.newQuad(i*width,j*height,width,height,iw,ih))
        end
    end
    table.insert(animations, {
        image=image,
        quads=quads,
        width = width,
        height = height
    })
end

module {
    name = 'animations',
    parts = {
        positions = {'V', 'port', 'vector', 'in'},
        rotations = {'R', 'port', 'number', 'in'},
        rotation_knob = {'+', 'knob', default=0},
        scales = {'S', 'port', 'number', 'in'},
        scale_knob = {'*', 'knob'},
        colors = {'C', 'port', 'color', 'in'},
        frame = {'F', 'port', 'number', 'in'},
        frame_out = {'F', 'port', 'number', 'out'},
        ping_pong = {'Pong', 'button', default=false},
        speed = {'Spd', 'knob'},
        speed_in = {'Spd', 'port', 'number', 'in'},
        draw_order = {'DO', 'knob'},
        order = {'Order', 'port', 'number', 'in'},
        btn_1 = {'Sprite', 'button', default=false},
        btn_2 = {'', 'button', default=false},
        btn_3 = {'', 'button', default=false},
        btn_4 = {'', 'button', default=false},
    },
    layout = {
        {'draw_order', 'order', '', 'frame_out'},
        {'positions', 'rotations', 'scales', 'colors'},
        {'', 'rotation_knob', 'scale_knob', ''},
        {'frame', 'speed', 'speed_in', 'ping_pong'},
        {'btn_1', 'btn_2', 'btn_3', 'btn_4'},
    },
    start = function(self)
        self._frames = {}
    end,
    restart = function(self)
        self._frames = {}
    end,
    update = function(self, dt)
        Utils.cell_map(self.positions, function(key, position)
            position = position or {x=0, y=0}
            local f = self._frames[key] or 0
            local speed = (self.speed_in[key] or 1) * math.pow((self.speed * 2), 3)
            f = f + dt * speed
            f = f % 1
            self._frames[key] = f
        end, true)
        Utils.cell_trim(self.positions, self._frames)
    end,
    draw = function(self)
        local keys = {}
        local default = true
        for key, position in pairs(self.positions) do
            default = false
            local depth = self.order[key] or position.y
            table.insert(keys, {key, depth})
        end
        table.sort(keys, function(a, b)
            return a[2] < b[2]
        end)
        if default then
            table.insert(keys, {"default", self.positions.default or {x=0, y=0}})
        end
        for i, p in ipairs(keys) do
            local key = p[1]
            local position = self.positions[key] or {x=0, y=0}
            --local r = self.rotations[key] or 0
            local r = (self.rotations[key] or 0) + self.rotation_knob
            local c = self.colors[key] or {1, 1, 1, 1}
            local s = self.scales[key] or .5
            local s = supervert(key, self.scales, self.scale_knob)
            s = math.pow(s, 2) * 4
            local frame = self.frame[key] or self._frames[key] or 0
            local which = buttonToNumber(self.btn_1, self.btn_2, self.btn_3, self.btn_4)
            which = math.min(which, #animations)

            local animation = animations[which]
            local qi = 1 + math.floor(frame * #animation.quads)
            qi = math.min(#animation.quads, math.max(1, qi))
            local quad = animation.quads[qi]
            local image = animation.image

            local sx, sy = Utils.denorm_point(position.x, position.y)
            local sw, sh = animation.width, animation.height
            love.graphics.setColor(c)
            love.graphics.draw(image, quad, sx, sy, r * math.pi * 2, s, s, sw / 2, sh / 2)
        end
        --Utils.cell_map(self.positions, function(key, position)
        --end, false)
        love.graphics.setColor(1, 1, 1, 1)
    end
}

module {
    name = 'debug',
    parts = {
        positions_1 = {'V', 'port', 'vector', 'in'},
        positions_2 = {'V2', 'port', 'vector', 'in'},
        numbers_1 = {'N', 'port', 'number', 'in'},
        numbers_2 = {'N', 'port', 'number', 'in'},
    },
    layout = {
        {'positions_1', 'positions_2'},
        {'numbers_1', 'numbers_2'},
    },
    draw = function(self)
        local offset = 0
        Utils.cell_map(self.positions_1, function(k, p)
            p = p or {x=0, y=0}
            local x, y = Utils.denorm_point(p.x, p.y)
            --local p2 = self.positions_2[k]
            local n1 = self.numbers_1[k]
            local n2 = self.numbers_2[k]
            love.graphics.circle('line', x, y, 10)
            love.graphics.print(k, x, y + offset * 30)
            if n1 then
                love.graphics.print(n1, x, y + 10 + offset * 30)
            end
            if n2 then
                love.graphics.print(n2, x, y + offset * 30)
            end
        end)
    end
}


module {
    name = 'toa',
    parts = {
        target_1 = {'T', 'knob'},
        offset_1 = {'O', 'port', 'number', 'in'},
        attenuvert_1 = {'*', 'knob', default=.75},
        output_1 = {'Out', 'port', 'number', 'out'},
    },
    layout = {
        {'target_1'},
        {'offset_1'},
        {'attenuvert_1'},
        {'output_1'},
    },
    update = function(self, dt)
        Utils.cell_map(self.offset_1, function(key)
            local sv = supervert(key, self.offset_1, self.attenuvert_1)
            local target_width = 1 - math.abs(np1(self.attenuvert_1))
            self.output_1[key] = (self.target_1 * target_width) + sv
        end)
    end
}

module {
    name = 'knobs',
    parts = {
        knob_1 = {'', 'knob'},
        range_1 = {'0-1', 'button', default=true},
        output_1 = {'1', 'port', 'number', 'out'},
        knob_2 = {'', 'knob'},
        range_2 = {'0-1', 'button', default=true},
        output_2 = {'1', 'port', 'number', 'out'},
        knob_3 = {'', 'knob'},
        range_3 = {'0-1', 'button', default=true},
        output_3 = {'1', 'port', 'number', 'out'},
        knob_4 = {'', 'knob'},
        range_4 = {'0-1', 'button', default=true},
        output_4 = {'1', 'port', 'number', 'out'},
    },
    layout = {
        {'knob_1', 'knob_2', 'knob_3', 'knob_4'},
        {'range_1', 'range_2', 'range_3', 'range_4'},
        {'output_1', 'output_2', 'output_3', 'output_4'},
    },
    update = function(self, dt)
        for i=1,4 do
            local v = self['knob_' .. i]
            if not self['range_' .. i] then
                v = v * 2 - 1
            end
            self['output_' .. i].default = v
        end
    end
}

module {
    name = 'vector-?',
    parts = {
        -- Number -> Vector
        x = {'X', 'port', 'number', 'in'},
        y = {'Y', 'port', 'number', 'in'},
        x_attenuvert = {'av', 'knob'},
        y_attenuvert = {'av', 'knob'},
        xy = {'XY', 'port', 'vector', 'out'},
        rl = {'RL', 'port', 'vector', 'out'},
        vec_p1 = {'+1', 'button', default=false},
        -- Vector methods
        v1 = {'V1', 'port', 'vector', 'in'},
        v2 = {'V2', 'port', 'vector', 'in'},
        v1_attenuvert = {'av', 'knob', default=1},
        v2_attenuvert = {'av', 'knob', default=1},
        plus = {'+', 'port', 'vector', 'out'},
        theta = {'Theta', 'port', 'number', 'out'},
        delta = {'Delta', 'port', 'number', 'out'},
        x_out = {'X', 'port', 'number', 'out'},
        y_out = {'Y', 'port', 'number', 'out'},
    },
    layout = {
        {'x', 'y', 'vec_p1', 'v1', 'v2', 'x_out', 'y_out'},
        {'x_attenuvert', 'y_attenuvert', '', 'v1_attenuvert', 'v2_attenuvert', 'theta', 'delta'},
        {'xy', 'rl', '', 'plus', '', ''},
    },
    update = function(self, dt)
        local bonus = {}
        if self.vec_p1 then
            bonus = {[self.id] = true}
        end
        local xy_cells = {}
        for key in Utils.all_keys(self.x, self.y, bonus, {default=true}) do
            xy_cells[key] = true
            local xy = rawget(self.xy, key) or {}
            --local x = np1(self.x[key] or 0) * np1(self.x_attenuvert)
            --local y = np1(self.y[key] or 0) * np1(self.y_attenuvert)
            local x = supervert(key, self.x, self.x_attenuvert, true)
            local y = supervert(key, self.y, self.y_attenuvert, true)
            xy.x = x
            xy.y = y
            self.xy[key] = xy

            local rl = rawget(self.rl, key) or {}
            rl.x = math.cos(z1(x) * math.pi * 2) * z1(y)
            rl.y = math.sin(z1(x) * math.pi * 2) * z1(y)
            self.rl[key] = rl
        end
        Utils.cell_trim(xy_cells, self.xy, {self.rl})

        local v_keys = {}
        for key in Utils.all_keys(self.v1, self.v2) do
            v_keys[key] = true
            local plus = rawget(self.plus, key) or {}
            local v1 = self.v1[key] or {x=0, y=0}
            local v2 = self.v2[key] or {x=0, y=0}
            local v1x = v1.x * np1(self.v1_attenuvert)
            local v1y = v1.y * np1(self.v1_attenuvert)
            local v2x = v2.x * np1(self.v2_attenuvert)
            local v2y = v2.y * np1(self.v2_attenuvert)
            plus.x = v1x + v2x
            plus.y = v1y + v2y
            self.plus[key] = plus

            local dx = v2x - v1x
            local dy = v2y - v1y

            local theta = math.atan2(dy, dx) / math.pi / 2
            self.theta[key] = theta

            local delta = math.sqrt(dx * dx + dy * dy)
            self.delta[key] = delta

            self.x_out[key] = z1(plus.x)
            self.y_out[key] = z1(plus.y)
        end

        Utils.cell_trim(v_keys, self.plus, {self.theta, self.delta, self.x_out, self.y_out})
    end
}

module {
    name = 'vector',
    parts = {
        vector_1 = {'V1', 'port', 'vector', 'in'},
        vector_2 = {'V2', 'port', 'vector', 'in'},
        v2_knob = {'V2*', 'knob'},
        distance = {'D', 'port', 'number', 'out'},
        offset = {'+', 'port', 'vector', 'out'},
    },
    layout = {
        {'vector_1', 'vector_2', 'v2_knob'},
        {'distance', 'offset'},
    },
    update = function(self, dt)
        for key in pairs(self.offset) do
            if not rawget(self.vector_1, key) and not rawget(self.vector_2, key) then
                self.offset[key] = nil
                self.distance[key] = nil
            end
        end
        local seen = {}
        for key in Utils.all_keys(self.vector_1, self.vector_2) do
            seen[key] = true
            local v1 = self.vector_1[key] or {x=0, y=0}
            local v2 = self.vector_2[key] or {x=0, y=0}
            self.offset[key] = rawget(self.offset, key) or {}
            self.offset[key].x = v1.x + v2.x * self.v2_knob
            self.offset[key].y = v1.y + v2.y * self.v2_knob
            local dx, dy = v1.x - v2.x, v1.y - v2.y
            self.distance[key] = math.sqrt(dx * dx + dy * dy)
        end

        Utils.cell_trim(seen, self.distance, {self.offset})
    end
}

module {
    name = 'vector-s',
    parts = {
        r = {'R', 'knob'},
        d = {'D', 'knob'},
        output = {'Out', 'port', 'vector', 'out'},
    },
    layout = {
        {'r','d','output'}
    },
    update = function(self, dt)
        local x = math.cos(self.r * math.pi * 2) * self.d
        local y = math.sin(self.r * math.pi * 2) * self.d
        self.output.default = {x=x, y=y}
        self.output.value = {x=x, y=y}
    end
}

module {
    name = 'associate',
    parts = {
        a = {'A', 'port', '*', 'in'},
        b = {'B', 'port', '*', 'in'},
        output = {'Out', 'port', '*', 'out'},
        --zip_button = {'Zip', 'button'},
        --many_button = {'Many', 'button'},
    },
    layout = {
        {'a', 'b'},
        {'output'}
    },
    start = function(self)
        self._left_associations = {}
        self._right_associations = {}
    end,
    restart = function(self)
        self._left_associations = {}
        self._right_associations = {}
        self._left_key = nil
        self._right_key = nil
    end,
    update = function(self, dt)
        for key in pairs(self.a) do
            if not self._left_associations[key] then
                self._left_associations[key] = self._right_key
                print(self._right_key)
                self._right_key = next(self.b, self._right_key)
            end
            self.output[key] = self.b[self._left_associations[key]]
        end

        Utils.cell_trim(self.a, self._left_associations)

        for key in pairs(self.b) do
            if not self._right_associations[key] then
                self._right_associations[key] = self._left_key
                self._left_key = next(self.a, self._left_key)
            end
            self.output[key] = self.a[self._right_associations[key]]
        end

        Utils.cell_trim(self.b, self._right_associations)
    end
}

module {
    name = 'adsr',
    parts = {
        input = {'In', 'port', 'number', 'in'},
        attack = {'A', 'knob'},
        decay = {'D', 'knob'},
        sustain = {'S', 'knob'},
        release = {'R', 'knob'},
        output = {'Out', 'port', 'number', 'out'}
    },
    layout = {
        {'input'},
        {'attack'},
        {'decay'},
        {'sustain'},
        {'release'},
        {'output'},
    },
    update = function(self, dt)
        self.values = self.values or {}
        self._stages = self._stages or {}
        for key in Utils.all_keys(self.input) do
            local value = self.input[key] or 0
            local output = self.output[key] or 0
            local stage = self._stages[key] or 'attack'
            if value > .5 then
                if stage == 'attack' then
                    output = output + math.pow(self.attack, 2) * 60 * dt
                    if output >= 1 then
                        stage = 'decay'
                        output = 1
                    end
                elseif stage == 'decay' then
                    output = output - math.pow(self.decay, 2) * 60 * dt
                    if output <= self.sustain then
                        output = self.sustain
                        stage = 'sustain'
                    end
                elseif stage == 'sustain' then
                    -- in the case of changing sustain value
                    output = self.sustain
                end
            else -- no on
                output = output - math.pow(self.release, 2) * 60 * dt
                output = math.max(output, 0)
                stage = 'attack'
            end

            self.output[key] = output
            self._stages[key] = stage
        end

        Utils.cell_trim(self.input, self.output, {self._stages})
    end
}

local bullet_iota = 0
local function bullet_fire(self, source_key)
    local v = self.sources[source_key] or {x=0, y=0}
    local bv = {x=v.x, y=v.y}
    self._pools[source_key] = self._pools[source_key] or {}
    local pool = self._pools[source_key]
    local bullet_key = source_key .. "_" .. #pool
    table.insert(pool, bullet_key)
    self.output[bullet_key] = bv
    self.out_dir[bullet_key] = self.direction[source_key] or 0
    self.out_life[bullet_key] = 1.0
end

local function bullet_remove(self, key)
    self.output[key] = nil
    self.out_life[key] = nil
    self.out_dir[key] = nil
end

module {
    name = 'bullets',
    parts = {
        sources = {'V', 'port', 'vector', 'in'},
        direction = {'Dir', 'port', 'number', 'in'},
        fire = {'Fire', 'port', 'number', 'in'},
        rate = {'R8', 'knob'},
        velocity = {'Vel', 'knob'},
        life = {'Life', 'knob'},
        output = {'Ov', 'port', 'vector', 'out'},
        out_life = {'Ol', 'port', 'number', 'out'},
        out_dir = {'Od', 'port', 'number', 'out'}
    },
    layout = {
        {'sources', 'direction', 'fire'},
        {'rate', 'velocity', ''},
        {'life', '', ''},
        {'out_dir', 'out_life', 'output'}
    },
    start = function(self, dt)
        self._pools = {}
        self._r8 = {}
    end,
    restart = function(self, dt)
        self._pools = {}
        self._r8 = {}
    end,
    update = function(self, dt)
        for key, children in pairs(self._pools) do
            if not self.sources[key] then
                for _, child in pairs(children) do
                    bullet_remove(self, child)
                end
                self._pools[key] = nil
            end
        end

        for key in pairs(self.sources) do
            local _r8 = self._r8[key] or 0
            local fire = self.fire[key] or 0
            if fire > .5 and _r8 < 0 then
                bullet_fire(self, key)
                _r8 = 1
            end
            self._r8[key] = _r8 - dt * math.pow(self.rate, 2) * 20
        end

        for key, vector in pairs(self.output) do
            local life = self.out_life[key] or 1.0
            local dir = self.out_dir[key] or 1
            local v = self.velocity
            vector.x = vector.x + math.cos(dir * math.pi * 2) * v * dt
            vector.y = vector.y + math.sin(dir * math.pi * 2) * v * dt

            life = life - ((1 - self.life) * dt)
            self.out_life[key] = life

            if life < 0 then
                bullet_remove(self, key)
            end
        end

        Utils.cell_trim(self.sources, self._r8)
    end
}

local function update_bars(dt, key, values, cooldowns, punch, when, v, v_knob)
    local cooldown = cooldowns[key] or 0
    local when = when[key] or 0
    if (when > .5) then
        local value = values[key] or 1
        local k = math.pow(np1(v_knob), 3)
        local delta = v[key] or 1 * k * 10
        if punch and cooldown <= 0 then
            value = value + delta
            values[key] = value
            cooldowns[key] = 1
        end

        if not punch then
            value = value + delta * dt
            values[key] = value
        end
    end
end

module {
    name = 'bars',
    parts = {
        ids = {'ids', 'port', '*', 'in'},
        init = {'init', 'knob'},
        cd_knob = {'CD', 'knob', default=1},
        one = {'1', 'port', 'number', 'out'},
        punch_1 = {'Punch', 'button'},
        when_1 = {'When', 'port', 'number', 'in'},
        v_1 = {'V', 'port', 'number', 'in'},
        v_knob_1 = {'*', 'knob', default=1},
        punch_2 = {'Punch', 'button'},
        when_2 = {'When', 'port', 'number', 'in'},
        v_2 = {'V', 'port', 'number', 'in'},
        v_knob_2 = {'*', 'knob', default=1},
        punch_3 = {'Punch', 'button'},
        when_3 = {'When', 'port', 'number', 'in'},
        v_3 = {'V', 'port', 'number', 'in'},
        v_knob_3 = {'*', 'knob', default=1},
        value_out = {'V', 'port', 'number', 'out'},
        empty_out = {'MT', 'port', 'number', 'out'},
        full_out = {'FUL', 'port', 'number', 'out'},
        cd_out = {'CD', 'port', 'number', 'out'},
    },
    layout = {
        {'ids', 'init', 'cd_knob', 'one'},
        {'punch_1', 'when_1', 'v_1', 'v_knob_1'},
        {'punch_2', 'when_2', 'v_2', 'v_knob_2'},
        {'punch_3', 'when_3', 'v_3', 'v_knob_3'},
        {'value_out', 'empty_out', 'full_out', 'cd_out'}
    },
    update = function(self, dt)
        self.one.default = 1
        for key in Utils.all_keys(self.ids, {default=true}) do
            if key ~= "default" then
                if not rawget(self.value_out, key) then
                    self.value_out[key] = self.init
                end
            end
            if not self.value_out.default then
                self.value_out.default = self.init
            end

            update_bars(dt, key, self.value_out, self.cd_out, self.punch_1, self.when_1, self.v_1, self.v_knob_1)
            update_bars(dt, key, self.value_out, self.cd_out, self.punch_2, self.when_2, self.v_2, self.v_knob_2)
            update_bars(dt, key, self.value_out, self.cd_out, self.punch_3, self.when_3, self.v_3, self.v_knob_3)

            local cd = (self.cd_out[key] or 0) - dt / (math.pow(math.max(self.cd_knob, .0001), 3) * 10)
            cd = math.max(0, cd)

            local value = self.value_out[key] or .5
            value = math.min(math.max(value, 0), 1)
            self.value_out[key] = value

            self.cd_out[key] = cd
            self.empty_out[key] = value < .01 and 1 or 0
            self.full_out[key] = value > .99 and 1 or 0
        end
    end
}

module {
    name = 'rectangles',
    parts = {
        positions = {'V', 'port', 'vector', 'in'},
        width = {'W', 'port', 'number', 'in'},
        width_knob = {'*', 'knob', default=.5},
        height = {'H', 'port', 'number', 'in'},
        height_knob = {'*', 'knob', default=.5},
        color = {'C', 'port', 'color', 'in'},
        draw_order = {'DO', 'knob'},
        rotation = {'R', 'port', 'number', 'in'},
        rotation_knob = {'*', 'knob'},
        fill_mode = {'fill', 'button'},
    },
    layout = {
        {'draw_order', 'positions', 'color', 'fill_mode'},
        {'width', 'height', 'rotation'},
        {'width_knob', 'height_knob', 'rotation_knob'},
    },
    draw = function(self)
        local ww, wh = love.window.getMode()
        for key, position in pairs(self.positions) do
            --local position = self.positions[key] or {x=0, y=0}
            local x, y = Utils.denorm_point(position.x, position.y)
            local width = supervert(key, self.width, self.width_knob)
            local height = supervert(key, self.height, self.height_knob)
            local rotation = supervert(key, self.rotation, self.rotation_knob)
            local color = self.color[key] or {1,1,1,1}
            local fill = self.fill_mode and 'fill' or 'line'

            local w = width * ww
            local h = height * wh

            love.graphics.push()
                love.graphics.setColor(color[1], color[2], color[3], color[4])
                love.graphics.translate(x, y)
                love.graphics.rotate(rotation * math.pi * 2)
                love.graphics.rectangle(fill, -w/2, -h/2, w, h)
            love.graphics.pop()
        end
    end
}

local midi = {}
local midiChannel = love.thread.getChannel('midi')

src = [[
local socket = require "socket"
local client = socket.tcp()
client:connect("localhost", 9999)
local channel = love.thread.getChannel('midi')
while true do
    line = client:receive("*l")
    if line then
        m = string.gmatch(line, "%d+")
        c = m()
        v = m()
        channel:push({c, v})
    else
        print("Couldn't connect to MIDI server... Did you remember to start it with midi_server.py?")
        break
    end
end
]]
love.thread.newThread(src):start()

local midiParts = {}
for i=1,16 do
    midiParts["p" .. i] = {tostring(i), 'port', 'number', 'out'}
end

module {
    name = 'midi',
    parts = midiParts,
    layout = {
        {'p1', 'p2', 'p3', 'p4'},
        {'p5', 'p6', 'p7', 'p8'},
        {'p9', 'p10', 'p11', 'p12'},
        {'p13', 'p14', 'p15', 'p16'},
    },
    update = function(self, dt)
        for i=1,midiChannel:getCount() do
            local v = midiChannel:pop()
            if v then
                local c = tonumber(v[1]) + 1
                local v = tonumber(v[2])
                print("Setting", c, "to", v)
                midi[c] = v / 127
            end
        end
        for i=1,16 do
            local key = "p" .. i
            self[key].default = midi[i] or 0
        end
    end
}

--[[module {
    name = 'bonkers',
    parts = {
        position = {'V', 'port', 'vector', 'in'},
        radius_knob = {'R', 'knob'},
    }
}]]--

local function copy_table(t)
    if not t then return nil end

    local output = {}
    for key, value in pairs(t) do
        output[key] = value
    end
    return output
end

local STAMPER_SLOTS = {"v1_out", "v2_out", "n1_out", "n2_out", "n3_out", "n4_out", "c1_out", "c2_out"}

module {
    name = 'stamper',
    parts = {
        v1 = {'V1', 'port', 'vector', 'in'},
        v2 = {'V2', 'port', 'vector', 'in'},
        n1 = {'N1', 'port', 'number', 'in'},
        n2 = {'N2', 'port', 'number', 'in'},
        n3 = {'N3', 'port', 'number', 'in'},
        n4 = {'N4', 'port', 'number', 'in'},
        c1 = {'C1', 'port', 'color', 'in'},
        c2 = {'C2', 'port', 'color', 'in'},
        v1_out = {'V1', 'port', 'vector', 'out'},
        v2_out = {'V2', 'port', 'vector', 'out'},
        n1_out = {'N1', 'port', 'number', 'out'},
        n2_out = {'N2', 'port', 'number', 'out'},
        n3_out = {'N3', 'port', 'number', 'out'},
        n4_out = {'N4', 'port', 'number', 'out'},
        c1_out = {'C1', 'port', 'color', 'out'},
        c2_out = {'C2', 'port', 'color', 'out'},
        recording = {'Rec', 'button'},
        reset = {'Reset', 'button', callback="reset"}
    },
    layout = {
        {'v1', 'v2', 'recording', 'v1_out', 'v2_out'},
        {'n1', 'n2', '', 'n1_out', 'n2_out'},
        {'n3', 'n4', '', 'n3_out', 'n4_out'},
        {'c1', 'c2', 'reset', 'c1_out', 'c2_out'},
    },
    start = function(self)
        self.data = {
            values = {},
            iota = 1
        }
    end,
    reset = function(self)
        self.data = {
            values = {},
            iota = 0
        }
        self.iota = 0

        for _, key in pairs(STAMPER_SLOTS) do
            for key2 in pairs(self[key]) do
                self[key][key2] = nil
            end
            self[key].default = nil
        end
    end,
    restart = function(self)
        self.iota = self.data.iota

        if self.data then
            for _, key in pairs(STAMPER_SLOTS) do
                for key2, value in pairs(self.data.values[key] or {}) do
                    self[key][key2] = value
                end
            end
        end
    end,
    update = function(self, dt)
        self.values = self.values or {}
        self.stamping = self.stamping or false
        self.iota = self.iota or 1

        local mx, my = Mouse.getNormPoint()
        local v1 = self.v1[self.iota] or {x=mx, y=my}

        if self.recording and Mouse.isInViewport() and love.mouse.isDown(1) then 
            if not self.stamping and self.recording then
                self.stamping = true
                print("Stamping!")
                self.v1_out[self.iota] = copy_table(v1) or {x=0, y=0}
                self.v2_out[self.iota] = copy_table(self.v2.default) or {x=0, y=0}
                self.n1_out[self.iota] = self.n1.default
                self.n2_out[self.iota] = self.n2.default
                self.n3_out[self.iota] = self.n3.default
                self.n4_out[self.iota] = self.n4.default
                self.c1_out[self.iota] = copy_table(self.c1.default) or {1, 1, 1, 1}
                self.c2_out[self.iota] = copy_table(self.c2.default) or {1, 1, 1, 1}

                for _, key in pairs(STAMPER_SLOTS) do
                    self.data.values[key] = self.data.values[key] or {}
                    self.data.values[key][self.iota] = self[key][self.iota]
                end
                self.iota = self.iota + 1
            end
        else
            self.stamping = false
        end

        self.v1_out.next = v1
        self.v2_out.next = self.v2.default
        self.n1_out.next = self.n1.default
        self.n2_out.next = self.n2.default
        self.n3_out.next = self.n3.default
        self.n4_out.next = self.n4.default
        self.c1_out.next = self.c1.default
        self.c2_out.next = self.c2.default

        self.v1_out.default = v1
        self.v2_out.default = self.v2.default
        self.n1_out.default = self.n1.default
        self.n2_out.default = self.n2.default
        self.n3_out.default = self.n3.default
        self.n4_out.default = self.n4.default
        self.c1_out.default = self.c1.default
        self.c2_out.default = self.c2.default
    end,
    serialize = function(self)
        local values = {}
        for _, key in pairs(STAMPER_SLOTS) do
            if key ~= "next" then
                values[key] = self[key]
                values[key].default = self[key].default
            end
        end
        return {
            values = values,
            iota = self.iota
        }
    end,
    deserialize = function(self, data)
        self.iota = data.iota
        self.data = data
        for _, key in pairs(STAMPER_SLOTS) do
            for key2 in pairs(data.values[key] or {}) do
                self[key][key2] = data.values[key][key2]
            end
        end
    end
}

local TRAIL_MAX_POINTS = 30

module {
    name = "trail",
    parts = {
        positions = {'V', 'port', 'vector', 'in'}, 
        n_points = {'n', 'port', 'number', 'in'},
        n_points_knob = {'*', 'knob'},
        distance = {'d', 'port', 'number', 'in'},
        distance_knob = {'*', 'knob'},
        theta = {'r', 'port', 'number', 'in'},
        theta_knob = {'*', 'knob'},
        delta_distance = {'dd', 'port', 'number', 'in'},
        delta_distance_knob = {'*', 'knob'},
        delta_theta = {'dr', 'port', 'number', 'in'},
        delta_theta_knob = {'*', 'knob'},
        smooth = {'Smooth', 'button'},
        positions_out = {'V', 'port', 'vector', 'out'},
        next_out = {'Next', 'port', 'vector', 'out'},
        n_out = {'n', 'port', 'number', 'out'}
    },
    layout = {
        {'positions', 'smooth', '', '', ''},
        {'n_points', 'distance', 'theta', 'delta_distance', 'delta_theta',},
        {'n_points_knob', 'distance_knob', 'theta_knob', 'delta_distance_knob', 'delta_theta_knob'},
        {'positions_out', 'next_out', 'n_out'}
    },
    update = function(self)
        local function trim_trail(key, n)
            for i=n,TRAIL_MAX_POINTS do
                local point_key = 'trail_' .. key .. '_' .. i
                self.positions_out[point_key] = nil
                self.n_out[point_key] = nil
            end
        end

        local function visit_trails(key)
            local n_float = supervert(key, self.n_points, self.n_points_knob) * TRAIL_MAX_POINTS
            local n = math.floor(n_float)
            local position = self.positions[key] or {x=0, y=0}
            local distance = supervert(key, self.distance, self.distance_knob)
            distance = math.pow(distance, 3) * .25
            local theta = (((self.theta[key] or 0) + self.theta_knob) % 1) * math.pi * 2
            local delta_distance = math.pow(np1(supervert(key, self.delta_distance, self.delta_distance_knob)), 3) * .25
            local delta_theta = supervert(key, self.delta_theta, self.delta_theta_knob, true) * .5

            local previous_position = position

            for i=1,n do
                local point_key = 'trail_' .. key .. '_' .. i
                local out_position = rawget(self.positions_out, point_key) or {}
                local this_distance = distance
                if i == (n - 1) and self.smooth then
                    this_distance = distance * (n_float - n)
                end
                out_position.x = previous_position.x + math.cos(theta) * this_distance
                out_position.y = previous_position.y + math.sin(theta) * this_distance
                self.positions_out[point_key] = out_position
                self.n_out[point_key] = i / n

                previous_position = out_position
                distance = distance + delta_distance
                theta = theta + delta_theta
            end

            trim_trail(key, n)

            for i=1,n do
                local point_key = 'trail_' .. key .. '_' .. i
                local next_point_key = 'trail_' .. key .. '_' .. i + 1
                self.next_out[point_key] = self.positions_out[next_point_key] or self.positions_out[point_key]
            end
        end

        self._position_cache = self._position_cache or {}

        local any = false
        for key, position in pairs(self.positions) do
            any = true
            self._position_cache[key] = true
            visit_trails(key)
        end

        for key, _ in pairs(self._position_cache) do
            if not rawget(self.positions, key) then
                trim_trail(key, 0)
            end
        end

        if not any then
            visit_trails("default")
        else
            trim_trail("default", 0)
        end
    end
}

module {
    name = 'lines',
    parts = {
        starts = {'V1', 'port', 'vector', 'in'},
        ends = {'V2', 'port', 'vector', 'in'},
        thickness = {'Width', 'port', 'number', 'in'},
        thickness_knob = {'*', 'knob', default=.6},
        color = {'C', 'port', 'color', 'in'},
    },
    layout ={
        {'starts', 'ends', 'thickness'},
        {'color', '', 'thickness_knob'}
    },
    draw = function(self)
        local function f(key)
            local startPoint = self.starts[key] or {x=0, y=0}
            local endPoint = self.ends[key] or {x=0, y=0}
            local thickness = math.pow(supervert(key, self.thickness, self.thickness_knob), 2) * 50
            local sx, sy = Utils.denorm_point(startPoint.x, startPoint.y)
            local ex, ey = Utils.denorm_point(endPoint.x, endPoint.y)
            local color = self.color[key] or {1, 1, 1, 1}

            love.graphics.push()
                love.graphics.setColor(color[1], color[2], color[3], color[4])
                love.graphics.setLineWidth(thickness)
                love.graphics.line(sx, sy, ex, ey)
                love.graphics.setLineWidth(1)
            love.graphics.pop()
        end

        local default = true
        for key in Utils.all_keys(self.starts) do
            if key ~= "default" then
                f(key)
                default = false
            end
        end
        if default then
            f("default")
        end
    end
}
