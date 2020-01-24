--- calculates all values related to the Receiver Window
local log = require "log"--- Required to generate Log Message and control the Logs simple
local rca_config = require "rca_config"---The configuration file for the RCA tool including all Configuration possibilities in this tool
local module = {}--- Generating the local variable module to return to be able to use this module

RW_SIZE = rca_config.receiverWindowSize---Sets the size for the RoundRobin Storage here

---Sets the loglevel of this module to the specified level
function module.setLoglevel(Level)
   log:setLevel(Level)
end

---Provides the state struct for the flow for this module saving specific elements and provides the struct to save the information
function module.getStateStruct()
   return [[
uint32_t rw_ack_up[ ]]..RW_SIZE..[[ ];
uint32_t rw_ack_down[ ]]..RW_SIZE..[[ ];

uint32_t rw_seq_up[ ]]..RW_SIZE..[[ ];
uint32_t rw_seq_down[ ]]..RW_SIZE..[[ ];

uint32_t rw_aw_up[ ]]..RW_SIZE..[[ ];
uint32_t rw_aw_down[ ]]..RW_SIZE..[[ ];

double rw_ack_ts_up[ ]]..RW_SIZE..[[ ];
double rw_ack_ts_down[ ]]..RW_SIZE..[[ ];

double rw_seq_ts_up[ ]]..RW_SIZE..[[ ];
double rw_seq_ts_down[ ]]..RW_SIZE..[[ ];

double rw_aw_ts_up[ ]]..RW_SIZE..[[ ];
double rw_aw_ts_down[ ]]..RW_SIZE..[[ ];

uint16_t rw_ack_pos_up;
uint16_t rw_ack_pos_down;

uint32_t rw_ack_i_up;
uint32_t rw_ack_i_down;

uint16_t rw_seq_pos_up;
uint16_t rw_seq_pos_down;

uint32_t rw_seq_i_up;
uint32_t rw_seq_i_down;

uint16_t rw_aw_pos_up;
uint16_t rw_aw_pos_down;

uint32_t rw_aw_i_up;
uint32_t rw_aw_i_down;
]]
end

