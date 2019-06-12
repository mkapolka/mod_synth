local MODE = "normal"

local MOUSE_DOWN = {}
local current_chord = ""
local timer = 0 -- Message timer
local message = ""

local vim = {
    methods = {},
    binds = {}
}

local textinput = {
    prompt = "",
    text = "",
    callback = function()end
}

local awaitclick = {
    prompt = "",
    callback = function()end
}

local function vim_pcall(f, ...)
    ok, result = pcall(f, ...)
    if not ok then
        print(result)
        vim.show_message("ERROR! Check console.")
    end
    return result
end

local function holding_cmd()
    return love.keyboard.isDown("rgui") or love.keyboard.isDown("lgui")
end

local function holding_shift()
    return love.keyboard.isDown("rshift") or love.keyboard.isDown("lshift")
end

local function chord_in_progress()
    local chord = current_chord
    if chord ~= "" then
        local binds = vim.binds[MODE] or {}
        for key, _ in pairs(binds) do
            if key:sub(1,#chord) == chord then
                return true
            end
        end
    end
end

local function count_in_progress()
    return string.match(current_chord, "^%d+$")
end

local function keydown_normal(key)
    --[[if key == "s" then
        -- cmd-s
        if holding_cmd() then
            vim.methods.save()
        end
    end]]--
end

local function key_valid(key)
    -- Alphanumeric, punctuation, or spaces
    return string.find(key, "^%w$") or string.find(key, "^%p$") or string.find(key, "^%s$")
end

local function keydown_textinput(key, text)
    if text and key_valid(text) then
        textinput.text = textinput.text .. text
        return
    end

    if key == "return" then
        MODE = "normal"
        vim_pcall(textinput.callback, textinput.text)
    end

    if key == "backspace" then
        if holding_shift() then
            textinput.text = ""
        else
            textinput.text = string.sub(textinput.text, 1, #textinput.text - 1)
        end
    end
end

local kd = nil
local ti = nil
local rep = 1

function vim.keydown(key)
    kd = key
end

function vim.textinput(text)
    ti = text
end

local function do_key(key, text)
    if key == "lshift" or key == "rshift" then
        return
    end

    if key == "escape" then
        current_chord = ""
    end

    -- Repeats
    if text and not string.match(text, "%d") and string.match(current_chord, "^%d+$") then
        rep = tonumber(current_chord) 
        current_chord = ""
    end

    -- Check for chords
    current_chord = current_chord .. (text or key)
    if not chord_in_progress() and not count_in_progress() then
        current_chord = ""
        rep = 1
    else
        local binds = vim.binds[MODE] or {}
        if binds[current_chord] then
            for i=1,rep do
                vim_pcall(binds[current_chord])
            end
            rep = 1
            current_chord = ""
            return
        end
    end

    if key == "escape" then
        current_chord = ""
        MODE = "normal"
        return
    end

    if MODE == "normal" then
        keydown_normal(text or key)
    elseif MODE == "textinput" and key then
        keydown_textinput(key, text)
    end
end

function vim.update()
    if kd or ti then
        do_key(kd, ti)
    end
    ti = nil
    kd = nil

end

function vim.mousepressed(x, y, which)
    if which == 1 and MODE == "awaitclick" then
        MODE = "normal"
        vim_pcall(awaitclick.callback, love.mouse:getPosition())
    end
end

function draw_text(text, layer)
    local font = love.graphics.getFont()
    local height = font:getHeight() * layer
    local width = font:getWidth(text)
    love.graphics.setColor(0, 0, 0, 1)
    love.graphics.rectangle("fill", 0, love.graphics.getHeight() - height, width, height)
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.print(text, 0, love.graphics.getHeight() - height)
end

function vim.draw()
    local layer = 1
    if MODE == "textinput" then
        draw_text(textinput.prompt .. textinput.text, layer)
        layer = layer + 1
    elseif MODE == "awaitclick" then
        draw_text(awaitclick.prompt, layer)
        layer = layer + 1
    else
        if chord_in_progress() or count_in_progress() then
            draw_text(current_chord, layer)
            layer = layer + 1
        end
    end

    if message ~= "" and (love.timer.getTime() - timer) < 1 then
        draw_text(message, layer)
        layer = layer + 1
    end
end

function vim.bind(mode, chord, callback)
    vim.binds[mode] = vim.binds[mode] or {}
    vim.binds[mode][chord] = callback
end

function vim.enter_textinput(prompt, initial, callback)
    MODE = "textinput"
    textinput.prompt = prompt
    textinput.text = initial
    textinput.callback = callback
end

function vim.enter_awaitclick(prompt, callback)
    MODE = "awaitclick"
    awaitclick.callback = callback
    awaitclick.prompt = prompt
end

function vim.show_message(m)
    message = m
    timer = love.timer.getTime()
end

local function post_hook(pre, f)
    return function(...)
        (pre or function()end)(...)
        f(...)
    end
end

function vim.init()
    love.update = post_hook(love.update, vim.update)
    love.keypressed = post_hook(love.keypressed, vim.keydown)
    love.textinput = post_hook(love.textinput, vim.textinput)
    love.mousepressed = post_hook(love.mousepressed, vim.mousepressed)
    love.draw = post_hook(love.draw, vim.draw)
end

return vim
