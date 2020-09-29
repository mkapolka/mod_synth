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

module_types = {}
local MODULES = {}
local EDGES = {}

local GRAB_MODE = false

local _CLICK_ID = 0

local CLICKING_PORT = nil
local CLICK_X, CLICK_Y = nil, nil
local HOLDING_KNOB = nil
-- other ports that I'm connected to
local HOLDING_CONNECTIONS = {}

-- Initialized in love.load
local SCREEN = nil
SLACK = 30

FULLSCREEN = false
local PLAYING = true
CLEAR_COLOR = {0, 0, 0, 1}

local SAVE_SLOT = 0

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
        local module = MODULES[part_id[1]]
        return module.parts[part_id[2]]
    end
    return nil
end

local function reify_pid(part_id)
    local module = MODULES[part_id[1]]
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
    end

    if part_type == 'knob' then
        output.value = part.default or .5
    end

    if part_type == 'button' then
        output.value = part.default or false
    end

    return output
end

local function module_cell_dimensions(module)
    local t = module_types[module.module_type]
    return #module.layout[1] + 1, #module.layout + 1
end

local function modules_overlap(x, y, w, h, m2)
    local x1, x2, y1, y2 = x, m2.x, y, m2.y
    local w1, h1, w2, h2 = w, h, module_cell_dimensions(m2)
    local lrx1 = x1 + w1
    local lry1 = y1 + h1
    local lrx2 = x2 + w2
    local lry2 = y2 + h2
    if lrx1 <= x2 or lrx2 <= x1 then
        return false
    end

    if lry1 <= y2 or lry2 <= y1 then
        return false
    end

    return true
end

local function can_place_module_at(x, y, w, h)
    local lrx = x + w
    local lry = y + h
    for _, module in pairs(MODULES) do
        if not module.uprooted and modules_overlap(x, y, w, h, module) then
            return false
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

local function uproot_module(module)
    module.uprooted = true
end

local function place_module(module, x, y)
    module.x = x
    module.y = y
    module.uprooted = nil
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
        MODULES[id] = template
        template.id = id
    else
        table.insert(MODULES, template)
        template.id = #MODULES
    end
    return template
end

local function update_target(module)
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
end

local function visit_module(module, method, ...)
    if module[method] then
        update_target(module)
        local target = module.target
        ok, err = pcall(module[method], target, ...)
        if not ok then
            print("ERROR CALLING " .. method .. ": " .. err)
            print(debug.traceback())
            module.erroring = true
        else
            module.erroring = false
        end
    end
end

local function reset_module(module)
    module.target = {}

    for key, v in pairs(module.parts) do
        if v.part_type == 'port' then
            for k, _ in pairs(v.cell) do
                v.cell[k] = nil
            end
            v.cell.default = nil
        end
    end

    visit_module(module, "restart")
end

local function delete_module(module_id)
    visit_module(MODULES[module_id], 'delete')
    uproot_module(MODULES[module_id])
    MODULES[module_id] = nil
    local edges_to_remove = {}
    for i=1,#EDGES do
        local edge = EDGES[i]
        if edge[1][1] == module_id or edge[2][1] == module_id then
            table.insert(edges_to_remove, i)
        end
    end
    for i=#edges_to_remove,1,-1 do
        table.remove(EDGES, edges_to_remove[i])
    end

    if CLICKING_PORT and CLICKING_PORT[1] == module_id then
        CLICKING_PORT = nil
    end

    for i=#HOLDING_CONNECTIONS,1,-1 do
        if HOLDING_CONNECTIONS[i][1] == module_id then
            table.remove(HOLDING_CONNECTIONS, i)
        end
    end
end

local function clear_modules()
    for key in pairs(MODULES) do
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
    if CLICKING_PORT then
        local clicking = get_part(CLICKING_PORT)
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
    local t = (math.pi / 2 + math.pi / 10) + knob.value * (math.pi * 1.8)
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
    for i=1,#EDGES do
        local conn = EDGES[i]
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
    for i=1,#EDGES do
        local e = EDGES[i]
        if (part_keys_equal(e[1], pid1) and part_keys_equal(e[2], pid2)) or 
           (part_keys_equal(e[1], pid2) and part_keys_equal(e[2], pid1)) then
            return i
        end
    end
end

local function disconnect(pid1, pid2)
    local cid = get_connection_id(pid1, pid2)
    if cid then
        table.remove(EDGES, cid)
    end
end

local function disconnect_all(pid)
    local to_remove = {}
    for i=1,#EDGES do
        local e = EDGES[i]
        if part_keys_equal(e[1], pid) or part_keys_equal(e[2], pid) then
            table.insert(to_remove, i)
        end
    end

    for i=#to_remove,1,-1 do
        table.remove(EDGES, to_remove[i])
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

        table.insert(EDGES, connection)
    end
end

