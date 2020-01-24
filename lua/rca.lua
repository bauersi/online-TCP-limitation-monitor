--- Getting the Path to this script in order to include all necessarry lua script in this folder
local function script_path()
    local str = debug.getinfo(2, "S").source:sub(2)
    return str:match("(.*/)")
end

package.path = script_path() .. "/?.lua;" .. script_path() .. "../luasocket/src/?.lua;" .. package.path --- Extending the Lua Package Path with the RCA Lua Scripts
package.cpath = script_path() .. "../luasocket/src/?.so;" .. package.cpath --- All c required files
local ffi = require "ffi" --- Required for fast prcoessing with LuaJIT
local log = require "log" --- Required to generate Log Message and control the Logs simple
local json = require "json" --- Required in order to produce JSON output, included from https://github.com/rxi/json.lua/blob/master/json.lua
local lm = require "libmoon" --- Required as libmoon is the basis for FlowScope and provides several Functions
-- local inspect = require "inspect"--- Only Required for Testing purposes
local tracker = require "flowManagement" --- The local Lua file for managing the TCP flows according to the requirements of the RCA tool
local rca_config = require "rca_config" --- The configuration file for the RCA tool including all Configuration possibilities in this tool
local socket = require "socket" --- Library to send messages over network protocols
local module = {} --- Generating the local variable module which is send as integration to FlowScope

--- Function filters the tables using a filterfunction filterIter and the table just adding the values to the table, which are filtered
table.filter = function(t, filterIter)
    local out = {}
    for k, v in ipairs(t) do
        if filterIter(k, v) then --- Filter the Items
            table.insert(out, v) --Insert them in a new Table
        end
    end
    return out --Return new Table
end

--- The function abstracts the sending procedures, so that every mode can be used and it do not reflect to the original function
--- @param data Data is the array which is send out and additional information such as measurement name can be added here
function send(data)
    data["measurement"] = rca_config.database.measurement --- Adding the Measurement ID to the data
    if rca_config.database.mode == "UDP" then --- The Mode for UDP Connections
        local udp = assert(socket.udp()) --- Getting the unnconnected UDP socket
        local jsonstr = json.encode(data) --- Encoding the data
        if udp:sendto(jsonstr, socket.dns.toip(rca_config.database.host), rca_config.database.port) == nil then --- -Sending the data
            log:error("JSON was not saved as UDP Error accured, save to file")---Sending the Data was not possible save them to one file.
            local file = io.open("rca_error.json", "a")
            file:write(jsonstr .. "\n")
            file:close()
        end
        assert(udp:close()) --- Closing the UDP Connection
    end --- TODO Add more modes here
end

--- TODO Add a check for the require parts and the every part
local mods = {
    --Declare which mods are used in the RCA tool, what they require and how often they are processed.
    [1] = {
        ["name"] = "connection",
        ["mod"] = require "connection",
        ["from"] = 0,
        ["every"] = 1
    }, -- mss, i, WS
    [2] = {
        ["name"] = "alp",
        ["mod"] = require "alp",
        ["from"] = 0,
        ["every"] = 1
    },
    [3] = {
        ["name"] = "position",
        ["mod"] = require "position",
        ["from"] = 0,
        ["requires"] = {},
        ["every"] = 1
    }, -- handshake
    [4] = {
        ["name"] = "rtt",
        ["mod"] = require "rtt",
        ["from"] = 0,
        ["requires"] = {},
        ["every"] = 1
    }, --use TCP timestamps
    [5] = {
        ["name"] = "capacity",
        ["mod"] = require "capacity",
        ["from"] = 0,
        ["requires"] = {},
        ["every"] = 1
    },
    [6] = {
        ["name"] = "dispersion",
        ["mod"] = require "dispersion",
        ["from"] = 0,
        ["requires"] = { "capacity" },
        ["every"] = 1
    }, -- capacity, avg tput
    [7] = {
        ["name"] = "retransmission",
        ["mod"] = require "retransmission",
        ["from"] = 0,
        ["every"] = 1
    }, -- #bytes retransmitted / #bytes transmitted
    [8] = {
        ["name"] = "rtt_score",
        ["mod"] = require "rtt-score",
        ["from"] = 50,
        ["requires"] = { "rtt" },
        ["every"] = 1
    }, -- #avgrtt / #minrtt
    [9] = {
        ["name"] = "receiver_window",
        ["mod"] = require "receiver-window",
        ["from"] = 0,
        ["requires"] = {},
        ["every"] = 1
    }, -- window minimum RTT of connection (each packet?), outstanding bytes time series - receiver advertised window time series. 3 * MSS, average value of the time series.: outstanding bytes: sender data packet sequence number - highest ack number
    [10] = {
        ["name"] = "burstiness",
        ["mod"] = require "burstiness",
        ["from"] = 0,
        ["requires"] = { "rtt", "capacity" },
        ["every"] = 1
    } -- n = avg receiver window / mss; IAT_n  average of 100/n% largest IATs; b = IAT_n/ RTT
}

