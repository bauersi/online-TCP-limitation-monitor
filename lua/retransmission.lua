---Calculates how many bytes had to be transmitted again
local ffi = require "ffi"--- Required for fast prcoessing with LuaJIT
local log = require "log"--- Required to generate Log Message and control the Logs simple
local module = {}--- Generating the local variable module to return to be able to use this module

---Sets the loglevel of this module to the specified level
function module.setLoglevel(Level)
   log:setLevel(Level)
end

---Provides the state struct for the flow for this module saving specific elements and provides the struct to save the information
function module.getStateStruct()
   return [[
uint32_t retransmission_highest_sequence_number_up;
uint32_t retransmission_highest_sequence_number_down;
uint64_t retransmission_bytes_retransmitted_up;
uint64_t retransmission_bytes_retransmitted_down;
uint64_t retransmission_bytes_transmitted_up;
uint64_t retransmission_bytes_transmitted_down;
]]
end

---Provides the default settings for the state, initialized for a new flow each time
function module.getDefaultState()
   return {
      ["retransmission_highest_sequence_number_up"] = 0,
      ["retransmission_highest_sequence_number_down"] = 0,
      ["retransmission_bytes_retransmitted_up"] = 0,
      ["retransmission_bytes_retransmitted_down"] = 0,
      ["retransmission_bytes_transmitted_up"] = 0,
      ["retransmission_bytes_transmitted_down"] = 0,
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
   -- retransmission if sequence number is lower or equal to largest sequence number previously observed on same connection
   if state["retransmission_highest_sequence_number_"..dat.direction] >= dat.packet.tcp:getSeqNumber() then---Bytes had to be retransmitted
      state["retransmission_bytes_retransmitted_"..dat.direction] = state["retransmission_bytes_retransmitted_"..dat.direction] + buf:getSize()
   else---Bytes are only inital transmitted
      state["retransmission_bytes_transmitted_"..dat.direction] = state["retransmission_bytes_transmitted_"..dat.direction] + buf:getSize()
      state["retransmission_highest_sequence_number_"..dat.direction] = dat.packet.tcp:getSeqNumber()
   end
   return dat
end

--- Handle Each Packet Individual
-- This operations extract information of each individual packet and Updates the information in the state for the flow
-- @param flowKey table The extracted FlowKey for the Table
-- @param state The c state struct
-- @param buf The buffer to store information in
-- @param isFirstPacket If this is the first packet of the flow or not
-- @param dat Saves all shared informations between the modules
function module.checkExpiry(flowKey, state, checkState, dat)
   for _, dir in pairs({"up", "down"}) do---Control for Up and Down
      if tonumber(ffi.cast("uint64_t", state["retransmission_bytes_transmitted_"..dir])) > 0 then---If more than 0 Bytes are retransmitted
         dat.json["retransmission_"..dir] =
            tonumber(ffi.cast("uint64_t", state["retransmission_bytes_retransmitted_"..dir])) /
            tonumber(ffi.cast("uint64_t", state["retransmission_bytes_transmitted_"..dir]))---The retransmitted rate is the number of retransmitted divided by the total transmitted bytes
      end
   end
   return dat
end

return module---Returns this module to be used