local function get_hovering_module_id()
    local mouse_x, mouse_y = love.mouse.getPosition()
    for key, module in pairs(MODULES) do
        local mx, my, mw, mh = module_dimensions(module)
        if Utils.point_in_rectangle(mouse_x, mouse_y, mx, my, mw, mh) then
            return key
        end
    end
end

local function get_hovering_module()
    local module_id = get_hovering_module_id()
    if module_id then
        return MODULES[module_id]
    end
end

-- return {mod_id, part_id}, part_type
local function get_hovering_part_id()
    local x, y = love.mouse.getPosition()
    local mp = {x=x, y=y}
    for module_id, module in pairs(MODULES) do
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
    for _, m in pairs(MODULES) do
        for key, part in pairs(m.parts) do
            if part.part_type == 'port' then
                part.cell = part.own_cell
            end
        end
    end

    for i=1,#EDGES do
        local edge = EDGES[i]
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

local function write_save(slot)
    local data = {
        modules = {},
        edges = {},
    }

    for key, module in pairs(MODULES) do
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

        if module.serialize then
            ok, err = pcall(module.serialize, module.target)
            if not ok then
                print("ERROR SERIALIZING " .. module.module_type .. ": " .. err)
            else
                out_module.data = err
            end
        end

        data.modules[key] = out_module
    end

    for i=1,#EDGES do
        local edge = EDGES[i]
        table.insert(data.edges, {edge[1], edge[2]})
    end

    love.filesystem.write(get_save_file(slot), binser.serialize(data))
end

local function load_save(which)
    clear_modules()
    local saveString = love.filesystem.read(get_save_file(which))

    if saveString then
        local data = binser.deserialize(saveString)[1]

        for key, module in pairs(data.modules) do
            local template = module_types[module.module_type]
            if template then
                rack(module.module_type, module.x, module.y, key)

                if module.parts then
                    local in_module = MODULES[key]
                    for key, value in pairs(module.parts) do
                        if template.parts[key] then
                            if in_module.parts[key] then
                                in_module.parts[key].value = value
                            end
                        end
                    end
                end
            end
        end

        for _, edge in pairs(data.edges) do
            local pid1, pid2 = edge[1], edge[2]
            local mid1, key1 = pid1[1], pid1[2]
            local mid2, key2 = pid2[1], pid2[2]

            if MODULES[mid1] and MODULES[mid2] and MODULES[mid1].parts[key1] and MODULES[mid2].parts[key2] then
                table.insert(EDGES, edge)
                update_bezier(edge)
            else
                print("Culling missing edge: ", mid1, key1, mid2, key2)
            end
        end
        update_ports()

        for key, module in pairs(MODULES) do
            update_target(module)
            visit_module(module, 'start')

            local payload = data.modules[key].data
            if module.deserialize and payload then
                ok, err = pcall(module.deserialize, module.target, payload)
                if not ok then
                    print("ERROR DESERIALIZING " .. module.module_type .. ": " .. err)
                end
            end
        end
    end
end

local function clear_edges()
    EDGES = {}
    update_ports()
    vim.show_message("Patches cleared.")
end

