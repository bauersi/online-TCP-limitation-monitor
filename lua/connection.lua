--- Extracts Various Connection properties from the flow and packets itself
local lm = require "libmoon"--- Required as libmoon is the basis for FlowScope and provides several Functions
local log = require "log"--- Required to generate Log Message and control the Logs simple
local pktLib = require "packet"---Provides the Libmoon packet library
local tcpLib = require "proto/tcp"---Provides the Libmoon tcp protocol library
local module = {}

---Sets the loglevel of this module to the specified level
function module.setLoglevel(Level)
   log:setLevel(Level)
end

---Provides the state struct for the flow for this module saving specific elements and provides the struct to save the information
function module.getStateStruct()
   return [[
   		uint8_t client_is_smaller; //true if client has smaller ip than server, ip_b is always smaller
		uint8_t ignore;

		uint32_t mss_up; //maximum segement sizes
		uint32_t mss_down;

		uint64_t i_up; // number of packets
		uint64_t i_down;
		uint32_t ws_up;//Window Size
		uint32_t ws_down;

		double first_observed;//Time first observed
]]
end

---Provides the default Values of the State --TODO Are they really used?
function module.getDefaultState()
   return {
      ["client_is_smaller"] = 0,
      ["ignore"] = 0,
      ["mss_up"] = 0,
      ["mss_down"] = 0,
      ["i_up"] = 0,
      ["i_down"] = 0,
      ["ws_up"] = 0,
      ["ws_down"] = 0,
      ["first_observed"] = 0
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
   local packet--To store the Information from the packet inbetween
   -- get packet
   if flowKey.ip_version == 4 then--receive the packet out of the buffer based on the IP Version --TODO Use the provided one function selecting between IPv4 and IPv6
      packet = pktLib.getTcp4Packet(buf)
   elseif flowKey.ip_version == 6 then
      packet = pktLib.getTcp6Packet(buf)
   else
      log:warn("Not an IP packet")
      return false--Return to not use the packet if it is not an IP packet
   end
   dat.packet = packet--Store the packet to be used in the other applications

   if isFirstPacket then--All the information only handled for the first packet in a row
      state.first_observed = buf:getTimestamp()
      if packet.tcp:getSyn() then -- client initializes connection
         -- ip_a is always higher than ip_b (flowManagement.lua)
         if flowKey.ip_version == 4 then--Decide
            if flowKey.ip_a.uint32 == packet.ip4.src.uint32 then--the Client is smaller when he is not in ip_b as source
               state.client_is_smaller = 0 --false
            elseif flowKey.ip_b.uint32 == packet.ip4.src.uint32 then
               state.client_is_smaller = 1 --true
            else
                state.ignore = 1
               return false---The Flow State is damaged and this means we should ignore from here
            end
         else
            if flowKey.ip_a.uint64[0] == packet.ip6.src.uint64[0] and flowKey.ip_a.uint64[1] == packet.ip6.src.uint64[1] then--the Client is smaller when he is not in ip_b as source
               state.client_is_smaller = 0 --false
            elseif flowKey.ip_b.uint64[0] == packet.ip6.src.uint64[0] and flowKey.ip_b.uint64[1] == packet.ip6.src.uint64[1] then
               state.client_is_smaller = 1 --true
            else
               state.ignore = 1
               return false---The Flow State is damaged and this means we should ignore from here
            end
         end
      else
         log:warn("We could not record connection initialisation of this flow. Ignoring from now on")
         state.ignore = 1--Ignore the connection as the first packet was not a SYN packet, which is starting the connection, means ignoring it
         return false
      end


      -- get MSS_up
      local opts = packet.tcp:getOptions()--Receive the options out of the TCP Header (IPv6 and IPv4)
      for k, v in pairs(opts) do---Iterate through all options to select the MSS_up state
         local t = v['type']
         if t == tcpLib.option['mss'] then
            state.mss_up = packet.tcp:getMssOption(v)
            log:info("mss_up is %s", state.mss_up)
         end
      end

      -- get windowscaling option
      for k, v in pairs(dat.packet.tcp:getOptions()) do--TODO Add both in the same iterating
         if v["type"] == tcpLib.option["ws"] then--Get Option Window Scaling
            state.ws_up = packet.tcp:getWSOption(v)
         end
      end
   end--End of First packet Part

   -- if current dest ip is smaller one, and client is bigger
   if flowKey.ip_version == 4 then--Decide if the connection is up or down wards divided between ipv6 and ipv4
      if flowKey.ip_b.uint32 == packet.ip4.src.uint32 and tonumber(state.client_is_smaller) ~= 0 then
         dat.direction = "up"
      elseif flowKey.ip_a.uint32 == packet.ip4.src.uint32 and tonumber(state.client_is_smaller) == 0 then
         dat.direction = "up"
      else
         dat.direction = "down"
      end
   else
      if flowKey.ip_b.uint64[0] == packet.ip6.src.uint64[0] and flowKey.ip_b.uint64[1] == packet.ip6.src.uint64[1] and tonumber(state.client_is_smaller) ~= 0 then
         dat.direction = "up"
      elseif flowKey.ip_a.uint64[0] == packet.ip6.src.uint64[0] and flowKey.ip_a.uint64[1] == packet.ip6.src.uint64[1] and tonumber(state.client_is_smaller) == 0 then
         dat.direction = "up"
      else
         dat.direction = "down"
      end
   end
   -- extract downlink mss and windowscaling from first packet
   if tonumber(state.i_down) == 0 and dat.direction == "down"--Only for downwards and the first packet downwards (should be a Acknowledgment)
   and packet.tcp:getAck() then
      for k, v in pairs(packet.tcp:getOptions()) do
         if v['type'] == tcpLib.option['mss'] then
            state.mss_down = packet.tcp:getMssOption(v)
            log:info("mss_down is %s", state.mss_down)---The MSS Downwards
         elseif v['type'] == tcpLib.option["ws"] then
            state.ws_down = packet.tcp:getWSOption(v)
         end
      end
   elseif tonumber(state.i_down) == 0 and dat.direction == "down" then--- If this is the first recognized packet down and it is not a Ack package, the TCP Handshake is missing a packet
      log:warn("Malformed TCP handshake!")
   end

   dat["i_"..dat.direction] = tonumber(state["i_"..dat.direction])--Stores the information in the internal data set from the struct
   dat["ws"] = tonumber(state["ws_"..dat.direction])--Stores the information in the internal data set from the struct
   -- increase packet counter
   state["i_"..dat.direction] = state["i_"..dat.direction] + 1--Increase the packet counter in the State Struct
end

--- Is called for each flow in a individual intervall
-- All calculation is performed here in order to improve the performance of the packet handle function and if the flow is inactive it is removed from the QQ Ringbuffer after this
-- @param flowKey table The extracted FlowKey for the Table
-- @param state The c state struct
-- @param checkState The C Struct State of the function
-- @return Bool If the packet should be discarded it returns false
function module.checkExpiry(flowKey, state, checkState, dat)
   -- TODO: functional expiry check
   local now = lm.getTime()---gets the localtime
   dat.now = now
   local last_ts = 0---TODO last_ts is always 0 (Problem with setting, how to handle) and if it is not set, how to do this
   if last_ts > 0 and last_ts + module.expiryTime < now then---ExpiryTime is the time from them a timestamp is expired TODO Where is expiry Time set and if not, set it in the settings
      return false --expired
   end

   local flowIdTable = {}---Create a local flow table for the json output
   if tonumber(state.client_is_smaller) == 1 then--Decides which IP is client and which is server
      flowIdTable = {
         ["client_ip"] = flowKey.ip_b:getString(),
         ["client_port"] = flowKey.port_b,
         ["server_ip"] = flowKey.ip_a:getString(),
         ["server_port"] = flowKey.port_a
      }
   else
      flowIdTable = {
         ["client_ip"] = flowKey.ip_a:getString(),
         ["client_port"] = flowKey.port_a,
         ["server_ip"] = flowKey.ip_b:getString(),
         ["server_port"] = flowKey.port_b
      }
   end
   for k, v in pairs(flowIdTable) do dat.json[k] = v end---Add the values to the JSON Storage

   ---Add all found values to the JSON output
   dat.json.now = now
   dat.json.client_is_smaller = tonumber(state.client_is_smaller)
   dat.json.ignore = tonumber(state.ignore)
   dat.json.mss_up = tonumber(state.mss_up)
   dat.json.mss_down = tonumber(state.mss_down)
   dat.json.i_up = tonumber(state.i_up)
   dat.json.i_down = tonumber(state.i_down)
   dat.json.ws_up = tonumber(state.ws_up)
   dat.json.ws_down = tonumber(state.ws_down)
   dat.json.first_observed = tonumber(state.first_observed)
   return dat--Return the dat TODO Why and why not true
end

return module