--- remove disabled modules
for k, v in ipairs(rca_config.mods_enabled) do --- TODO Improve performance here
    for l, w in ipairs(mods) do
        if w["name"] == k and not v then --- Remove all in iPairs which are not enabled
            table.remove(mods, l) --- Remove them from the mods table
        end
    end
end


-- set log level
log:setLevel("INFO")

for k, v in ipairs(mods) do --- Set LogLevel in each mod (loads the module each time new)
    v.mod.setLoglevel("ERROR")
end


local struct = "" --- The C Structure to store information from the specific mods
for k, v in ipairs(mods) do
    struct = struct .. "\n" .. v.mod.getStateStruct() .. "\n uint8_t " .. v.name .. "_enabled;\n" --- Adds the StateStruct of each mod to the complete structure. and add the name enabled to it in the end to be able to check if the module is enabled.
end

--- Generates the RCA State struct based on the previous defined struct for each packet
ffi.cdef([[
	struct rca_state {
uint32_t checker_i;
]] .. struct .. [[
	};
]])
log:info("Structsize: %s", ffi.sizeof("struct rca_state"))

-- setup of FlowScope
module.mode = "qq" --- Use the FlowScope QQ Ringbuffer for better performance and faster processing and works with the Receive-Side-Scalling in NICs
module.flowKeys = tracker.flowKeys --- Defines with which Key Structure the Packets are stored in the QQ Ringbuffer
module.extractFlowKey = tracker.extract5TupleBidirectional --- Extracting Flow Information Function is set for the FlowKeys and Filtering out packets cheeply
module.stateType = "struct rca_state" --- Setting the State C Struct which stores all packet specific information processed in the different modules
module.checkInterval = rca_config.generalSettings.checkInterval --- The Interval to Run the Checker and execute the checkExpiry function in seconds  TODO: eval
module.checkState = { ["start_time"] = 0 } --- The initial Check State

local defaultState = { ["checker_i"] = 0 } -- The Initial Default state of the module (is iterated after each checker, not possible for parallel processing modules)
for no, rca_mod in ipairs(mods) do --- Adding the Default State of each module to the global default state
    for k, v in pairs(rca_mod.mod.getDefaultState()) do
        defaultState[k] = v
    end
    defaultState[rca_mod['name'] .. "_enabled"] = 1 --- Add a enabled to the default state (TODO Find out if this is necessary)
end
module.defaultState = {} -- it's buggy anyways TODO Find out why the default State is not set here and why it is buggy!

