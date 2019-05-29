
local function associate(primary, ...)
    local f, i, s = pairs(primary)

    local fallbacks = {}
    local collections = {...}

    for i, collection in ipairs(collections) do
        local _, v = next(collection)
        fallbacks[i] = v
    end


    return function(invariant, idx)
        local idx, next_p = f(invariant, idx)
        local rest = {}
        for i, collection in ipairs(collections) do
            if collection[idx] then
                rest[i] = collection[idx]
            else
                rest[i] = fallbacks[i]
            end
        end
        return idx, next_p, unpack(rest)
    end, primary, nil
end

