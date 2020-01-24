---Calculates the Capacity and used capacity of the flow
local ffi = require "ffi"--- Required for fast prcoessing with LuaJIT
local lm = require "libmoon"--- Required as libmoon is the basis for FlowScope and provides several Functions
local log = require "log"--- Required to generate Log Message and control the Logs simple
local pktLib = require "packet"---Provides the Libmoon packet library
local tcpLib = require "proto/tcp"---Provides the Libmoon tcp protocol library
local rca_config = require "rca_config"---The configuration file for the RCA tool including all Configuration possibilities in this tool
--local inspect = require "inspect"
local module = {}--- Generating the local variable module to return to be able to use this module

PPRATE_SLIDING_WINDOW_SIZE = rca_config.capacitySettings.pprateSlidingWindowSize--The sliding window for the capacity estimation
MIN_NUM_PACKETS = rca_config.capacitySettings.minNumPakets---The minimum number of packets required to calculate the PPRate
CAP_TIME = rca_config.capacitySettings.capTime---Second after Handshake to start calculating

---Sets the loglevel of this module to the specified level
function module.setLoglevel(Level)
   log:setLevel(Level)
end

---Provides the state struct for the flow for this module saving specific elements and provides the struct to save the information
function module.getStateStruct()
   return [[
		uint16_t pos_up_data; // current position in ringbuffer
		uint16_t pos_up_ack;
		uint16_t pos_down_data;
		uint16_t pos_down_ack;

		uint32_t ack_number_up; //last acknowledge numbers to notice delayed acks
		uint32_t ack_number_down;

		uint64_t num_buf_up_data; // number of IATs written to the buffer
		uint64_t num_buf_up_ack;
		uint64_t num_buf_down_data;
		uint64_t num_buf_down_ack;

		double last_ts_up_data; // last timestamps
		double last_ts_up_ack;
		double last_ts_down_data;
		double last_ts_down_ack;

		uint32_t caps_up_data[ ]]..PPRATE_SLIDING_WINDOW_SIZE..[[ ];
		uint32_t caps_up_ack[ ]]..PPRATE_SLIDING_WINDOW_SIZE..[[ ];
		uint32_t caps_down_data[ ]]..PPRATE_SLIDING_WINDOW_SIZE..[[ ];
		uint32_t caps_down_ack[ ]]..PPRATE_SLIDING_WINDOW_SIZE..[[ ];

		double capacity_up;
		double capacity_down;
]]
end

