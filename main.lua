local Utils = require "utils"
local vim = require "vim"
local binser = require "binser"

PORT_RADIUS = 10
KNOB_RADIUS = 8
BUTTON_RADIUS = 9

CELL_WIDTH = 35
CELL_HEIGHT = 40
GRID_WIDTH = 0 -- filled in in load
GRID_HEIGHT = 0 -- filled in in load
GRID = {}

module_types = {}
local modules = {}
local ports = {}
local knobs = {}
local buttons = {}
local edges = {}
local cells = {}

local grab_mode = false

local _click_id = 0

local clicking_port = nil
local click_x, click_y = nil, nil
local holding_knob = nil
local removing = false
-- other ports that I'm connected to
local holding_connections = {}

-- Initialized in love.load
local screen = nil
NORM_FACTOR = 600
SLACK = 30

fullscreen = false
local playing = true
clear_color = {0, 0, 0, 1}

local save_slot = 0

local function types_match(t1, t2)
    return t1 == t2 or t1 == '*' or t2 == '*'
end

local function Cell(default)
    local output = setmetatable({}, {
        __index = function(self, key)
            return default
        end,
        __newindex = function(self, key, value)
            if key == 'default' then
                default = value
            else
                rawset(self, key, value)
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

local CLICKS = Cell()

local function get_cells(...)
    local output = {}
    for k, v in pairs({...}) do
        output[k] = v.cell
    end
    return unpack(output)
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

local function rack(name, mx, my, id)
    if not module_types[name] then
        error("No such module: " .. tostring(name))
    end
    local t = module_types[name]

    local template = {
        module_type = name
    }
    -- Clone the template
    for k, v in pairs(t) do
        template[k] = t[k]
    end

    if not mx then
        local mw, mh = #template.layout[1] + 1, #template.layout + 1
        mx, my = find_module_place(mw, mh)
    end

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
    if id then
        modules[id] = template
        template.id = id
    else
        table.insert(modules, template)
        template.id = #modules
    end
    return template
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

local function delete_module(module_id)
    visit_module(modules[module_id], 'delete')
    uproot_module(modules[module_id])
    modules[module_id] = nil
    local edges_to_remove = {}
    for i=1,#edges do
        local edge = edges[i]
        if edge[1][1] == module_id or edge[2][1] == module_id then
            table.insert(edges_to_remove, i)
        end
    end
    for i=#edges_to_remove,1,-1 do
        print("removing edge", edges_to_remove[i])
        table.remove(edges, edges_to_remove[i])
    end

    if clicking_port and clicking_port[1] == module_id then
        clicking_port = nil
    end

    for i=#holding_connections,1,-1 do
        if holding_connections[i][1] == module_id then
            table.remove(holding_connections, i)
        end
    end
end

local function clear_modules()
    for key in pairs(modules) do
        delete_module(key)
    end
end

require "modules"

mclicks = Cell()

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
        love.graphics.setColor(Utils.hsv(d / 800, .5, 1))
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

local function get_save_file(slot)
    return "save" .. slot
end

local function writeSave(slot)
    local data = {
        modules = {},
        edges = {},
    }

    for key, module in pairs(modules) do
        local out_module = {
            module_type = module.module_type,
            x = module.x,
            y = module.y,
            parts = {}
        }

        for name, part in pairs(module.parts) do
            if part.part_type == 'knob' or part.part_type == 'button' then
                out_module.parts[name] = part.value
            end
        end

        data.modules[key] = out_module
    end

    for i=1,#edges do
        local edge = edges[i]
        table.insert(data.edges, {edge[1], edge[2]})
    end

    love.filesystem.write(get_save_file(slot), binser.serialize(data))
end

local function loadSave(which)
    clear_modules()
    local saveString = love.filesystem.read(get_save_file(which))

    if saveString then
        local data = binser.deserialize(saveString)[1]

        for key, module in pairs(data.modules) do
            rack(module.module_type, module.x, module.y, key)

            if module.parts then
                local in_module = modules[key]
                for key, value in pairs(module.parts) do
                    if in_module.parts[key] then
                        in_module.parts[key].value = value
                    end
                end
            end

        end

        for _, edge in pairs(data.edges) do
            table.insert(edges, edge)
            update_bezier(edge)
        end
        update_ports()

        for key, module in pairs(modules) do
            visit_module(module, 'start')
        end
    end
end

local function clear_edges()
    edges = {}
    update_ports()
    vim.show_message("Patches cleared.")
end

local function setup_vim_binds()
    vim.init()
    vim.bind("normal", "a", function()
        vim.enter_textinput("Module name?", "", function(name)
            if module_types[name] then
                local module = rack(name)
                visit_module(module, 'start')
            else
                vim.show_message("No such module: " .. name)
            end
        end)
    end)

    vim.bind("normal", "S", function()
        writeSave(save_slot)
        vim.show_message("Slot " .. save_slot .. " saved.")
    end)

    vim.bind("normal", "f", function()
        fullscreen = not fullscreen
    end)

    vim.bind("normal", " ", function()
        playing = not playing
    end)

    vim.bind("normal", "d", function()
        fullscreen = false
        vim.enter_awaitclick("Delete which module?", function(x, y)
            local module_id = get_hovering_module_id()
            if module_id then
                delete_module(module_id)
                update_ports()
            end
        end)
    end)

    vim.bind("normal", "r", function()
        for k, v in pairs(cells) do
            for k2 in pairs(v) do
                v[k2] = nil
            end
        end
        for _, module in pairs(modules) do
            visit_module(module, 'restart')
        end
    end)

    vim.bind("normal", "g", function()
        grab_mode = not grab_mode
        if grab_mode then
            vim.show_message("Grab mode ENABLED")
            love.mouse.setCursor(love.mouse.getSystemCursor('hand'))
        else
            love.mouse.setCursor(love.mouse.getSystemCursor('arrow'))
            holding_module = nil
            vim.show_message("Grab mode DISABLED")
        end
    end)

    local function load_slot(which)
        return function()
            save_slot = which
            loadSave(save_slot)
            vim.show_message("Rack " .. which .. " loaded.")
        end
    end

    local function save_slot(which)
        return function()
            save_slot = which
            writeSave(save_slot)
            vim.show_message("Rack " .. which .. " saved.")
        end
    end

    vim.bind("normal", "cp", clear_edges)

    vim.bind("normal", "l0", load_slot(0))
    vim.bind("normal", "l1", load_slot(1))
    vim.bind("normal", "l2", load_slot(2))
    vim.bind("normal", "l3", load_slot(3))
    vim.bind("normal", "l4", load_slot(4))
    vim.bind("normal", "l5", load_slot(5))
    vim.bind("normal", "l6", load_slot(6))
    vim.bind("normal", "l7", load_slot(7))
    vim.bind("normal", "l8", load_slot(8))
    vim.bind("normal", "l9", load_slot(9))

    vim.bind("normal", "s0", save_slot(0))
    vim.bind("normal", "s1", save_slot(1))
    vim.bind("normal", "s2", save_slot(2))
    vim.bind("normal", "s3", save_slot(3))
    vim.bind("normal", "s4", save_slot(4))
    vim.bind("normal", "s5", save_slot(5))
    vim.bind("normal", "s6", save_slot(6))
    vim.bind("normal", "s7", save_slot(7))
    vim.bind("normal", "s8", save_slot(8))
    vim.bind("normal", "s9", save_slot(9))
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

    loadSave(save_slot)
end

function love.update(dt)
    if playing then
        for _, module in pairs(modules) do
            visit_module(module, 'update', dt)
        end
    end

    if holding_knob then
        local mx = love.mouse.getX()
        local dx = mx - click_x
        holding_knob.value = math.min(1, math.max(0, holding_knob.value + (dx / 100)))
        click_x = mx
    end
end

function love.draw(dt)
    if not fullscreen then
        for key, module in pairs(modules) do
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
    else -- fullscreen
        local sw, sh = love.graphics.getDimensions()
        love.graphics.rectangle('line', 0, 0, sw, sh)
    end

    love.graphics.clear(clear_color)

    local draw_modules = {}
    local i = 1
    for key, value in pairs(modules) do
        if value.draw then
            draw_modules[i] = value
            i = i + 1
        end
    end

    table.sort(draw_modules, function(m1, m2)
        local o1 = .5
        local o2 = .5
        local do_knob = m1.parts.draw_order
        if do_knob then
            o1 = do_knob.value
        end
        local do_knob = m2.parts.draw_order
        if do_knob then
            o2 = do_knob.value
        end
        return o1 < o2
    end)

    for key, module in pairs(draw_modules) do
        visit_module(module, 'draw')
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


local function add_click(x, y)
    local key = 'click_' .. _click_id
    _click_id = _click_id + 1
    mclicks.default = mclicks.default or {}
    mclicks.default.x = x
    mclicks.default.y = y
    mclicks[key] = {x=x, y=y}
end

function love.mousepressed(x, y, which)
    if grab_mode then
        local module = get_hovering_module()
        if module then
            holding_module = module
            uproot_module(module)
        end
    elseif which == 1 then
        if fullscreen then
            local mx, my = love.mouse.getPosition()
            add_click(Utils.norm_point(mx, my))
        else
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
            elseif clicking_type == 'knob' then
                local knob = get_part(clicking)
                holding_knob = knob
                click_x, click_y = x, y
            else
                local sw, sh = love.graphics.getDimensions()
                local mx, my = love.mouse.getPosition()
                if not fullscreen then
                    mx = (mx - (2 * sw / 3)) * 3
                    my = (my - (2 * sh / 3)) * 3
                end

                local x2, y2 = Utils.norm_point(mx, my)
                add_click(x2, y2)
            end
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
    elseif holding_knob then
        holding_knob = nil
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
