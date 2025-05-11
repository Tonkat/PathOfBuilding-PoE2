-- src/LaunchRPCServer.lua
local socket  = require("socket")
local dkjson  = require("dkjson")

-- Security configuration
local config = {
    -- Only accept connections from localhost
    host = "127.0.0.1",
    -- Generate a random token on startup for simple authentication
    -- This token must be passed in HTTP requests via "Authorization: Bearer <token>" header
    -- or as a query parameter "?token=<token>"
    authToken = tostring(math.random(100000, 999999)),
    -- Rate limiting: max requests per window
    maxRequestsPerWindow = 60,
    -- Rate limiting: time window in seconds
    timeWindow = 60,
}

-- Rate limiting state
local rateLimit = {
    requestCount = 0,
    windowStart = os.time()
}

-- Try a few candidate ports until one binds
local function bindPort(start, count)
    for p = start, start + count - 1 do
        local srv, err = socket.bind(config.host, p)
        if srv then return srv, p end
    end
    error("LaunchRPCServer: could not bind to any port")
end

local server, port = bindPort(49090, 5)
server:settimeout(0)  -- non‐blocking

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

local function checkRateLimit()
    local now = os.time()
    
    -- Reset counter if we're in a new time window
    if now - rateLimit.windowStart > config.timeWindow then
        rateLimit.requestCount = 0
        rateLimit.windowStart = now
    end
    
    -- Increment the counter
    rateLimit.requestCount = rateLimit.requestCount + 1
    
    -- Return false if rate limit exceeded
    return rateLimit.requestCount <= config.maxRequestsPerWindow
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
    
    -- Rate limiting check
    if not checkRateLimit() then
        client:send("HTTP/1.1 429 Too Many Requests\r\nContent-Length: 0\r\n\r\n")
        client:close()
        return
    end
    
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
    
    -- Add checks around 'new' if it can fail
    local success, item = pcall(function() return new and new("Item", itemText) end)
    if not success or not item then
         client:send("HTTP/1.1 400 Bad Request\r\nContent-Type: text/plain\r\nConnection: close\r\n\r\nInvalid item data provided.\r\n")
         client:close()
         return
    end

    local tooltip = new and new("Tooltip")
    local success, err_or_result = pcall(build.itemsTab.AddItemTooltip, build.itemsTab, tooltip, item)

    if not success then
        -- An error occurred inside build.itemsTab:AddItemTooltip
        print("Error calling AddItemTooltip:", err_or_result) -- Log the actual error on the server side

        -- Send 500 Internal Server Error response
        client:send("HTTP/1.1 500 Internal Server Error\r\nContent-Type: text/plain\r\nConnection: close\r\n\r\nA server error occurred while processing the item.\r\n")
        client:close()
        return -- Stop processing this request
    end

    -- If AddItemTooltip was successful, continue processing
    local output_structure = convert_formatted_text(tooltip.lines)

    -- Add check around dkjson.encode
    local jsonOut_success, jsonOut = pcall(dkjson.encode, output_structure, {indent = true})
    if not jsonOut_success then
         print("Error encoding JSON response:", jsonOut) -- Log the error
         client:send("HTTP/1.1 500 Internal Server Error\r\nContent-Type: text/plain\r\nConnection: close\r\n\r\nFailed to format response data.\r\n")
         client:close()
         return
    end

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