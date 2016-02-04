-- vim:ts=4:sw=4:noexpandtab
--- This script can be used to determine if a device is affected by the corrupted packets
--  that are generated by the software rate control method.
--  It generates CBR traffic via both methods and compares the resulting latency distributions.
--  TODO: this module should also test L3 traffic (but not just L3 due to size constraints (timestamping limitations))
local dpdk      = require "dpdk"
local memory    = require "memory"
local ts        = require "timestamping"
local device    = require "device"
local filter    = require "filter"
local timer     = require "timer"
local stats     = require "stats"
local hist      = require "histogram"


-- required here because this script creates *a lot* of mempools
memory.enableCache()


-------------------------------------------------------------------------------
-- "Constants"
-------------------------------------------------------------------------------
local REPS = 1
local run_time = 60
local LATENCY_TRIM = 3000 -- time in ms to delayied start and early end to latency mseasurement, so we are certain main packet load is present
local FRAME_SIZE = 64
local BIDIREC = 0 --do not do bidirectional test
local LATENCY = 0 --do not get letency measurements
local MAX_FRAME_LOSS_PCT = 0
local LINE_RATE = 10000000000 -- 10Gbps
local RATE_RESOLUTION = 0.02
local ETH_DST   = "10:11:12:13:14:15" -- src mac is taken from the NIC
-- local ETH_DST   = "ec:f4:bb:ce:cd:68" -- src mac is taken from the NIC
local IP_SRC    = "192.168.0.10"
local IP_DST    = "10.0.0.1"
local PORT_SRC  = 1234
local PORT_DST  = 1234
local NUM_FLOWS = 256 -- src ip will be IP_SRC + (0..NUM_FLOWS-1)
local TX_RATE_TOLERANCE_MPPS = 0.2  -- The acceptable difference between actual and measured TX rates (in Mpps).  Abort test if greater


