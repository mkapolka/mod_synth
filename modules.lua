local Utils = require "utils"

local function module(template)
    module_types[template.name] = template
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
            local nx, ny = Utils.denorm_point(v.x, v.y)
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
        if not fullscreen then
            local sw, sh = love.graphics.getDimensions()
            mx = (mx - (2 * sw / 3)) * 3
            my = (my - (2 * sh / 3)) * 3
        end
        local nx, ny = Utils.norm_point(mx, my)
        self.position.default.x = nx
        self.position.default.y = ny
        self.position.point.x = nx
        self.position.point.y = ny
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
                local x, y = Utils.denorm_point(v.x, v.y)
                local r = touch_radius(self.a_radii[k], self.a_radii_knob)
                local t = self.touches[k]
                love.graphics.setColor(1, 1-t, 1-t, 1)
                love.graphics.circle('line', x, y, r * NORM_FACTOR)
            end
            for k, v in pairs(self.b_positions) do
                local x, y = Utils.denorm_point(v.x, v.y)
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
        self.offsets = {}
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
            
            self.positions_out[k] = rawget(self.positions_out, k) or {x=0, y=0}
            local pout = self.positions_out[k]
            pout.x = v.x + offset.x
            pout.y = v.y + offset.y
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

        for key in Utils.all_keys(self.a, self.b, self.c) do
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
            local ht = self.hue_target_knob or 1
            local st = self.saturation_target_knob or 1
            local vt = self.value_target_knob or 1
            local at = self.alpha_target_knob or 1
            local h = rawget(self.hue, key) or ht
            local s = rawget(self.saturation, key) or st
            local v = rawget(self.value, key) or vt
            local a = rawget(self.alpha, key) or at
            local hout = (ht * (1 - self.hue_knob)) + (h * self.hue_knob)
            local sout = (st * (1 - self.saturation_knob)) + (s * self.saturation_knob)
            local vout = (vt * (1 - self.value_knob)) + (v * self.value_knob)
            local aout = (at * (1 - self.alpha_knob)) + (a * self.alpha_knob)
            local r, g, b = Utils.hsv(hout, sout,  vout)
            self.output[key] = {r, g, b, aout}
        end
        for key in Utils.all_keys(self.hue, self.saturation, self.value) do
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

module {
    name = 'clear',
    parts = {
        color = {'C', 'port', 'color', 'in'}
    },
    layout = {
        {'color'}
    },
    update = function(self)
        clear_color = self.color.default or {0, 0, 0, 1}
    end
}
