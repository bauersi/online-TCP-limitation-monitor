--- Extracts and calculates the amount of Application limitations in the flow called ALP
local log = require "log"--- Required to generate Log Message and control the Logs simple
local lm = require "libmoon"---Not used TODO Remove
local module = {}--- Generating the local variable module to return to be able to use this module

---Sets the loglevel of this module to the specified level
function module.setLoglevel(level)
   log:setLevel(level)
end

---Provides the state struct for the flow for this module saving specific elements and provides the struct to save the information
function module.getStateStruct()
   return [[
uint8_t alp_small_up[8];
uint8_t alp_small_down[8];
uint8_t alp_pos_up;
uint8_t alp_pos_down;

double alp_last_ts_up;
double alp_last_ts_down;
uint8_t alp_up;
uint8_t alp_down;
uint32_t alp_num_period_up;
uint32_t alp_num_period_down;
double alp_time_start_up;
double alp_time_start_down;
double alp_time_period_up;
double alp_time_period_down;
]]
end

---The module has no defaultState for its variables so it is reduced
function module.getDefaultState()
   return {}
end

--- Handle Each Packet Individual
-- This operations extract information of each individual packet and Updates the information in the state for the flow
-- @param flowKey table The extracted FlowKey for the Table
-- @param state The c state struct
-- @param buf The buffer to store information in
-- @param isFirstPacket If this is the first packet of the flow or not
-- @param dat Saves all shared informations between the modules
function module.handlePacket(flowKey, state, buf, isFirstPacket, dat)
   local delta_t = buf:getTimestamp() - state["alp_last_ts_"..dat.direction]--The delta between the last timestamp and the current timestamp of the same direction
   local is_full = true--If the Packet is full or not, required for ALP but not used

   --- Start of the ALP based on the State and the current Dat
   local start_alp = function(state, dat)
      state["alp_"..dat.direction] = 1--Which direction the ALP comes from
      local starttime = buf:getTimestamp()--Current Packet TimeStamp TODO Move directly, no variable
      state["alp_time_start_"..dat.direction] = starttime--The Starttime is the current packetTimestamp
   end

   --- End of the ALP based on the State and the current Dat
   local stop_alp = function(state, dat)
      state["alp_num_period_"..dat.direction] = state["alp_num_period_"..dat.direction] + state["alp_"..dat.direction]---Calculates the total number of ALPs
      state["alp_"..dat.direction] = 0--Resets the number of ALPs for this direction
      local stoptime = buf:getTimestamp()
      local diff = stoptime - tonumber(state["alp_time_start_"..dat.direction])---Calculates the time of the ALP period
      state["alp_time_period_"..dat.direction] = tonumber(state["alp_time_period_"..dat.direction]) + diff--Calculates the total time of ALPs in this TCP flow
   end

   local data_length = 0--Calculates the Datalength
   if flowKey.ip_version == 4 then
      data_length = buf:getSize() - dat.packet.ip4:getHeaderLength() * 4 - 20 - 14--Data Length for IPv4 TCP Header - IP - MAC
   else
      data_length = buf:getSize() - dat.packet.ip6:getLength() * 4 - 20 - 14 -- TODO Control what the number means
   end
   if state["mss_"..dat.direction] > data_length and data_length > dat.packet.tcp:getVariableLength() then---Decide wheter the packet is full or not
      is_full = false---If it not uses the complete possible size it is not full.
   end

   if not is_full then---If it is not full than set the ALP pos to 1 in the correct direction and store that it was limited
      state["alp_small_"..dat.direction][state["alp_pos_"..dat.direction]] = 1
   else
      state["alp_small_"..dat.direction][state["alp_pos_"..dat.direction]] = 0
   end

   if state["alp_"..dat.direction] > 0 then -- we are ALP limited
      -- if we have 3 consecutive packets with mss then ALP is over
      local sum = 0
      for i=0, 2 do
         local cur_index = (state["alp_pos_"..dat.direction] - i) % 8
         if state["alp_small_"..dat.direction][cur_index] == 0 then
            sum = sum + 1
         end
      end
      if sum > 2 then
         stop_alp(state, dat)--use the stop function the set the values
      else
         state["alp_"..dat.direction] = state["alp_"..dat.direction] + 1 ---Add the alp
      end

   else -- not ALP limited yet
      -- calculate how many of last 10 packets were not full
      local sum = 0
      for i=0, 7 do
         sum = sum + state["alp_small_"..dat.direction][i]
      end
      -- if obove threshold then start ALP
      if sum > 2 then--TODO Move the threshold to the configurations
         start_alp(state, dat)
      end

      -- what's the time since the last packet? was it full?
      local last_index = (state["alp_pos_"..dat.direction] - 1) % 8---Time since last packet full
      if delta_t > state.rtt/2 and state["alp_small_"..dat.direction][last_index] == 1 then---If this is true, the ALP has started as the state is smaller and the delta is higher
         -- if older than RTT/2 and no then start ALP
         start_alp(state, dat)
      end

   end

   state["alp_last_ts_"..dat.direction] = buf:getTimestamp()---Last timestamp of controlling ALP
   -- update pos
   state["alp_pos_"..dat.direction] = (state["alp_pos_"..dat.direction] + 1) % 8---ALP Position

   if tonumber(state["alp_"..dat.direction]) > 0 then---If it is currently limited by the ALP no further processing is required
      dat.stop_flag = true
   end

end

--- Is called for each flow in a individual intervall
-- Only set the values for the JSON Output and resets the values in the state for the time since this last expiry check.
-- @param flowKey table The extracted FlowKey for the Table
-- @param state The c state struct
-- @param checkState The C Struct State of the function
function module.checkExpiry(flowKey, state, checkState, dat)
   -- put into json
   dat.json.alp_ratio_up = state.alp_time_period_up / 1.0
   dat.json.alp_ratio_down = state.alp_time_period_down / 1.0
   dat.json.alp_num_period_up = state.alp_num_period_up
   dat.json.alp_num_period_down = state.alp_num_period_down
   -- reset everything
   state.alp_num_period_up = 0
   state.alp_num_period_down = 0
   state.alp_time_period_up = 0
   state.alp_time_period_down = 0
end
return module--Return the module to be used in the RCA calculation