function master(...)
	local port1, port2, frame_size, bidirec, max_acceptable_frame_loss_pct, num_flows, max_line_rate_Mfps = tonumberall(...)

        if not port1 or not port2 then
            printf("\n\n");
	    printf("Usage: \n");
	    printf("         opnfv-vsperf.lua Port1 Port2 [Frame Size] [Traffic Direction] [Maximum Acceptable Frame Loss] [Number of Flows] [Maximum Frames Per Second]\n\n");
            printf("             where:\n");
            printf("                Port1 ............................ The first DPDK enabled port of interest, e.g. 0\n");
            printf("                Port2 ............................ The second DPDK enabled port of interest, e.g. 1\n");
            printf("                Frame Size ....................... Frame size in bytes.  This is the 'goodput' payload size in bytes.  It does not include");
            printf("                                                   the preamble (7 octets), start of frame delimited (1 octet), and interframe gap (12 octets). ");
            printf("                                                   The default size is 64. \n");
            printf("                Traffic Direction ................ Unidirectional (0) or bidirectional (1) traffic flow between Port1 and Port2.  Default is unidirectional\n");
            printf("                Maximum Acceptable Frame Loss .... Percentage of acceptable packet loss.  Default is 0\n");
            printf("                Number of Flows .................. Number of packet flows.  Default is 256\n");
            printf("                Maximum Frames Per Second ........ The maximum number of frames per second (in Mfps).  For a 10 Gbps connection, this would be 14.88 (also the default)");
            printf("\n\n");
            return
	end

	frame_size = frame_size or FRAME_SIZE
	bidirec = bidirec or BIDIREC
	max_acceptable_frame_loss_pct = max_acceptable_frame_loss_pct or MAX_FRAME_LOSS_PCT
	max_line_rate_Mfps = max_line_rate_Mfps or (LINE_RATE /(frame_size*8 +64 +96) /1000000) --max_line_rate_Mfps is in millions per second
	num_flows = num_flows or NUM_FLOWS
        -- The allowed frame loss (percent)
	rate_resolution = RATE_RESOLUTION
	latency = LATENCY

	-- assumes port1 and port2 are not the same
	local numQueues = 1 
	if (bidirec == 1) then
		numQueues = numQueues + 1 
	end
	if (latency == 1) then
		numQueues = numQueues + 1 
	end

	local prevRate = 0
	local prevPassRate = 0
	local frame_loss = 0
	local prevFailRate = max_line_rate_Mfps
	local rate = max_line_rate_Mfps
        -- local method = "hardware"
	local method = "software"
        local final_validation_ctr = 0

	while ( math.abs(rate - prevRate) > rate_resolution or final_validation_ctr < 1 ) do
                local devs = {}
                devs[1] = device.config(port1, numQueues, numQueues)
                devs[2] = device.config(port2, numQueues, numQueues)
                device.waitForLinks()
		-- r = {frame_loss, rxMpps, total_rx_frames, total_tx_frames}
	        r = {dev1_frame_loss, 
                     dev1_rxMpps, 
                     dev1_total_tx_frames, 
                     dev1_total_rx_frames, 
                     dev2_frame_loss, 
                     dev2_rxMpps, 
                     dev2_total_tx_frames, 
                     dev2_total_rx_frames, 
                     avg_device_frame_loss, 
                     aggregate_avg_rxMpps, 
                     dev1_frame_loss, 
                     dev2_frame_loss, 
                     dev1_txMpps, 
                     dev2_txMpps}

                printf("TOP OF WHILE LOOP:  Testing with prevPassRate = %.2f, prevFailRate = %.2f, prevRate = %.2f, rate = %.2f", prevPassRate, prevFailRate, prevRate, rate); 
		launchTest(devs[1], devs[2], rate, bidirec, 0, frame_size, run_time, num_flows, method, r)
		local avg_device_frame_loss = r[9]
		local aggregate_avg_rxMpps = r[10]
	        local dev1_txMpps = r[13]
	        local dev2_txMpps = r[14]


                if math.abs(rate - dev1_txMpps) > TX_RATE_TOLERANCE_MPPS then
                    printf("\n\n");
                    printf("ABORT TEST:  Device 1 transmit rate not correct. \n");
                    printf("             The desired TX Rate = %.2f Mpps, the measured TX Rate = %.2f Mpps\n", rate, dev1_txMpps);
                    printf("             The difference between rates can not exceed %.2f Mpps\n\n", TX_RATE_TOLERANCE_MPPS);
                    return
                end

                -- printf("The Tx rates in Mpps are:  dev1 = %.2f    dev2 = %.2f **********\n", dev1_txMpps, dev2_txMpps);
                -- total_tx_frames = r[3]
                -- total_rx_frames = r[4]
		prevRate = rate
	        if avg_device_frame_loss > max_acceptable_frame_loss_pct then --failed to have <= max_acceptable_frame_loss_pct, lower rate
                        printf("*********************************************************************************************************************************");
			printf("* Test Result:  FAILED - The traffic throughput loss was %.8f %%, which is higher than the maximum allowed (%.2f %%) loss", avg_device_frame_loss, max_acceptable_frame_loss_pct);
                        printf("*********************************************************************************************************************************");
			prevFailRate = rate
			rate = ( prevPassRate + rate ) / 2
                        printf("FAIL WHILE LOOP:  Testing with prevPassRate = %.2f, prevFailRate = %.2f, prevRate = %.2f, 'new'rate = %.2f", prevPassRate, prevFailRate, prevRate, rate); 
		else --acceptable packet loss, increase rate
                        printf("*********************************************************************************************************************************");
			printf("* Test Result:  PASSED - The traffic thoughput loss was %.8f %%, was did not exceed the maximum allowed loss (%.2f %%)", avg_device_frame_loss, max_acceptable_frame_loss_pct);
                        printf("*********************************************************************************************************************************");
			prevPassRate = rate
			rate = (prevFailRate + rate ) / 2
                        printf("PASS WHILE LOOP:  Testing with prevPassRate = %.2f, prevFailRate = %.2f, prevRate = %.2f, 'new'rate = %.2f", prevPassRate, prevFailRate, prevRate, rate); 
		end
		printf("\n")
		dpdk.sleepMillis(500)
		if not dpdk.running() then
			break
		end
		printf("\n")

	        if math.abs(rate - prevRate) < rate_resolution then
                
	            r = {dev1_frame_loss_pct, 
                         dev1_rxMpps, 
                         dev1_total_tx_frames, 
                         dev1_total_rx_frames, 
                         dev2_frame_loss_pct, 
                         dev2_rxMpps, 
                         dev2_total_tx_frames, 
                         dev2_total_rx_frames, 
                         avg_device_frame_loss, 
                         aggregate_avg_rxMpps, 
                         dev1_frame_loss, 
                         dev2_frame_loss, 
                         dev1_txMpps, 
                         dev2_txMpps}

                    printf("\n");
                    printf("*********************************************************************************************");
	            printf("* Starting final validation");
                    printf("*********************************************************************************************");
                    printf("\n\n");
                    printf("VALIDATION WHILE LOOP:  Testing with prevPassRate = %.2f, prevFailRate = %.2f, prevRate = %.2f, rate = %.2f", 
                            prevPassRate, prevFailRate, prevRate, rate); 
	            launchTest(devs[1], devs[2], prevPassRate, bidirec, latency, frame_size, run_time, num_flows, method, r)
                    printf("\n\n");
                    printf("*********************************************************************************************");
	            printf("* Stopping final validation");
                    printf("*********************************************************************************************");
                    printf("\n\n");
	            local dev1_frame_loss_pct = r[1]
	            local dev1_rxMpps = r[2]
                    local dev1_total_tx_frames = 0
                    local dev1_total_rx_frames = 0
                    local dev1_total_tx_frames = r[3]
                    local dev1_total_rx_frames = r[4]
	            local dev2_frame_loss_pct = r[5]
	            local dev2_rxMpps = r[6]
                    local dev2_total_tx_frames = 0
                    local dev2_total_rx_frames = 0
                    dev2_total_tx_frames = r[7]
                    dev2_total_rx_frames = r[8]
                    local avg_device_frame_loss = r[9]
                    local aggregate_avg_rxMpps = r[10]
	            local dev1_frame_loss = r[11]
	            local dev2_frame_loss = r[12]
	            local dev1_txMpps = r[13]
	            local dev2_txMpps = r[14]

                    if math.abs(rate - dev1_txMpps) > TX_RATE_TOLERANCE_MPPS then
                        printf("\n\n");
                        printf("ABORT TEST:  Device 1 transmit rate not correct. \n");
                        printf("             The desired TX Rate = %.2f Mpps, the measured TX Rate = %.2f Mpps\n", rate, dev1_txMpps);
                        printf("             The difference between rates can not exceed %.2f Mpps\n\n", TX_RATE_TOLERANCE_MPPS);
                        return
                    end
                    -- printf("The Tx rates in Mpps are:  dev1 = %.2f    dev2 = %.2f **********\n", dev1_txMpps, dev2_txMpps);
                    
                    if (avg_device_frame_loss) > max_acceptable_frame_loss_pct then

                        printf("\n");
                        printf("*********************************************************************************************");
                        printf("* Final Validation Test Result:  FAILED\n" ..
                               "*     The validation of %.2f Mfps failed because the traffic throughput loss was %.8f %%, \n" ..
                               "*     which is higher than the maximum allowed (%.2f %%) loss", 
                               aggregate_avg_rxMpps, avg_device_frame_loss, max_acceptable_frame_loss_pct);
                        printf("*********************************************************************************************");
                        printf("\n");
			
                        --prevFailRate = prevPassRate
                        --prevPassRate = prevPassRate * 0.80
			--rate = prevPassRate 
                        prevFailRate = prevPassRate
                        prevPassRate = 0
			rate = ( prevPassRate + rate ) / 2

	            else
                        printf("\n");
                        printf("*********************************************************************************************");
                        printf("* Final Validation Test Result:  PASSED\n" ..
                               "*     The validation of %.2f Mfps passed because the traffic throughput loss was %.8f %%, \n" ..
                               "*     which did not exceed the maximum allowed (%.2f %%) loss", 
                               aggregate_avg_rxMpps, avg_device_frame_loss, max_acceptable_frame_loss_pct);
                        printf("*********************************************************************************************");
                        printf("\n");

                        printf("#############################################################################################\n");
                        printf("RFC 2544 Test Results Summary From Final Validation\n\n");

	                printf("Measured Aggregate Average Throughput (Mfps) ................ %.2f", aggregate_avg_rxMpps);
	                printf("Frame Size .................................................. %d", frame_size);
                        
                        if (bidirec == 1) then
	                    printf("Traffic Flow Direction ...................................... Bidirectional");
	                    printf("Maximum Theoretical Line Rate Throughput (Mfps) ............. %.2f", 2 * max_line_rate_Mfps);
                        else
	                    printf("Traffic Flow Direction ...................................... Unidirectional");
	                    printf("Maximum Theoretical Line Rate Throughput (Mfps) ............. %.2f", max_line_rate_Mfps);
                        end

	                printf("Number of Data Flows ........................................ %d", num_flows);
	                printf("Rate Resolution (%%) ......................................... %.2f", rate_resolution);
	                printf("Maximum Acceptable Frame Loss (%%) ........................... %.2f", max_acceptable_frame_loss_pct);
                        printf("\n");
	                printf("Network Device ID ........................................... %d", port1);
                        printf("    Average Rx Frame Count (Mfps) ........................... %.2f", dev1_rxMpps);
                        printf("    Rx Frame Count .......................................... %d", dev1_total_rx_frames);
                        printf("    Tx Frame Count .......................................... %d", dev1_total_tx_frames);
                        printf("    Frame Loss .............................................. %d", dev1_frame_loss);
                        printf("\n");
	                printf("Network Device ID ........................................... %d", port2);
                        printf("    Average Rx Frame Count (Mfps) ........................... %.2f", dev2_rxMpps);
                        printf("    Rx Frame Count .......................................... %d", dev2_total_rx_frames);
                        printf("    Tx Frame Count .......................................... %d", dev2_total_tx_frames);
                        printf("    Frame Loss .............................................. %d\n", dev2_frame_loss);
                        printf("#############################################################################################\n");
                        printf("\n\n");
                        final_validation_ctr = 1
	            end
		    printf("\n")
		    dpdk.sleepMillis(500)
		    if not dpdk.running() then
		    	break
		    end
		    printf("\n")
		end
	end

        -- run_time = run_time * 2 --use a longer runtime for final validation
	printf("\n")
	dpdk.sleepMillis(500)