local function clear_modules()
    MODULES = {}
    EDGES = {}
    update_ports()
    vim.show_message("Modules cleared.")
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
        write_save(SAVE_SLOT)
        vim.show_message("Slot " .. SAVE_SLOT .. " saved.")
    end)

    vim.bind("normal", "f", function()
        FULLSCREEN = not FULLSCREEN
    end)

    vim.bind("normal", " ", function()
        PLAYING = not PLAYING
    end)

    vim.bind("normal", "d", function()
        FULLSCREEN = false
        vim.enter_awaitclick("Delete which module?", function(x, y)
            local module_id = get_hovering_module_id()
            if module_id then
                delete_module(module_id)
                update_ports()
            end
        end)
    end)

    vim.bind("normal", "r", function()
        for _, module in pairs(MODULES) do
            reset_module(module)
        end
    end)

    vim.bind("normal", "g", function()
        GRAB_MODE = not GRAB_MODE
        if GRAB_MODE then
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
            SAVE_SLOT = which
            load_save(SAVE_SLOT)
            vim.show_message("Rack " .. which .. " loaded.")
        end
    end

    local function save_slot(which)
        return function()
            SAVE_SLOT = which
            write_save(SAVE_SLOT)
            vim.show_message("Rack " .. which .. " saved.")
        end
    end

    vim.bind("normal", "cp", clear_edges)
    vim.bind("normal", "cm", clear_modules)

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
    love.window.setMode(1024, 768, {
        resizable=true
    })

    local ww, wh = love.graphics.getDimensions()
    GRID_WIDTH = math.floor(ww / CELL_WIDTH)
    GRID_HEIGHT = math.floor(wh / CELL_HEIGHT)

    SCREEN = love.graphics.newCanvas()

    load_save(SAVE_SLOT)
end

function love.resize(w, h)
    SCREEN:release()
    SCREEN = love.graphics.newCanvas(w, h)
end

function love.update(dt)
    if PLAYING then
        for _, module in pairs(MODULES) do
            visit_module(module, 'update', dt)
        end
    end

    if HOLDING_KNOB then
        local mx = love.mouse.getX()
        local dx = mx - CLICK_X
        HOLDING_KNOB.value = math.min(1, math.max(0, HOLDING_KNOB.value + (dx / 100)))
        CLICK_X = mx
    end
end

function love.draw(dt)
    if not FULLSCREEN then
        for key, module in pairs(MODULES) do
            if module.erroring then
                love.graphics.setColor(1, 0, 0, 1)
            else
                love.graphics.setColor(1, 1, 1, 1)
            end

            local mx, my, mw, mh = module_dimensions(module)
            love.graphics.print(module.name, mx + 5, my + 5)
            love.graphics.rectangle('line', mx, my, mw, mh)

            love.graphics.setColor(1, 1, 1, 1)
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
        love.graphics.setColor(1, 1, 1, 1)

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

        if CLICKING_PORT then
            local mx, my = love.mouse.getPosition()
            for i=1,#HOLDING_CONNECTIONS do
                local hcid = HOLDING_CONNECTIONS[i]
                local module = MODULES[hcid[1]]
                local port = module.parts[hcid[2]]
                local px, py = part_screen_position(module, port)
                love.graphics.line(mx, my, px, py)
            end
        end

        local sw, sh = love.graphics.getDimensions()
        love.graphics.rectangle('line', sw - (sw / 3), sh - (sh / 3), sw / 3, sh / 3)
        love.graphics.draw(SCREEN, sw - (sw / 3), sh - (sh / 3), 0, 1/3, 1/3)

        love.graphics.setCanvas(SCREEN)
    else -- FULLSCREEN
        local sw, sh = love.graphics.getDimensions()
        love.graphics.rectangle('line', 0, 0, sw, sh)
    end

    love.graphics.clear(CLEAR_COLOR)

    local draw_modules = {}
    local i = 1
    for key, value in pairs(MODULES) do
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
    if PLAYING then
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
    local key = 'click_' .. _CLICK_ID
    _CLICK_ID = _CLICK_ID + 1
    mclicks.default = mclicks.default or {}
    mclicks.default.x = x
    mclicks.default.y = y
    mclicks[key] = {x=x, y=y}
end

function love.mousepressed(x, y, which)
    if GRAB_MODE then
        local module = get_hovering_module()
        if module then
            holding_module = module
            uproot_module(module)
        end
    elseif which == 1 then
        if FULLSCREEN then
            local mx, my = love.mouse.getPosition()
            add_click(Utils.norm_point(mx, my))
        else
            clicking, clicking_type = get_hovering_part_id()

            if clicking_type == 'port' then
                -- immediatly disconnect
                CLICKING_PORT = clicking
                local port = get_part(clicking)
                HOLDING_CONNECTIONS = {}
                for i=1,#EDGES do
                    local edge = EDGES[i]
                    if part_keys_equal(edge[1], clicking) then
                        table.insert(HOLDING_CONNECTIONS, edge[2])
                    end

                    if part_keys_equal(edge[2], clicking) then
                        table.insert(HOLDING_CONNECTIONS, edge[1])
                    end
                end

                disconnect_all(clicking)
                update_ports()

                if #HOLDING_CONNECTIONS == 0 then
                    table.insert(HOLDING_CONNECTIONS, clicking)
                else
                    CLICKING_PORT = HOLDING_CONNECTIONS[1]
                end
            elseif clicking_type == 'button' then
                local button = get_part(clicking)
                button.value = not button.value
            elseif clicking_type == 'knob' then
                local knob = get_part(clicking)
                HOLDING_KNOB = knob
                CLICK_X, CLICK_Y = x, y
            else
                local sw, sh = love.graphics.getDimensions()
                local mx, my = love.mouse.getPosition()
                if not FULLSCREEN then
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
            for _, edge in pairs(EDGES) do
                if edge[1][1] == holding_module.id or edge[2][1] == holding_module.id then
                    update_bezier(edge)
                end
            end
        end
        holding_module = nil
    elseif HOLDING_KNOB then
        HOLDING_KNOB = nil
    else
        local hovering_pid = get_hovering_part_id()
        local hovering_part = get_part(hovering_pid)
        if hovering_part and hovering_part.part_type == 'port' and CLICKING_PORT then
            hovering_part = get_part(hovering_pid) or {}
            local clicking = get_part(CLICKING_PORT)
            local type1, type2 = hovering_part.type, clicking.type
            if types_match(type1, type2) and hovering_part.output ~= clicking.output then
                for i=1,#HOLDING_CONNECTIONS do
                    connect(hovering_pid, HOLDING_CONNECTIONS[i])
                end
                update_ports()
            end
        end
    end

    CLICKING_PORT = nil
end

function love.wheelmoved(x, y)
    local knob = get_hovering_knob()
    if knob then
        knob.value = math.min(math.max(knob.value + (y / 20), 0), 1)
    end
end
