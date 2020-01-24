---calculates the burstiness score (Burstiness of the inter-contact time)
local log = require "log"--- Required to generate Log Message and control the Logs simple
local module = {}--- Generating the local variable module to return to be able to use this module

---Sets the loglevel of this module to the specified level
function module.setLoglevel(Level)
   log:setLevel(Level)
end

---Provides the state struct for the flow for this module saving specific elements and provides the struct to save the information
function module.getStateStruct()
   return [[
double bscore_up;
double bscore_down;
]]
end

---Provides the default settings for the state, initialized for a new flow each time
function module.getDefaultState()
   return {
      ["bscore_up"] = 0,
      ["bscore_down"] = 0
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
   return --nuffin
end

--- Is called for each flow in a individual intervall
-- Only set the values for the JSON Output and resets the values in the state for the time since this last expiry check.
-- @param flowKey table The extracted FlowKey for the Table
-- @param state The c state struct
-- @param checkState The C Struct State of the function
-- @param dat The internal data values
function module.checkExpiry(flowKey, state, checkState, dat)
   for _, direction in pairs({"up", "down"}) do---Once for each direction
      local other_dir = ""
      if direction == "up" then other_dir = "down" else other_dir = "up" end
      local start = 0---Starts in the Receiver Window Store
      local num = tonumber(state["i_"..other_dir]) - 1
      if state["i_"..other_dir] > RW_SIZE - 1 then
         start = state["rw_aw_pos_"..other_dir]
         num = RW_SIZE - 1---Reset according to the receiver window store
      end
      local sum = 0---Calculates the sum of all advertised window elements
      for i = start, start + num do
         local index = i % RW_SIZE
         sum = sum + state["rw_aw_"..other_dir][index]
      end
      local avg_receiver_window = sum / num---Calculating the average

      if state["capacity_"..direction] > 0 and state["rtt"] > 0 then---Calculating for capacity and round trip time greater 0
         local bscore = 1 -
            ((avg_receiver_window * 8  - 1)
                  * state["mss_"..direction] * 8 / state["capacity_"..direction]) /
            state["rtt"]---calculating the burstiness score using the average advertised window, the MSS ad the capacity as well as the round trip time
         state["bscore_"..direction] = bscore---The value is stored
         dat.json["bscore_"..direction] = tonumber(state["bscore_"..direction])
      end
   end
end

return module---Returns the module to be able to be used