end

function launchTest(dev1, dev2, rate, bidirec, latency, frame_size, run_time, num_flows, method, t)
		-- t = {frame_loss, rxMpps}

		local total_rate = rate
		local qid = 0

		if (bidirec == 1) then
			total_rate = rate * 2
		end


                printf("\n\nInside launchTest.  rate = %.2f, bidirec = %d, latency = %d, frame_size = %d, run_time = %d, num_flows = %d, method = %s\n\n", rate, bidirec, latency, frame_size, run_time, num_flows, method);

                printf("*********************************************************************************");
		printf("* Testing frame rate (millions per second) with %s rate control: %.2f", method , total_rate)
                printf("*********************************************************************************");
		dev1:getTxQueue(qid):setRateMpps(method == "hardware" and rate or 0)
		loadTask1a = dpdk.launchLua("loadSlave", dev1:getTxQueue(qid), dev2:getRxQueue(qid), method == "software" and rate, frame_size, run_time, num_flows)
		qid = qid + 1

		if (bidirec == 1) then
			dev2:getTxQueue(qid):setRateMpps(method == "hardware" and rate or 0)
			loadTask1b = dpdk.launchLua("loadSlave", dev2:getTxQueue(qid), dev1:getRxQueue(qid), method == "software" and rate, frame_size, run_time, num_flows)
			qid = qid + 1
		end

		if (latency == 1) then
			loadTask2a = dpdk.launchLua("timerSlave", dev1:getTxQueue(qid), dev2:getRxQueue(qid), frame_size, run_time, num_flows)
			qid = qid + 1
		end

		local dev1_total_frame_loss_pct = 0 
		local dev1_avg_rxMpps = 0
		local dev1_avg_txMpps = 0
                local dev1_total_tx_frames = 0
                local dev1_total_rx_frames = 0
		local dev2_total_frame_loss_pct = 0
		local dev2_avg_rxMpps = 0
		local dev2_avg_txMpps = 0
                local dev2_total_tx_frames = 0
                local dev2_total_rx_frames = 0
                local avg_device_frame_loss = 0
                local aggregate_avg_rxMpps = 0
                local aggregate_avg_txMpps = 0
                local dev1_total_frame_loss = 0
                local dev2_total_frame_loss = 0
                
                
		local r1 = {}
		r1 = loadTask1a:wait()
		dev1_total_frame_loss_pct = r1[1]
		dev1_avg_rxMpps = r1[2]
                dev1_total_tx_frames = r1[3]
                dev2_total_rx_frames = r1[4]
		dev2_total_frame_loss = r1[5]
		dev1_avg_txMpps = r1[6]
                
		if (bidirec == 1) then
		    local r2 = {}
		    r2 = loadTask1b:wait()

		    dev2_total_frame_loss_pct = r2[1]
		    dev2_avg_rxMpps = r2[2]
                    dev2_total_tx_frames = r2[3];
                    dev1_total_rx_frames = r2[4];
		    dev1_total_frame_loss = r2[5]
		    dev2_avg_txMpps = r2[6]

		    -- total_frame_loss_pct = (r1[1] +r2[1]) /2
		    -- total_rxMpps = r1[2] +r2[2]
                    avg_device_frame_loss = (dev1_total_frame_loss_pct + dev2_total_frame_loss_pct) / 2
                else
                    avg_device_frame_loss = dev1_total_frame_loss_pct 
		end


                aggregate_avg_rxMpps = dev1_avg_rxMpps + dev2_avg_rxMpps
                
		if (latency == 1) then
			loadTask2a:wait()
		end
		
		t[1] = dev1_total_frame_loss_pct
		t[2] = dev1_avg_rxMpps
                t[3] = dev1_total_tx_frames
                t[4] = dev1_total_rx_frames
		t[5] = dev2_total_frame_loss_pct
		t[6] = dev2_avg_rxMpps
                t[7] = dev2_total_tx_frames
                t[8] = dev2_total_rx_frames
                t[9] = avg_device_frame_loss
                t[10] = aggregate_avg_rxMpps
		t[11] = dev1_total_frame_loss
		t[12] = dev2_total_frame_loss
		t[13] = dev1_avg_txMpps
		t[14] = dev2_avg_txMpps