---Provides the default settings for the state, initialized for a new flow each time
function module.getDefaultState()
   return {
      ["pos_up_data"] = 0,
      ["pos_up_ack"] = 0,
      ["pos_down_data"] = 0,
      ["pos_down_ack"] = 0,
      ["ack_number_up"] = 0,
      ["ack_number_down"] = 0,
      ["num_buf_up_data"] = 0,
      ["num_buf_up_ack"] = 0,
      ["num_buf_down_data"] = 0,
      ["num_buf_down_ack"] = 0,
      ["last_ts_up_data"] = 0,
      ["last_ts_up_ack"] = 0,
      ["last_ts_down_data"] = 0,
      ["last_ts_down_ack"] = 0,
      ["capacity_up"] = 0,
      ["capacity_down"] = 0
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
   -- add IATs
   local mode = {}
   -- when packet is ack:
   if dat.packet.tcp:getAck() then
      local acknumber = dat.packet.tcp:getAckNumber()
      local last_ack = state["ack_number_"..dat.direction]---Previous saved Ack number of same connection
      state["ack_number_"..dat.direction] = acknumber---Current Ack number is saved
      local acksize = acknumber - last_ack---Calculating the size between two acknowledged numbers and save in the mode table
      table.insert(mode, {["type"] = "ack", ["size"] = acksize})

   end
   -- when packet carries data
   local data_length = 0
   if flowKey.ip_version == 4 then---Calculating the length of the data based on the packet size and IPVersion
      data_length = buf:getSize() - dat.packet.ip4:getHeaderLength() * 4 - (20 + dat.packet.tcp:getVariableLength()) - 14
   else
      data_length = dat.packet.ip6:getLength()- (20 + dat.packet.tcp:getVariableLength()) - 14 ---At this point we assume that the Header has only TCP extension as the extensions are included in the Length
   end
   if data_length > 0 then---When the packet contains data the complete packet size is saved as data size in the mode table
      local packetsize = buf:getSize()
      table.insert(mode, {["type"] = "data", ["size"] = packetsize})
   end

   -- add to iat ringbuffer arrays
   for key, value in ipairs(mode) do---Go through all added settings (maximum 2)
      local last_ts = tonumber(state["last_ts_"..dat.direction.."_"..value["type"]])
      state["last_ts_"..dat.direction.."_"..value["type"]] = buf:getTimestamp()---Updating the last timestamp
      local iat = buf:getTimestamp() - last_ts---Calculating the inter-arrival times
      if last_ts > 0 then -- omit first packet, we don't have a IAT
--         if value["type"] == "ack" and value["size"] > state["mss_"..dat.direction] + 54 then---TODO Why is this removed
--            iat = iat / 2
--           log:info("Recognized delayed ack. Packetsize %s", value["size"])
--         end
         --log:info("Mode: %s Packetsize is %s, MSS %s is %s", value["type"], value["size"], dat.direction, state["mss_"..dat.direction])
         local cap = value["size"] * 8 / iat---Calculating the Capacity based on the size and the interarrival times (Times 8 to go from bytes to bites)
         --log:info("Adding packet with capacity %s to %s_%s", cap, dat.direction, value["type"])
         state["caps_"..dat.direction.."_"..value["type"]][state["pos_"..dat.direction.."_"..value["type"]]] = cap---save new value
         state["pos_"..dat.direction.."_"..value["type"]] = (state["pos_"..dat.direction.."_"..value["type"]] + 1) % PPRATE_SLIDING_WINDOW_SIZE---Save new Position based on the sliding window size
         state["num_buf_"..dat.direction.."_"..value["type"]] = state["num_buf_"..dat.direction.."_"..value["type"]] + 1---Update the number of cups
      end
   end
   return false---TODO Why is it always returning false, makes no difference now but will
end

--- Is called for each flow in a individual intervall
-- Only set the values for the JSON Output and resets the values in the state for the time since this last expiry check.
-- @param flowKey table The extracted FlowKey for the Table
-- @param state The c state struct
-- @param checkState The C Struct State of the function
-- @param dat The internal data values
function module.checkExpiry(flowKey, state, checkState, dat)

   local now = lm.getTime()---Initialize the time
   local last_ts = 0---Initialize the last timestamp
   ---Initializing all required Arrays
   dat.json.hist_diff_up_ack = {}
   dat.json.hist_diff_down_ack = {}
   dat.json.hist_diff_up_data = {}
   dat.json.hist_diff_down_data = {}
   dat.json.hist_diff2_up_ack = {}
   dat.json.hist_diff2_down_ack = {}
   dat.json.hist_diff2_up_data = {}
   dat.json.hist_diff2_down_data = {}
   dat.json.hist_current_up_ack = {}
   dat.json.hist_current_down_ack = {}
   dat.json.hist_current_up_data = {}
   dat.json.hist_current_down_data = {}
   dat.json.peaks_up_ack = {}
   dat.json.peaks_down_ack = {}
   dat.json.peaks_up_data = {}
   dat.json.peaks_down_data = {}
   dat.json.hist_x_up_data = {}
   dat.json.hist_x_down_data = {}
   dat.json.hist_x_up_ack = {}
   dat.json.hist_x_down_ack = {}

   ---Run the Algorithm two times, once per direction
   for _, direction in pairs({"up", "down"}) do
      local mode = ""---Which packet mode is used
      local capacity_direction = direction---The capacity direction initialized
      if tonumber(state.pos) < 0.5 then --close to sender
         dat["close_to_sender_"..direction] = true---saving if the sender is close
         if direction == "up" then -- up ack, down data
            mode = "ack"
            direction = "down"
            capacity_direction = "up"
         else---data and capacity direction = direction
            mode = "data"
         end
      else
         dat["close_to_sender_"..direction] = false---saving if the sender is far away
         if direction == "up" then --up data, down ack
            mode = "data"
         else ---Acknowledge and capacity direction != direction
            mode = "ack"
            direction = "down"
            capacity_direction = "up"
         end
      end---End selecting according to position
      log:info("Analysing flow %s, %s, %s", ("%s"):format(flowKey), direction, mode)---Analysing Flow
      -- if packet is newer than last_ts update last_ts
      if state["last_ts_"..direction.."_"..mode] > last_ts then
         last_ts = state["last_ts_"..direction.."_"..mode]
      end

      -- only if we have enough packets
      -- or after n seconds after handshake
      if state["num_buf_"..direction.."_"..mode] > MIN_NUM_PACKETS or
      now - state.first_observed > CAP_TIME and state["num_buf_"..direction.."_"..mode] > 30 then--TODO Decide if the 30 should be a Config Item
         ---Initializing local arrays used in the algorithm
         local original_hist = {}
         local original_peaks = {}
         local original_caps = {}
         local original_bin_width = 0
         local bin_width = 0
         local range = {}
         local caps = {}
         local sorted_caps = {}
         local sorted_orig_caps = {}
         local hists = {}
         local start = 0
         local capacity = 0

         local num = tonumber(state["num_buf_"..direction.."_"..mode]) - 1---Number of elements in Caps -1
         -- if we have more than SLIDING_WINDOW_SIZE packages already
         if state["num_buf_"..direction.."_"..mode] > PPRATE_SLIDING_WINDOW_SIZE - 1 then
            start = state["pos_"..direction.."_"..mode]---The current position in the sliding window storage
            num = PPRATE_SLIDING_WINDOW_SIZE---Then the size we use is the sliding window
         end
         log:info("Start: %s, num %s", start, num)
         for i = start, start + num do---Insert all saved Cups according to the index into a caps table for simpler processing
            local index = i % PPRATE_SLIDING_WINDOW_SIZE
            local cap = state["caps_"..direction.."_"..mode][index]
            log:info("Inserting %s to caps", cap)
            table.insert(caps, cap)
         end

         -- we start off with packet trains of length 3
         for n=1, 100 do---Go over 100 times TODO Why 100, maybe move to settings
            log:info("######## n is %s", n)
            if i ~= 2 then---All which are not two (TODO i is never set, do they mean n?!)
               -- build average of n packets
               local caps_grouped = {}
               if n > 1 then---For n > 1 group all caps
                  for i = 1, #original_caps do---Original Caps is empty with the first time
                     local modulo = (i - 1) % n
                     if modulo == 0 then
                        --log:info("Add %s to index %s", original_caps[i], ((i-1)/n) +1)---TODO Remove
                        caps_grouped[ ((i - 1) / n) + 1 ] = original_caps[i]
                     else
                        -- log:info("Add %s to index %s", original_caps[i], math.floor((i-1)/n) +1)---TODO Remove
                        caps_grouped[ math.floor((i-1) / n) + 1 ] =
                           caps_grouped[ math.floor((i-1) / n) + 1 ] + original_caps[i]
                     end
                  end
                  -- build average
                  for i = 1, #caps_grouped - 1 do
                     caps_grouped[i]  = caps_grouped[i] / n---Built the average over n each time
                  end
                  log:info("#original_caps: %s", #original_caps)
                  local modulo = (#original_caps) % n
                  if modulo > 0  then---Save the caps grouped again and modify
                     caps_grouped[ #caps_grouped ] = caps_grouped[ #caps_grouped ] / modulo
                  else
                     caps_grouped[ #caps_grouped ] = caps_grouped[ #caps_grouped ] / n
                  end
                  caps = caps_grouped---Caps are caps_grouped now
               end---End for all which are higher than 1
               log:info("#caps is %s", #caps)

               -- simple assignment is not enough, as it's just a reference
               for k, v in ipairs(caps) do
                  table.insert(sorted_orig_caps, v)---Save all caps in sorted_orig_caps
               end
               table.sort(sorted_orig_caps)---Sort the caps
               if n == 1 then---Only when this is the first iteration
                  ---Calculate the different percentile of number of caps
                  local seventyfive_percentile = math.floor(#caps * 0.75)
                  local twentyfive_percentile = math.floor(#caps * 0.25)
                  local ninetyfive_percentile = math.floor(#caps * 0.95)
                  local iqr = sorted_orig_caps[seventyfive_percentile] - sorted_orig_caps[twentyfive_percentile]---IQR is the 75 percentile - 25 percentile in the sorted array
                  bin_width = math.ceil(iqr * 0.05)---Needed to calculate the bin width of the histogram
                  log:warn("25p: %s, 75p: %s, iqr: %s, bin_width: %s", twentyfive_percentile, seventyfive_percentile, iqr, bin_width)

                  -- filter big: min(p75 + IQR, p95)
                  local filtered_big = table.filter(caps, function(k, v) return v <= (sorted_orig_caps[seventyfive_percentile] + iqr) end)
                  if #filtered_big > #caps * 0.95 then---Filtered Big is too much, removing the smalls
                     log:warn("Removing p75+IQR")
                     caps = filtered_big
                  else---Otherwise Remove only the one greater 95 percentile
                     log:warn("Removing p95")
                     caps = table.filter(caps, function(k,v) return v <= sorted_orig_caps[ninetyfive_percentile] end)
                  end
                  -- filter small: p25 - IQR
                  local filtered_small = table.filter(caps, function(k, v) return v >= sorted_orig_caps[twentyfive_percentile] - iqr and v > 0 end)---The same for the small, Filter the small out
                  caps = filtered_small---Both small and big are filtered out
               end---End only for the first case
               sorted_caps = {}
               for k, v in ipairs(caps) do
                  table.insert(sorted_caps, v)
               end
               table.sort(sorted_caps)----Sort the caps again

               -- generate hist
               log:info("max sorted caps %s, min sorted_caps %s", sorted_caps[#sorted_caps], sorted_caps[1])
               log:info("#caps %s, #sorted_caps %s", #caps, #sorted_caps)
               if bin_width == nil or sorted_caps[#sorted_caps] == nil or sorted_caps[1] == nil then---This means no capacity estimation available
                  log:error("Something has gone wrong during capacity estimation")
                  break
               end
               local numbins = math.ceil((sorted_caps[#sorted_caps] - sorted_caps[1]) / bin_width) + 1---Calculating number of bins in Histogramm
               --log:info("Caps:")---TODO Remove
               --for k,v in ipairs(caps) do io.write(tostring(v)..", ") end
               --log:info("Sorted_Caps:")
               --for k,v in ipairs(sorted_caps) do io.write(tostring(v)..", ") end
               local hist = {}---Empty Array for the histogram
               log:info("numbins: %s, bin_width: %s, #caps: %s", numbins, bin_width, #caps)
               for i = 1, numbins do hist[i] = 0 end---Initialize the Histogram with zero
               for k, v in ipairs(caps) do---Do this for all bins
                  -- log:info("Cap value is %s", v)
                  local index = math.floor((v - sorted_caps[1]) / bin_width) + 1---Calculate the Bin in which this value goes
                  -- log:info("Index: %s", index)
                  assert(index >= 1 and index <= numbins, "hist index out of bounds")
                  hist[index] = hist[index] + 1---Updates the specific histogram index
               end

               local hist_temp = {}
               hist_temp["y"] = hist---Generate the local hist
               local hist_x = {}
               for i = 0, numbins - 1 do table.insert(hist_x, sorted_caps[1] + bin_width * i) end---Add the Hist values
               log:info("min hist_x %s, max hist_x %s, #hist_x %s", hist_x[1], hist_x[#hist_x], #hist_x)
               log:info("Numbins %s", numbins)
               hist_temp["x"] = hist_x---Calculate the Histogram
               hists[n] = hist_temp

               -- PPrate:
               -- detect modes
               -- histogram diff and diff2
               local hist_diff = {[0] = 0}---Initalize the Hist diff
               hist[0] = 0
               for i = 1, numbins do
                  hist_diff[i] = hist[i] - hist[i-1]---Calculate the Histogramm differences
               end
               local hist_diff2 = {}
               for i = 1, #hist_diff do
                  hist_diff2[i] = hist_diff[i] - hist_diff[i - 1]---calculates the Differences of the Differences in the Histogram
               end

               -- generate peak list
               local peaks = {}
               local current = 1
               for i = 1, #hist do
                  local sign
                  if hist_diff[i] > 0 then sign = 1 else sign = -1 end---Decide on which side the hist-diff is
                  if sign ~= current then --vorzeichenwechsel
                     current = sign
                     if hist_diff2[i] < 0 then---The difference of the difference is smaller than 0
                        table.insert(peaks, i-1)---Insert the previous index as peak
                     end
                  end
               end
               -- cleanup
               hist[0] = nil
               hist_diff[0] = nil

               if n == 1 then--Create the original hist, caps and peaks in the first run
                  for k, v in ipairs(peaks) do table.insert(original_peaks, v) end
                  for k, v in ipairs(hist) do table.insert(original_hist, v) end
                  for k, v in ipairs(caps) do table.insert(original_caps, v) end
                  original_bin_width = bin_width
               else
                  for k, v in ipairs(original_caps) do table.insert(caps, v) end----Only move the original_caps to caps
               end

               local should_break = false
               local sorted_orig_caps = {}
               for k, v in ipairs(original_caps) do table.insert(sorted_orig_caps, v) end
               table.sort(sorted_orig_caps)---Sort the original caps again
               local adrs = {}
               for k, v in ipairs(peaks) do
                  local adr = sorted_caps[1] + bin_width * v
                  table.insert(adrs, adr)---Insert the Address of the peak in the bins
                  log:info("ADR %s is at position %s", adr, v)
               end

               if #peaks == 1 and n == 1 then -- PPD has a clear result
                  capacity = sorted_caps[1] + bin_width * peaks[1]
                  should_break = true
               elseif #peaks == 1 then
                  -- relate ADR to original histogram: find mode larger than ADR: strongest and narrowest
                  local pivot = 0
                  local pivot_height = 0
                  for k, v in pairs(original_peaks) do---Find Strongest here
                     -- search "to the right"
                     log:info("Orig peak id at %s", v)
                     local peak = sorted_orig_caps[1] + bin_width * v
                     local peak_height = original_hist[v]
                     log:info("Peak bandwidth is %s with height %s", peak, peak_height)
                     if peak >= adrs[1] then
                        if pivot_height < peak_height then
                           pivot_height = peak_height
                           pivot = peak---Select the pivot
                        end
                     end
                  end
                  -- TODO: narrowest?!? is not found
                  capacity = pivot---Capacity found and direct break
                  should_break = true
               elseif #peaks > 1 and n > 20 then -- we wait until we find a "big peak"
                  -- find a peak two times as high as the rest in the PTD
                  log:warn("Trying to find a peak now")
                  local adr_peak_heights = {}---Peak Height
                  local adr_peak_ids = {}---Peak IDs
                  local adr = 0---Adress
                  for k, v in ipairs(peaks) do
                     table.insert(adr_peak_heights, hist[v])---Insert all Histogram values in Peak height
                  end
                  table.sort(adr_peak_heights)--Sort
                  if adr_peak_heights[#adr_peak_heights] > 1.5 * adr_peak_heights[#adr_peak_heights - 1] or---If you find the highest is 1,5 times higher than the second highest or the amount is 2
                     #peaks == 2
                  then
                     log:warn("Peak 1.5 times bigger detected")
                     -- search hist id of peak
                     for k, v in ipairs(peaks) do
                        if hist[v] == adr_peak_heights[#adr_peak_heights] then
                           adr = adrs[k]---Saves the Hist ID of peaks
                           break
                        end
                     end
                     -- take the bigger ones if only two peaks are left
                     if #peaks == 2 then
                        adr = adrs[#peaks]
                     end

                     log:warn("ADR is %s", adr)
                     -- "trick 17 mit selbstüberlistung"
                     adr = adr*0.95
                     --correlate to PPD
                     local pivot = 0
                     local pivot_height = 0
                     local ranks = {}
                     local integral_sum = 0
                     for k, v in pairs(original_peaks) do
                        local peak = sorted_orig_caps[1] + bin_width * v
                        local peak_height = original_hist[v]
                        if peak >= adr then

                           -- throw out all candidates that do not have any neighbor peak within
                           -- 1/20 of x_axis
                           local neighbor_found = false
                           local x_width = #sorted_orig_caps
                           for l, w in pairs(original_hist) do
                              if math.abs(v-l) < 5 then
                                 neighbor_found = true
                              end
                           end
                           if not neighbor_found then
                              break
                           end

                           -- governor function:
                           -- -x^2*(x-1/5*x_width)*(x+1/5*x_width)
                           -- integrate over everything (height / (delta(distance)^2))
                           local integral = 0
                           for l, w in pairs(original_hist) do
                              local distance = (v - l)

                              local weight = function (x, width)
                                 return - x^2 *
                                    (x - width) *
                                    (x + width)
                              end
                              local width = 0.2 * #original_hist
                              local normfactor = weight(width/math.sqrt(2), width) --y_max
                              if weight(distance, width) > 0 then
                                 integral = integral + w * weight(distance, width) / normfactor
                              end
                           end
                           table.insert(ranks, {
                                           --["rank"] = 2*peak_height - integral,---TODO why is this deleted
                                           ["peak"] = peak,
                                           ["height"] = peak_height,
                                           ["integral"] = integral,
                                           ["peak_id"] = v
                           })
                           integral_sum = integral_sum + integral
                        end
                     end
                     local average_integral = integral_sum / #ranks---Calculate the average Integral out of ranks and integral sum
                     for i=1, #ranks do
                        ranks[i]["rank"] =
                           ranks[i]["height"] -
                           ranks[i]["integral"] +
                           ranks[i]["peak_id"]/#sorted_orig_caps -- slightly prefer higher peaks
                        ranks[i]["averaged_integral"] = average_integral
                     end
                     table.sort(ranks, function(a,b) return a.rank < b.rank end)---Sort the result according to the ranks
                     --log:error("Ranks: %s", inspect(ranks))
                     capacity = ranks[#ranks]["peak"]---Result found
                     should_break = true---Break as the result is found
                  end
               end
               -- log to JSON file
               dat.json["hist_diff".."_"..capacity_direction.."_"..mode][n] = hist_diff
               dat.json["hist_diff2".."_"..capacity_direction.."_"..mode][n] = hist_diff2
               dat.json["hist_current".."_"..capacity_direction.."_"..mode][n] = hist
               dat.json["hist_x".."_"..capacity_direction.."_"..mode][n] = hist_x
               dat.json["peaks".."_"..capacity_direction.."_"..mode][n] = peaks
               if should_break then break end
            else -- n == 2
               ---For number two directly save the information into the json settings with an empty array
               dat.json["hist_diff".."_"..capacity_direction.."_"..mode][2] = {}
               dat.json["hist_diff2".."_"..capacity_direction.."_"..mode][2] = {}
               dat.json["hist_current".."_"..capacity_direction.."_"..mode][2] = {}
               dat.json["hist_x".."_"..capacity_direction.."_"..mode][2] = {}
               dat.json["peaks".."_"..capacity_direction.."_"..mode][2] = {}
            end
         end---End of for going over 100 times
         dat.json["cap_mode_"..capacity_direction] = mode
         dat.json["capacity".."_"..capacity_direction] = capacity
         dat.json["caps".."_"..capacity_direction] = original_caps
         dat.json["bin_width".."_"..capacity_direction] = original_bin_width
         dat["capacity_"..capacity_direction] = capacity
         -- got capacity for this flow. disable the module
         --if capacity > 0 then
         state.capacity_enabled = 0
         --end
         log:info("Capacity is %s", capacity)
         state["capacity_"..capacity_direction] = capacity
      else---Flow in the selected direction has too less packets to calculate
         log:info("Flow %s %s %s only has %s packages. Skipping", ("%s"):format(flowKey), direction, mode, state["num_buf_"..direction.."_"..mode])
      end
   end---End of the direction switching
   return false---TODO Why is it returning false? Not expired or?
end

return module---Module is returned to be used
