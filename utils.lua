local Utils = {}

function Utils.hsv(h, s, v)
    if s <= 0 then return v,v,v end
    h, s, v = h*6, s, v
    local c = v*s
    local x = (1-math.abs((h%2)-1))*c
    local m,r,g,b = (v-c), 0,0,0
    if h < 1     then r,g,b = c,x,0
    elseif h < 2 then r,g,b = x,c,0
    elseif h < 3 then r,g,b = 0,c,x
    elseif h < 4 then r,g,b = 0,x,c
    elseif h < 5 then r,g,b = x,0,c
    else              r,g,b = c,0,x
    end return (r+m),(g+m),(b+m)
end

function Utils.point_in_rectangle(x, y, rx, ry, rw, rh)
    return x > rx and x < rx + rw and y > ry and y < ry + rh
end

function Utils.norm_point(x, y)
    local w, h = love.window.getMode()
    local n = math.max(w, h)
    if w > h then
        y = y + (w - h) / 2
    else
        x = x + (h - w) / 2
    end
    return x / n * 2 - 1, y / n * 2 - 1
end

function Utils.denorm_point(x, y)
    local w, h = love.window.getMode()
    local n = math.max(w, h)
    local xo = (x / 2 + .5) * n
    local yo = (y / 2 + .5) * n
    if w > h then
        yo = yo - (w - h) / 2
    else
        xo = xo - (w - h) / 2
    end
    return xo, yo
end

-- iterator that returns all the keys in the given collections
-- TODO: Optimize this into a proper iterator
function Utils.all_keys(...)
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

function Utils.cell_trim(pk_cell, out_cell, other_cells)
    for key in pairs(out_cell) do
        if key ~= "default" and not rawget(pk_cell, key) then
            out_cell[key] = nil
            if other_cells then
                for k2, other in pairs(other_cells) do
                    other[key] = nil
                end
            end
        end
    end
end

function Utils.cell_map(pk_cell, f, onDefault)
    for key, value in pairs(pk_cell) do
        f(key, value)
    end
    if onDefault == undefined or onDefault then
        f('default', pk_cell.default)
    end
end

function Utils.remove_element(t, element)
    for i, e in pairs(t) do
        if e == element then
            return table.remove(t, i)
        end
    end
end

return Utils
