local log = require "log"--- Required to generate Log Message and control the Logs simple
local rca_config = require "rca_config"---The configuration file for the RCA tool including all Configuration possibilities in this tool
local module = {}--- Generating the local variable module to return to be able to use this module

DISPERSION_SLIDING_WINDOW_SIZE = rca_config.dispersionSlidingWindowSize--The sliding window size for the Dispersion calculation

---Sets the loglevel of this module to the specified level
function module.setLoglevel(Level)
   log:setLevel(Level)
end

---Provides the state struct for the flow for this module saving specific elements and provides the struct to save the information
function module.getStateStruct()
   return [[
uint16_t dispersion_pos_up; // position in ringbuffer
uint16_t dispersion_pos_down; // position in ringbuffer
uint16_t dispersion_size_up[ ]]..DISPERSION_SLIDING_WINDOW_SIZE..[[ ];
uint16_t dispersion_size_down[ ]]..DISPERSION_SLIDING_WINDOW_SIZE..[[ ];
double dispersion_ts_up[ ]]..DISPERSION_SLIDING_WINDOW_SIZE..[[ ];
double dispersion_ts_down[ ]]..DISPERSION_SLIDING_WINDOW_SIZE..[[ ];
double avg_tput_up;
double avg_tput_down;
]]
end

---Provides the default settings for the state, initialized for a new flow each time
function module.getDefaultState()
   return {
      ["dispersion_pos_up"] = 0,
      ["dispersion_pos_down"] = 0,
      ["avg_tput_up"] = 0,
      ["avg_tput_down"] = 0
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
   ---Only adds values to the dispersion Ring Buffer
   state["dispersion_ts_"..dat.direction][state["dispersion_pos_"..dat.direction]] = buf:getTimestamp()
   state["dispersion_size_"..dat.direction][state["dispersion_pos_"..dat.direction]] = buf:getSize()
   state["dispersion_pos_"..dat.direction] = (state["dispersion_pos_"..dat.direction] + 1) % DISPERSION_SLIDING_WINDOW_SIZE
   return dat---Return the data which is has not to be as it is not used
end

--- Is called for each flow in a individual intervall
-- Only set the values for the JSON Output and resets the values in the state for the time since this last expiry check.
-- @param flowKey table The extracted FlowKey for the Table
-- @param state The c state struct
-- @param checkState The C Struct State of the function
-- @param dat The internal data values
function module.checkExpiry(flowKey, state, checkState, dat)
   for _, dir in pairs({"up", "down"}) do---Calculate all for both directions
      if state["i_"..dir] >= DISPERSION_SLIDING_WINDOW_SIZE then---As soon as the Sliding window size is smaller than the number of written down packets
         local start = 0---Iterate over the Sliding Window
         local num = tonumber(state["i_"..dir]) - 1---Number of Packets
         if state["i_"..dir] > DISPERSION_SLIDING_WINDOW_SIZE - 1 then---If it is more than in the Sliding Window Iterate from the Current Position
            start = state["dispersion_pos_"..dir]
            num = DISPERSION_SLIDING_WINDOW_SIZE - 1
         end
         local bytes = 0---Sum all Bytes of the Packets of the Dispersion Window Size
         for i = start, start + num do
            local index = i % DISPERSION_SLIDING_WINDOW_SIZE
            bytes = bytes + state["dispersion_size_"..dir][index]
         end
         local time_delta =
            state["dispersion_ts_"..dir][(start + num) % DISPERSION_SLIDING_WINDOW_SIZE]
            - state["dispersion_ts_"..dir][start]---Calculate the difference between the time now and the number of used values
         log:info("Bytes: %s, TimeDelta: %s", bytes, time_delta)
         dat["avg_tput_"..dir] = bytes * 8 / time_delta---Save the average Throughput
         state["avg_tput_"..dir] = dat["avg_tput_"..dir]---Save the value in the Status
         if state["capacity_"..dir] ~= nil and state["capacity_"..dir] > 0 then
            dat["dispersion_"..dir] = 1 - ( dat["avg_tput_"..dir] / state["capacity_"..dir] )---Calculate the Dispersion when the Capacity is set
         end
         ---Save the values to the JSON file
         dat.json["avg_tput_"..dir] = dat["avg_tput_"..dir]
         dat.json["dispersion_"..dir] = dat["dispersion_"..dir]
      end
   end---Both directions
end

return module---Return this Module