end

function loadSlave(txQueue, rxQueue, rate, frame_size, run_time, num_flows)
	local frame_size_without_crc = frame_size - 4
	-- TODO: this leaks memory as mempools cannot be deleted in DPDK
	local mem = memory.createMemPool(function(buf)
		buf:getUdpPacket():fill{
			pktLength = frame_size_without_crc, -- this sets all length headers fields in all used protocols
			ethSrc = txQueue, -- get the src mac from the device
			ethDst = ETH_DST,
			-- ipSrc will be set later as it varies
			ip4Dst = IP_DST,
			udpSrc = PORT_SRC,
			udpDst = PORT_DST,
			-- payload will be initialized to 0x00 as new memory pools are initially empty
		}
	end)
	local bufs = mem:bufArray()
	local runtime = timer:new(run_time)
	local rxStats = stats:newDevRxCounter(rxQueue, "plain")
	local txStats = stats:newDevTxCounter(txQueue, "plain")
	local count = 0
	local baseIP = parseIPAddress(IP_SRC)
	while runtime:running() and dpdk.running() do
		bufs:alloc(frame_size_without_crc)
                for _, buf in ipairs(bufs) do
			local pkt = buf:getUdpPacket()
			-- Using random here tends to slow down the Tx rate
			-- pkt.ip4.src:set(baseIP + math.random(num_flows) - 1)
			-- For now, just increment with count and limit with num_flows
			-- Later, maybe consider pre-allocating a list of random IPs
			-- pkt.ip4.src:set(baseIP + count % num_flows)
		        pkt.ip4.src:set(baseIP + count % num_flows)
		end
                bufs:offloadUdpChecksums()
		if rate then
			for _, buf in ipairs(bufs) do
				buf:setRate(rate)
			end
			txQueue:sendWithDelay(bufs)
		else
			txQueue:send(bufs)
		end
		rxStats:update()
		txStats:update()
		count = count + 1
	end
	txStats:finalize()

        local runtime = timer:new(5)
        while runtime:running() and dpdk.running() do
                rxStats:update()
        end
        -- note that the rx rate stats will be skewed because of the previous loop
        rxStats:finalize()
        local loss = txStats.total - rxStats.total
        if (loss < 0 ) then
                loss = 0
        end
        local pct_loss = loss / txStats.total * 100
        -- because the rx rates are skewed, calculate a new rx rate with tx and % loss
        rxStats.mpps.avg = txStats.mpps.avg * (100 - pct_loss) / 100

        local results = {pct_loss, rxStats.mpps.avg, txStats.total, rxStats.total, loss, txStats.mpps.avg}
        return results
