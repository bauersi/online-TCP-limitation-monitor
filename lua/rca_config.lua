---Contains all Configurationable elements
local module = {}---The module to send back the elements
---Defining which modules are enabled and used in the RCA calculation and which not.
module.mods_enabled = {
   ["connection"] = true,
   ["position"] = true,
   ["rtt"] = true,
   ["capacity"] = true,
   ["dispersion"] = true,
   ["retransmission"] = true,
   ["rtt-score"] = true,
   ["receiver-window"] = true,
   ["burstiness"] = true
}

---All General Settings for the Complete RCA-Module
module.generalSettings ={
   ["checkInterval"] = 0.5, --- The Interval to Run the Checker and execute the checkExpiry function in seconds
   ["maxDumperRules"] = 50 ---See FlowScope Internal Documentation for Details. (Dumper is removing the packets from the QQ Ringbuffer)
}

module.rttSize = 2000 --Number of Packets used in the RTT Calculations

module.capacitySettings = {
   ["pprateSlidingWindowSize"] = 1000,--The sliding window for the capacity estimation
   ["minNumPakets"] = 150,---The minimum number of packets required to calculate the PPRate
   ["capTime"] = 8---Second after Handshake to start calculating
}

module.dispersionSlidingWindowSize = 100 --The sliding window size for the Dispersion calculatio

module.rttScoreSize = 100-- Set the Minimum Number of Packets required for the score size

module.receiverWindowSize = 1000---Sets the size for the RoundRobin Storage here

----Database Specific Settings
module.database = {
   ["mode"] = "UDP",---At the moment only the UDP mode is supported
   ["port"] = 9801,---UDP Connection port, default: 9801
   ["host"] = "localhost",---Which IP or Host name to connect to, default: Localhost
   ["measurement"] = "test1"---Measurementseries name, should be set individual for each run
}
--TODO Add more settings required for Elastic and so on
return module---To be able to use the values
