--- Extracts and calculates the round trip time (rtt)
local tcpLib = require "proto/tcp"---Provides the Libmoon tcp protocol library
local lm = require "libmoon"---Not used TODO Remove
local log = require "log"--- Required to generate Log Message and control the Logs simple
local ffi = require "ffi"--- Required for fast prcoessing with LuaJIT
local module = {}--- Generating the local variable module to return to be able to use this module
local rca_config = require "rca_config"---The configuration file for the RCA tool including all Configuration possibilities in this tool

RTT_SIZE=rca_config.rttSize---The Size of the RTT Calculation including the number of used packets

---Sets the loglevel of this module to the specified level
function module.setLoglevel(Level)
   log:setLevel(Level)
end

---Provides the state struct for the flow for this module saving specific elements and provides the struct to save the information
function module.getStateStruct()
   return [[
uint32_t tsval_up[ ]]..RTT_SIZE..[[ ];
uint32_t tsval_down[ ]]..RTT_SIZE..[[ ];
uint32_t tsecr_up[ ]]..RTT_SIZE..[[ ];
uint32_t tsecr_down[ ]]..RTT_SIZE..[[ ];
double rtt_ts_up[ ]]..RTT_SIZE..[[ ];
double rtt_ts_down[ ]]..RTT_SIZE..[[ ];
uint16_t rtt_pos_up;
uint16_t rtt_pos_down;
double rtt;
double min_rtt;
]]
end

---Provides the default settings for the state, initialized for a new flow each time
function module.getDefaultState()
   return {
      ["rtt_pos_up"] = 0,
      ["rtt_pos_down"] = 0,
      ["rtt"] = 0,
      ["min_rtt"] = 0
   }
end

--- Handle Each Packet Individual
-- This operations extract information of each individual packet and Updates the information in the state for the flow
-- @param flowKey table The extracted FlowKey for the Table
-- @param state The c state struct
-- @param buf The buffer to store information in
-- @param isFirstPacket If this is the first packet of the flow or not
-- @param dat Saves all shared informations between the modules
function module.handlePacket(flowKey, state, buf, isFirstPacket, dat)

   local other_dir = ""---Saves the direction which is opposite of this direction and is assigned in the next line
   if dat.direction == "up" then other_dir = "down" else other_dir = "up" end
   local ts = {}--Saves the TCP OPtion timestamp
   -- add new timestamp
   for k, v in pairs(dat.packet.tcp:getOptions()) do
      if v["type"] == tcpLib.option["ts"] then---Includes the timestamp
         ts = dat.packet.tcp:getTSOption(v)---Saves the timestamp values
         state["tsval_"..dat.direction][state["rtt_pos_"..dat.direction]] = ts.tsval---Saves the timestamp values according to the direction
         state["tsecr_"..dat.direction][state["rtt_pos_"..dat.direction]] = ts.tsecr--saves the Timestamp Echo Reply values
         state["rtt_ts_"..dat.direction][state["rtt_pos_"..dat.direction]] = buf:getTimestamp()---Saves the packet received timestamp
         state["rtt_pos_"..dat.direction] = (state["rtt_pos_"..dat.direction] + 1) % RTT_SIZE---Calculates the position by + 1 module the RTT Size
         dat.tsval = tonumber(ffi.cast("uint32_t", ts.tsval))---Saves the Values in the data internal section
         dat.tsecr = tonumber(ffi.cast("uint32_t", ts.tsecr))
         break---We need no other option here
      end
   end
end

--- Is called for each flow in a individual intervall
-- Calculates the Round Trip Time and saves it to the state and in the JSON Output
-- @param flowKey table The extracted FlowKey for the Table
-- @param state The c state struct
-- @param checkState The C Struct State of the function
-- @param dat The internal data values
function module.checkExpiry(flowKey, state, checkState, dat)
   -- TODO: Maybe calculate also RTT for last n packets and take average
   -- get latest tsecr up
   -- search according tsval down
   local index_up_last = (state["rtt_pos_up"] - 1) % RTT_SIZE
   local delta_t1 = 0
   local index = 0
   for i = 0, RTT_SIZE - 1 do---Go back until the RTT_SIZE OPTION
      if state["tsecr_up"][index_up_last] == state["tsval_down"][i] then
         delta_t1 = state["rtt_ts_up"][index_up_last] - state["rtt_ts_down"][i]---Calculates the Delta between corresponding timestamp up and down
         index = i
         break
      end
   end
   -- calculate the number of positions we are back to optimize the array size
   local back1 = 0
   if index_up_last > index then
      back1 = index_up_last - index
   else---If the Index UP last is not greater than it is far more back and needs a different calulation
      back1 = RTT_SIZE - (index - index_up_last)
   end
   -- from this take tsecr down
   -- find accoring tsecr up
   -- calc delta t2
   local delta_t2 = 0
   local index2 = 0
   for i = 0, RTT_SIZE - 1 do
      if state["tsecr_down"][index] == state["tsval_up"][i] then
         delta_t2 = state["rtt_ts_down"][index] - state["rtt_ts_up"][i]
         index2 = i
         break
      end
   end
   -- calculate the number of positions we are back to optimize the array size
   local back2 = 0
   if index > index2 then
      back2 = index - index2
   else---If the Index UP last is not greater than it is far more back and needs a different calulation
      back2 = RTT_SIZE - (index2 - index)
   end

   state.rtt = delta_t1 + delta_t2---Calculates the round trip time based on the previous set delta values

   -- set min_rtt
   if state.min_rtt == 0 or state.min_rtt > state.rtt then
      state.min_rtt = state.rtt---Updates minimum RTT
   end

   ---Saves Information for print out with JSON
   dat.json.rtt = tonumber(state.rtt)
   dat.json.back1 = back1
   dat.json.back2 = back2
   dat.json.min_rtt = tonumber(state.min_rtt)
   return
end

return module---Return this as module
