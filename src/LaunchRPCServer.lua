-- src/LaunchRPCServer.lua
local socket  = require("socket")
local dkjson  = require("dkjson")

-- Try a few candidate ports until one binds
local function bindPort(start, count)
    for p = start, start + count - 1 do
        local srv, err = socket.bind("*", p)
        if srv then return srv, p end
    end
    error("LaunchRPCServer: could not bind to any port")
end

local server, port = bindPort(49090, 5)
server:settimeout(0)  -- non‐blocking

print(("RPC server listening on http://localhost:%d"):format(port))

-- helpers
local function urlDecode(s)
    return s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h,16)) end)
end

local function parseQuery(qs)
    local t = {}
    for k,v in qs:gmatch("([^&=?]+)=([^&=?]+)") do
        t[k] = urlDecode(v)
    end
    return t
end

function convert_formatted_text(input_table)
    local output_lines = {}
    local current_block = nil

    for _, element in ipairs(input_table) do
        local block = element.block
        local text = element.text

        -- Check for block change to add a separator
        if block ~= current_block and block ~= nil then
            if current_block ~= nil then -- Avoid adding an empty line before the first block
                table.insert(output_lines, "")
            end
            current_block = block
        end

        -- Process text if it exists
        if text then
            table.insert(output_lines, text)
        end
    end

    return output_lines
end

  
-- your core RPC loop; call from Launch:OnInit or similar
local function rpcLoop()
    local client = server:accept()
    if not client then return end
    client:settimeout(5)
    local req = client:receive("*l")
    if not req then client:close() return end

    local method,path = req:match("^(%S+)%s(%S+)")
    if method ~= "GET" or not path:match("^/calculate_item") then
        client:send("HTTP/1.1 404 Not Found\r\n\r\n")
        client:close()
        return
    end

    -- Extract the main build object to work off of
    local build = main.modes["BUILD"]
    if not build then
        -- no build loaded yet
        return
    end

    -- Extract an item from the item query params (?item=<encoded text>)
    local qs = path:match("%?(.*)$") or ""
    local params = parseQuery(qs)
    local itemText = params.item or ""
    local item = new("Item", itemText)
    local tooltip = new("Tooltip")

    -- Reuse the tooltip method from the itemsTab to get the results.
    build.itemsTab:AddItemTooltip(tooltip, item)

    local output_structure = convert_formatted_text(tooltip.lines)

    local jsonOut = dkjson.encode(output_structure, {indent = true})
    client:send(table.concat{
        "HTTP/1.1 200 OK\r\n",
        "Content-Type: application/json\r\n",
        "Access-Control-Allow-Origin: http://localhost:5173\r\n",
        "\r\n",
        jsonOut
    })
    client:close()
end

-- expose to the rest of the app
return {
    Tick = rpcLoop
}