--- Handle Each Packet Individual
-- This operations extract information which have to be done for each individual packet in order to process it later forward
-- @param flowKey table The extracted FlowKey for the Table
-- @param state The c state struct
-- @param buf The buffer to store information in
-- @param isFirstPacket If this is the first packet of the flow or not
-- @return Bool If the packet should be discarded it returns false
function module.handlePacket(flowKey, state, buf, isFirstPacket)
    if state.i_up == 0 then -- Only done once when this is the firstPacket of the connection in Up direction TODO What is with the down direction
        for k, v in ipairs(mods) do
            state[v["name"] .. "_enabled"] = 1
        end
    end
    local dat = {} --- TODO Remove
    local dat = {
        --- Set the dat variable to have the two values stop flag and connection has run TODO What does this means
        ["stop_flag"] = false,
        ["connection_has_run"] = false
    } --- TODO What is done with dat
    if tonumber(state.ignore) ~= 0 then --- Ignore the packet if it is ignored from the state
        return false
    end
    for k, v in ipairs(mods) do
        --      if i == 0 or tonumber(state["i_"..dat.direction]) > v.from then --- TODO what means this and remove
        --         v.mod.handlePacket(flowKey, state, buf, isFirstPacket, dat)
        if dat.stop_flag then --- If the Stop flag is set then the processing is stopped here
            break
        end
        if tonumber(state.ignore) ~= 0 then --- If the packet is set to ignore it is immidiately ignored
            return false
        end
        v.mod.handlePacket(flowKey, state, buf, isFirstPacket, dat) --- The packet handle function of each module is called TODO use the result of a false return
    end
    if tonumber(state.ignore) ~= 0 then --- TODO Find a better way to ask not so often for the ignore part
        return false --- If the packet is set to ignore it is immidiately ignored
    end
end

--- Is called for each flow in a individual intervall
-- All calculation is performed here in order to improve the performance of the packet handle function and if the flow is inactive it is removed from the QQ Ringbuffer after this
-- @param flowKey table The extracted FlowKey for the Table
-- @param state The c state struct
-- @param checkState The C Struct State of the function
-- @return Bool If the packet should be discarded it returns false
function module.checkExpiry(flowKey, state, checkState)
    if state.ignore ~= 1 then --- Ignoring All Flows which are marked as state ignore, as they should not be processed further
        local dat = { json = {} } --- Generates the Dat field
        dat.json.runtimeexp = {} -- This is done for storing the execution times --- TODO Remove as this costs time and perform individual settings
        for k, v in ipairs(mods) do
            local startTimeMod = lm.getTime() --Take the time for the runtime
            if state[v.name .. "_enabled"] == 1 then --or state.checker_i % v.every == 0 or state.checker_i == 0 then --TODO Add the execution prevention here
                v.mod.checkExpiry(flowKey, state, checkState, dat) --- Executes the individual mods TODO Use the return to say a Flow is expired
            end
            local endTimeMod = lm.getTime() --The end time
            dat.json.runtimeexp[v.name] = endTimeMod - startTimeMod --- Saves the execution time of each module individual
        end
        --log:info("JSON data: %s", inspect(dat.json))
        send(dat.json)
        state.checker_i = state.checker_i + 1 --- Add a run of the checker for this module here
    end
    --- TODO Add removing of flows when they are done! How to know when they are done?
end

--- Initializes the Checker
-- Does the Initialization of the Checker before the First Flow
-- @param checkState The C Struct State of the function
function module.checkInitializer(checkState)
    checkState.start_time = lm.getTime() * 10 ^ 6
end

--- Finalize the Checker
-- Does the Finalization of the Checker after the Last Flow
-- @param checkState The C Struct State of the function
function module.checkFinalizer(checkState, keptFlows, purgedFlows)
    local t = lm.getTime() * 10 ^ 6 -- How long it took and how many flows are processed, kept and removed
    log:info("[Checker]: Done, took %fs, flows %i/%i/%i [purged/kept/total]",
        (t - tonumber(checkState.start_time)) / 10 ^ 6,
        purgedFlows, keptFlows, purgedFlows + keptFlows)
end

module.maxDumperRules = rca_config.generalSettings.maxDumperRules --- The Maximum Number of rules to keep for Dumping Packets from the QQ Ring buffer.

-- Function that returns a packet filter string in pcap syntax from a given flow key required in FlowScope
function module.buildPacketFilter(flowKey)
    return flowKey:getPflangBi()
end

return module --- Returns this module to FlowScope
