--Calculates the Round Trip Time Score
local rca_config = require "rca_config"---The configuration file for the RCA tool including all Configuration possibilities in this tool
local module = {}--- Generating the local variable module to return to be able to use this module
RTT_SCORE_SIZE = rca_config.rttScoreSize-- Set the Minimum Number of Packets required for the score size

---Sets the loglevel of this module to the specified level
function module.setLoglevel(Level)
 --  log:setLevel(Level) No Log line included here
end

---Provides the state struct for the flow for this module saving specific elements and provides the struct to save the information

function module.getStateStruct()
   return [[
double rtt_score_up[ ]]..RTT_SCORE_SIZE..[[ ];
double rtt_score_down[ ]]..RTT_SCORE_SIZE..[[ ];
uint16_t rtt_score_up_pos;
uint16_t rtt_score_down_pos;
]]
end

---Provides the default settings for the state, initialized for a new flow each time

function module.getDefaultState()
   return {
      ["rtt_score_up_pos"] = 0,
      ["rtt_score_down_pos"] = 0
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
   ---Saves Information in the Roundtrip Information which are calculated in the RTT module
   state["rtt_score_"..dat.direction][state["rtt_score_"..dat.direction.."_pos"]] = state["rtt"]
   state["rtt_score_"..dat.direction.."_pos"] = (state["rtt_score_"..dat.direction.."_pos"] + 1) % RTT_SCORE_SIZE
end

--- Is called for each flow in a individual intervall
-- Only set the values for the JSON Output and resets the values in the state for the time since this last expiry check.
-- @param flowKey table The extracted FlowKey for the Table
-- @param state The c state struct
-- @param checkState The C Struct State of the function
-- @param dat The internal data values
function module.checkExpiry(flowKey, state, checkState, dat)
   for _, dir in pairs({"up", "down"}) do---Perform the calculation for each direction
      local start = 0---Starting number for Round Robin Storage
      local num = tonumber(state["i_"..dir]) - 1---Number of elements used
      if state["i_"..dir] > RTT_SCORE_SIZE - 1 then---If the Size is enough or bigger the Round Robin Store will be used
         start = state["rtt_score_"..dir.."_pos"]
         num = RTT_SCORE_SIZE
      end
      local sum = 0---Calculate the Sum of the rtt scores
      for i = start, start + num do
         local index = i % RTT_SCORE_SIZE
         sum = sum + state["rtt_score_"..dir][index]
      end
      local avg_rtt = sum / num---Calculates the Average of the Score
      ---TODO Use the result as it is not used here
   end
end

return module---Returns the module to be used in the RCA module