---Provides the default settings for the state, initialized for a new flow each time
function module.getDefaultState()
   return {
      ["rw_ack_pos_up"] = 0,
      ["rw_ack_pos_down"] = 0,
      ["rw_ack_i_up"] = 0,
      ["rw_ack_i_down"] = 0,
      ["rw_seq_pos_up"] = 0,
      ["rw_seq_pos_down"] = 0,
      ["rw_seq_i_up"] = 0,
      ["rw_seq_i_down"] = 0,
      ["rw_aw_pos_up"] = 0,
      ["rw_aw_pos_down"] = 0,
      ["rw_aw_i_up"] = 0,
      ["rw_aw_i_down"] = 0
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
   -- notice increased ACK or SEQnumber
   -- store according timestamp and timeshift it rtt/2 * pos or * 1-pos
   if dat.packet.tcp:getAck() then---All Required for Acknowledge Pakets
      if state["rw_ack_"..dat.direction][state["rw_ack_pos_"..dat.direction] -1] < dat.packet.tcp:getAckNumber() then---Only write down when the current acknowledge number higher as the previous is
         state["rw_ack_"..dat.direction][state["rw_ack_pos_"..dat.direction]] = dat.packet.tcp:getAckNumber()---Save new Acknowledge Number
         local ts = buf:getTimestamp() + state["rtt"]/2 * (1 - state.pos)
         state["rw_ack_ts_"..dat.direction][state["rw_ack_pos_"..dat.direction]] = ts---Save Timestamp
         state["rw_ack_pos_"..dat.direction] = (state["rw_ack_pos_"..dat.direction] + 1) % RW_SIZE---Save Position
         state["rw_ack_i_"..dat.direction] = state["rw_ack_i_"..dat.direction] + 1---Increase Acknowledge Number
         dat.currentAck = state["rw_ack_"..dat.direction][state["rw_ack_pos_"..dat.direction]]---Save Current Acknowledge
         dat.shiftedAckTS = ts---Shift Time Stamp
      end
   end
   if state["rw_seq_"..dat.direction][state["rw_seq_pos_"..dat.direction] -1] < dat.packet.tcp:getSeqNumber() then---Only when the current Sequence number bigger than the safed one is
      state["rw_seq_"..dat.direction][state["rw_seq_pos_"..dat.direction]] = dat.packet.tcp:getSeqNumber()---Same as in Ack
      local ts = buf:getTimestamp() - state["rtt"]/2 * state.pos
      state["rw_seq_ts_"..dat.direction][state["rw_seq_pos_"..dat.direction]] = ts
      state["rw_seq_pos_"..dat.direction] = (state["rw_seq_pos_"..dat.direction] + 1) % RW_SIZE
      state["rw_seq_i_"..dat.direction] = state["rw_seq_i_"..dat.direction] + 1
      dat.currentSeq = state["rw_seq_"..dat.direction][state["rw_seq_pos_"..dat.direction]]
      dat.shiftedSeqTs = ts
   end

   -- TODO: CHECK DIRECTIONS
   -- store advertised window with timestamp and timeshift
   state["rw_aw_"..dat.direction][state["rw_aw_pos_"..dat.direction]] = dat.packet.tcp:getWindow() * 2 ^ state["ws_"..dat.direction]---Caclculate Advertised Window
   local ts = buf:getTimestamp() + state["rtt"]/2 * (1 - state.pos)
   state["rw_aw_ts_"..dat.direction][state["rw_aw_pos_"..dat.direction]] = ts---Store Timestamp
   state["rw_aw_pos_"..dat.direction] = (state["rw_aw_pos_"..dat.direction] + 1) % RW_SIZE
   state["rw_aw_i_"..dat.direction] = state["rw_aw_i_"..dat.direction] + 1---Store number
   dat.aw = state["rw_aw_"..dat.direction][state["rw_aw_pos_"..dat.direction]]
   dat.shiftedAWTs = ts---Store timestamp shifted
end

--- Is called for each flow in a individual intervall
-- Only set the values for the JSON Output and resets the values in the state for the time since this last expiry check.
-- @param flowKey table The extracted FlowKey for the Table
-- @param state The c state struct
-- @param checkState The C Struct State of the function
-- @param dat The internal data values
function module.checkExpiry(flowKey, state, checkState, dat)
   -- Outstanding bytes time series -RTT...now
   -- search backwards in all timestamps in ACK and SEQ and RW in timespan
   local ts = {}
   -- construct ts[direction][series][index][value/timestmap] table:
   for _, direction in pairs({"up", "down"}) do---Create timestamp table for every direction
      local other_direction = "up"
      if direction == "up" then other_direction = "down" end
      ts[direction] = {}
      for _, series in pairs({"ack", "seq", "aw"}) do
         ts[direction][series] = {}
         local num = state["rw_"..series.."_i_"..direction] - 1
         local start = 0
         if state["rw_"..series.."_i_"..direction] > RW_SIZE - 1 then
            start = state["rw_"..series.."_pos_"..direction] - 1
            num = RW_SIZE - 1
         end
         local index = 1
         for i = start, start + num do
            local wrapped_i = i % RW_SIZE
            --log:info("Value: %s, now %s, rtt %s", state["rw_"..series.."_ts_"..direction][wrapped_i], now, state["rtt_"..direction])
            --if state["rw_"..series.."_ts_"..direction][wrapped_i] > now - state["rtt_"..direction] then---TODO remove
            ts[direction][series][index] =  {}
            ts[direction][series][index]["value"] = state["rw_"..series.."_"..direction][wrapped_i]
            ts[direction][series][index]["timestamp"] = state["rw_"..series.."_ts_"..direction][wrapped_i]
            index = index + 1
            --end
         end
      end
   end

   for _, direction in pairs({"up", "down"}) do---Do Calculation for each direction
      local other_direction = "up"
      if direction == "up" then other_direction = "down" end
      -- calculate diff for outstanding byte time series
      -- iterate over SEQs and search current highest ACK, store diff
      local b_vector = {}---Used to calculate the b_vector
      --log:warn("Inspect: %s", inspect(ts))
      local latest_seq_ts = 0
      if #ts[direction]["seq"] > 1 then -- cheap workaround
         latest_seq_ts = ts[direction]["seq"][#ts[direction]["seq"]]["timestamp"]
      else
         break
      end
      --log:warn("Latest seq ts: %s", latest_seq_ts)
      for i = 1, #ts[direction]["seq"] do
         if ts[direction]["seq"][i]["timestamp"] > latest_seq_ts - state.min_rtt / 2 then -- data are recent enough
            local current_seq = ts[direction]["seq"][i]
            local current_window = ts[direction]["aw"][i]
            -- now search highest ack with highest timestamp smaller than ACK timestamp
            local pivot_ack = {["value"] = 0, ["timestamp"] = 0}
            for j = 1, #ts[other_direction]["ack"] do
               if (ts[other_direction]["ack"][j]["timestamp"] < ts[direction]["seq"][i]["timestamp"]) and -- ack timestamp is smaller
               (pivot_ack["value"] < ts[other_direction]["ack"][j]["value"]) then -- pivot ack val is smaller
                  pivot_ack = ts[other_direction]["ack"][j]-- increase pivot
               end
            end

            -- find receiver advertised window at time instance
            local pivot_aw = {["value"] = 0, ["timestamp"] = 0}
            for j = 1, #ts[other_direction]["aw"] do
               if (ts[other_direction]["aw"][j]["timestamp"] < ts[direction]["seq"][i]["timestamp"]) and
               (pivot_aw["value"] < ts[other_direction]["aw"][j]["value"]) then
                  pivot_aw = ts[other_direction]["aw"][j]
               end
            end

            -- calculate diff from advertised window
            local element = {}
            --log:warn("Pivot val %s", pivot_ack.value)
            element.outstanding = ts[direction]["seq"][i]["value"] - pivot_ack["value"]
            element.aw = pivot_aw["value"]
            element.window_limited = (element.aw - element.outstanding) < 3 * state["mss_"..direction]
            table.insert(b_vector, element)
         end
      end
      --log:info("Current: %s", inspect(b_vector))
      dat.json["rw_outstanding_"..direction] = {}
      dat.json["rw_aw_"..direction] = {}
      for _, v in ipairs(b_vector) do---Save the data in the b_vector
         table.insert(dat.json["rw_outstanding_"..direction], v.outstanding)
         table.insert(dat.json["rw_aw_"..direction], v.aw)
      end
      -- average of b_vector
      local sum = 0
      log:warn("#b_vector %s %s", direction, #b_vector)---Not a warning, just the result
      for k,v in ipairs(b_vector) do---Calculate the window limited amount of times
         if v["window_limited"] then
            sum = sum + 1
         end
      end
      local receiver_window_score = sum / #b_vector
      if receiver_window_score == receiver_window_score then --not nan
         dat.json["rw_score_"..direction] = receiver_window_score---calculate the receiver window score
      end
   end
end

return module