end

function timerSlave(txQueue, rxQueue, frame_size, run_time, num_flows, bidirec)
	local frame_size_without_crc = frame_size - 4
	local rxDev = rxQueue.dev
	rxDev:filterTimestamps(rxQueue)
	local timestamper = ts:newUdpTimestamper(txQueue, rxQueue)
	local hist = hist()
	-- timestamping starts after and finishes before the main packet load starts/finishes
	dpdk.sleepMillis(LATENCY_TRIM)
	local runtime = timer:new(run_time - LATENCY_TRIM/1000*2)
	local baseIP = parseIPAddress(IP_SRC)
	local rateLimit = timer:new(0.01)
	while runtime:running() and dpdk.running() do
		--local port = math.random(2048)
		--local lat = timestamper:measureLatency(frame_size_without_crc, function(buf)
		--	local pkt = buf:getUdpPacket()
		--	pkt:fill{
		--		pktLength = frame_size_without_crc, -- this sets all length headers fields in all used protocols
		--		ethSrc = txQueue, -- get the src mac from the device
		--		ethDst = ETH_DST,
		--		-- ipSrc will be set later as it varies
		--		ip4Dst = IP_DST,
		--		udpSrc = PORT_SRC,
		--		udpDst = port,
		--	}
		--	pkt.ip4.src:set(baseIP + math.random(NUM_FLOWS) - 1)
		--end)
		--if lat then
		--	hist:update(lat)
		--end
		rateLimit:wait()
		local lat = timestamper:measureLatency();
		if (lat) then
                	hist:update(lat)
		end
		rateLimit:reset()
	end
	dpdk.sleepMillis(LATENCY_TRIM + 1000) -- the extra 1000 ms ensures the stats are output after the throughput stats
	hist:save("hist.csv")
	hist:print("Histogram")
end