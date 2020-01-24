--- Extracts and calculates the position of this measurement point to the client and server (Near/far)
local log = require "log"--- Required to generate Log Message and control the Logs simple
local packet = require "packet"--TODO Not used, remove
local tcpLib = require "proto/tcp"--TODO Not used, remove

local module = {}--- Generating the local variable module to return to be able to use this module

---Sets the loglevel of this module to the specified level
function module.setLoglevel(Level)
   log:setLevel(Level)
end

---Provides the state struct for the flow for this module saving specific elements and provides the struct to save the information
function module.getStateStruct()
   return [[
double pos_ts_syn;
double pos_ts_synack;
double pos_ts_ack_data;
double pos;
]]
end

---Provides the default settings for the state, initialized for a new flow each time
function module.getDefaultState()
   return {
      ["pos_ts_syn"] = 0,
      ["pos_ts_synack"] = 0,
      ["pos_ts_ack_data"] = 0,
      ["pos"] = 0
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
   if isFirstPacket and dat.packet.tcp:getSyn() then--It is a first packet
      state.pos_ts_syn = buf:getTimestamp()--The first timestamp of the sync is added here
   end
   if dat["i_down"] == 0 and dat.direction == "down" and dat.packet.tcp:getAck() then --SYNACK
      state.pos_ts_synack = buf:getTimestamp()--Thes first packet in the Downlink is the SYNACK Packet
   end
   if dat["direction"] == "up" and dat["i_up"] == 1 and dat.packet.tcp:getAck() then -- ACK
      state.pos_ts_ack_data = buf:getTimestamp() --The Second packet of the Up direction is assumed and used for the position calulation
      d1 = state.pos_ts_synack - state.pos_ts_syn--Subtracting the Timestamps of synack and syn
      d2 = state.pos_ts_ack_data - state.pos_ts_synack--the Subtraction of acknowledgement and synack
      if (d1+d2) > 0 then--If they are together more than 0, the Intervals between the packets are not 0
         state.pos = d2/(d1+d2)--The position is calculated according to the time between ack and synack divided by the time between syn and ack
      else
         log:error("Position: Intervals are zero, assuming position 0")
         state.pos = 0--The position is zero, sender and receiver are on the same host
      end
   end
   ---Information are stored in the data internal fields
   dat.position = state.pos
   --dat.position = tonumber(state.pos)--TODO Why this not
   dat.pos_ts_syn = state.pos_ts_syn
   dat.pos_ts_synack = state.pos_ts_synack
   dat.pos_ts_ack_data = state.pos_ts_ack_data
end

--- Is called for each flow in a individual intervall
-- Only set the values for the JSON Output and resets the values in the state for the time since this last expiry check.
-- @param flowKey table The extracted FlowKey for the Table
-- @param state The c state struct
-- @param checkState The C Struct State of the function
-- @param dat The internal data values
function module.checkExpiry(flowKey, state, checkState, dat)
   dat.json.pos = tonumber(state.pos)--Add the number of the Position of the Measurement Point to the JSON File
   return dat
end

return module
