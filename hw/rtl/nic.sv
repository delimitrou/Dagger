// Author: Cornell University
//
// Module Name :    nic
// Project :        F-NIC
// Description :    NIC top-level

`include "afu_json_info.vh"
`include "platform_if.vh"

`include "config_defs.vh"
`include "cpu_if_defs.vh"
//`include "nic_defs.vh"

`include "async_fifo_channel.sv"
`include "ccip_mmio.sv"
`include "ccip_polling.sv"
`include "ccip_queue_polling.sv"
`include "ccip_dma.sv"
`include "nic_counters.sv"
`include "pulse_gen.sv"
`include "rpc.sv"
`include "single_clock_wr_ram.sv"

module nic
    #(
        parameter NIC_ID = 0,
        // MMIO base address
        parameter SRF_BASE_MMIO_ADDRESS = 16'h0,
        // MMIO base address for the AFU_ID register;
        // currently should be 0x00
        parameter SRF_BASE_MMIO_ADDRESS_AFU_ID = 16'h0,
        // Number of upper-level NICs;
        // need to know due to some limitations of CCI-P MUX
        parameter NUM_SUB_AFUS = 1
    )
    (
    input logic clk,
    input logic clk_div_2,
    input logic reset,

    // CPU interface
    input  t_if_ccip_Rx sRx,
    output t_if_ccip_Tx sTx,

`ifdef PHY_NETWORK
    // L1 network interface (used for physical networking)
    // TX Avalon-ST interface
    input              tx_clk_in,
    input              tx_reset_in,
    input              tx_ready_in,
    output reg [255:0] tx_data_out,
    output reg         tx_valid_out,
    output reg         tx_sop_out,
    output reg         tx_eop_out,
    output reg [4:0]   tx_empty_out,
    output reg         tx_error_out,

    // RX Avalon-ST interface
    input           rx_clk_in,
    input           rx_reset_in,
    input   [255:0] rx_data_in,
    input           rx_valid_in,
    input           rx_sop_in,
    input           rx_eop_in,
    input     [4:0] rx_empty_in,
    input     [5:0] rx_error_in,
    output reg      rx_ready_out
`else
    // L4 network interface (used for L4 loopback)
    output logic network_clk_out,
    output NetworkIf network_tx_out,
    input NetworkIf network_rx_in
`endif

    );


    // =============================================================
    // General local config
    // =============================================================
    // log number of max queue sizes
    localparam LMAX_RX_QUEUE_SIZE = 3;   // 2**3=8
    localparam LMAX_TX_QUEUE_SIZE = 8;   // 2**8=256
    // CCI-P VCs
    localparam CCIP_FORWARD_VC       = eVC_VH0; // PCIe
    localparam CCIP_FORWARD_RD_TYPE  = eREQ_RDLINE_I;
    localparam CCIP_BACKWARD_VC      = eVC_VH0; // PCIe
    localparam CCIP_BACKWARD_WR_TYPE = eREQ_WRPUSH_I;
    // Log max CCI-P polling rate
    localparam LMAX_POLLING_RATE = 8;
    // Log depth of the RPC I/O FIFO
    localparam RPC_IO_FIFO_LDEPTH = 3;


    // =============================================================
    // Clocks
    // NOTE: ccip_clk >= rpc_clk
    //       ccip_clk >= network_clk
    // =============================================================
    localparam ccip_clk_hz = 200000000;
    logic ccip_clk;
    assign ccip_clk = clk;

    logic rpc_clk;
    assign rpc_clk = clk_div_2;

    logic network_clk;
    assign network_clk = rpc_clk;


    // =============================================================
    // AFU ID
    // =============================================================
    logic [127:0] afu_id = `AFU_ACCEL_UUID;


    // =============================================================
    // MMIO CSR
    // =============================================================
    // Addredss map
    localparam t_ccip_mmioAddr addrRegMemTxAddr
                        = t_ccip_mmioAddr'(SRF_BASE_MMIO_ADDRESS + 0);
    localparam t_ccip_mmioAddr addrRegMemRxAddr
                        = t_ccip_mmioAddr'(SRF_BASE_MMIO_ADDRESS + 2);
    localparam t_ccip_mmioAddr addrRegNicStart
                        = t_ccip_mmioAddr'(SRF_BASE_MMIO_ADDRESS + 4);
    localparam t_ccip_mmioAddr addrRegNumOfFlows
                        = t_ccip_mmioAddr'(SRF_BASE_MMIO_ADDRESS + 6);
    localparam t_ccip_mmioAddr addrRegInit
                        = t_ccip_mmioAddr'(SRF_BASE_MMIO_ADDRESS + 8);
    localparam t_ccip_mmioAddr addrRegNicStatus
                        = t_ccip_mmioAddr'(SRF_BASE_MMIO_ADDRESS + 10);
    localparam t_ccip_mmioAddr addrRegCcipRps
                        = t_ccip_mmioAddr'(SRF_BASE_MMIO_ADDRESS + 12);
    localparam t_ccip_mmioAddr addrGetPckCnt
                        = t_ccip_mmioAddr'(SRF_BASE_MMIO_ADDRESS + 14);
    localparam t_ccip_mmioAddr addrPckCnt
                        = t_ccip_mmioAddr'(SRF_BASE_MMIO_ADDRESS + 16);
    localparam t_ccip_mmioAddr addrRegNicMode
                        = t_ccip_mmioAddr'(SRF_BASE_MMIO_ADDRESS + 18);
    localparam t_ccip_mmioAddr addrCcipDmaMmio
                        = t_ccip_mmioAddr'(SRF_BASE_MMIO_ADDRESS + 20);
    localparam t_ccip_mmioAddr addrRxQueueSize
                        = t_ccip_mmioAddr'(SRF_BASE_MMIO_ADDRESS + 22);
    localparam t_ccip_mmioAddr addrTxBatchSize
                        = t_ccip_mmioAddr'(SRF_BASE_MMIO_ADDRESS + 24);
    localparam t_ccip_mmioAddr addrRxBatchSize
                        = t_ccip_mmioAddr'(SRF_BASE_MMIO_ADDRESS + 26);
    localparam t_ccip_mmioAddr addrPollingRate
                        = t_ccip_mmioAddr'(SRF_BASE_MMIO_ADDRESS + 28);
    localparam t_ccip_mmioAddr addrConnSetup
                        = t_ccip_mmioAddr'(SRF_BASE_MMIO_ADDRESS + 30);
    localparam t_ccip_mmioAddr addrConnStatus
                        = t_ccip_mmioAddr'(SRF_BASE_MMIO_ADDRESS + 32);
    localparam t_ccip_mmioAddr addrLB
                        = t_ccip_mmioAddr'(SRF_BASE_MMIO_ADDRESS + 34);
    localparam t_ccip_mmioAddr addrPhyNetAddr
                        = t_ccip_mmioAddr'(SRF_BASE_MMIO_ADDRESS + 36);
    localparam t_ccip_mmioAddr addrIPv4NetAddr
                        = t_ccip_mmioAddr'(SRF_BASE_MMIO_ADDRESS + 38);
    localparam t_ccip_mmioAddr addrNetDropCntRead
                        = t_ccip_mmioAddr'(SRF_BASE_MMIO_ADDRESS + 40);
    localparam t_ccip_mmioAddr addrNetDropCnt
                        = t_ccip_mmioAddr'(SRF_BASE_MMIO_ADDRESS + 42);
    localparam t_ccip_mmioAddr addrTxQueueSize
                        = t_ccip_mmioAddr'(SRF_BASE_MMIO_ADDRESS + 44);

    // Registers
    t_ccip_clAddr                  iRegMemTxAddr;
    t_ccip_clAddr                  iRegMemRxAddr;
    logic                          iRegNicStart;
    logic[LMAX_NUM_OF_FLOWS-1:0]   iRegNumOfFlows;    // iRegNumOfFlows = number of flows - 1
    logic                          iRegNicInit;
    NicStatus                      iRegNicStatus;
    logic[31:0]                    iRegCcipRps;
    logic[7:0]                     iRegGetPckCnt;
    logic[63:0]                    iRegPckCnt;
    logic[LMAX_RX_QUEUE_SIZE-1:0]  iRegRxQueueSize;  // iRegRxQueueSize = rx queue size - 1
    logic[LMAX_TX_QUEUE_SIZE:0]    iRegTxQueueSize;
    logic[LMAX_CCIP_BATCH-1:0]     lRegTxBatchSize;
    logic[LMAX_CCIP_DMA_BATCH-1:0] iRegRxBatchSize;
    logic[LMAX_POLLING_RATE-1:0]   iRegPollingRate;
    ConnSetupFrame                 iRegConnSetupFrame;
    logic                          iRegConnSetupFrame_en;
    ConnSetupStatus                iRegConnStatus;
    logic                          iLB;
    PhyAddr                        iRegPhyNetAddr;
    IPv4                           iRegIpv4NetAddr;
    logic                          iRegReadNetDropCntValid;
    logic[4:0]                     iRegReadNetDropCnt;
    logic[63:0]                    iRegNetDropCnt;
    NicMode                        iNicMode;

    // CSR read logic
    logic is_csr_read;
    assign is_csr_read = sRx.c0.mmioRdValid;

    t_ccip_c0_ReqMmioHdr mmio_req_hdr;
    assign mmio_req_hdr = t_ccip_c0_ReqMmioHdr'(sRx.c0.hdr);

    ConnSetupStatus rpc_conn_setup_status;

    always_ff @(posedge ccip_clk) begin
        // Always respond with something
        sTx.c2.mmioRdValid <= is_csr_read;
        sTx.c2.hdr.tid     <= mmio_req_hdr.tid;

        // Addresses are of 32-bit objects in MMIO space.  Addresses
        // of 64-bit objects are thus multiples of 2.
        case (mmio_req_hdr.address)
            // AFU DFH (device feature header)
            SRF_BASE_MMIO_ADDRESS_AFU_ID + 0: begin
                // Here we define a trivial feature list.  In this
                // example, our AFU is the only entry in this list.
                sTx.c2.data <= t_ccip_mmioData'(0);
                // Feature type is AFU
                sTx.c2.data[63:60] <= 4'h1;
                // End of list (last entry in list)
                sTx.c2.data[40] <= 1'b1;
              end

            // AFU_ID_L
            SRF_BASE_MMIO_ADDRESS_AFU_ID + 2: begin
                sTx.c2.data <= afu_id[63:0];
            end

            // AFU_ID_H
            SRF_BASE_MMIO_ADDRESS_AFU_ID + 4: begin
                sTx.c2.data <= afu_id[127:64];
            end

            // DFH_RSVD0
            SRF_BASE_MMIO_ADDRESS_AFU_ID + 6: begin
                sTx.c2.data <= t_ccip_mmioData'(0);
            end

            // DFH_RSVD1
            SRF_BASE_MMIO_ADDRESS_AFU_ID + 8: begin
                sTx.c2.data <= t_ccip_mmioData'(0);
            end

            // Status
            addrRegNicStatus: begin
                sTx.c2.data[$bits(iRegNicStatus)-1:0] <= iRegNicStatus;
            end

            // Perf
            addrRegCcipRps: begin
                sTx.c2.data[$bits(iRegCcipRps)-1:0] <= iRegCcipRps;
            end

            // Counters
            addrPckCnt: begin
                sTx.c2.data[$bits(iRegPckCnt)-1:0] <= iRegPckCnt;
            end

            addrRegNicMode: begin
                sTx.c2.data[$bits(iNicMode)-1:0] <= iNicMode;
            end

            addrConnStatus: begin
                sTx.c2.data[$bits(ConnSetupStatus)-1:0] <= iRegConnStatus;

                // Zero-out conenction status
                iRegConnStatus <= {($bits(iRegConnStatus)){1'b0}};
            end

            addrNetDropCnt: begin
                sTx.c2.data <= iRegNetDropCnt;
            end

            default: sTx.c2.data <= t_ccip_mmioData'(0);
        endcase

        // Save rpc connection status
        if (rpc_conn_setup_status.valid) begin
            iRegConnStatus <= rpc_conn_setup_status;
        end

        if (reset) begin
            sTx.c2.mmioRdValid <= 1'b0;
        end
    end

    // CSR write logic
    logic is_csr_write;
    assign is_csr_write = sRx.c0.mmioWrValid;

    logic is_mem_tx_addr_csr_write;
    assign is_mem_tx_addr_csr_write = is_csr_write &&
                                      (mmio_req_hdr.address == addrRegMemTxAddr);

    logic is_mem_rx_addr_csr_write;
    assign is_mem_rx_addr_csr_write = is_csr_write &&
                                      (mmio_req_hdr.address == addrRegMemRxAddr);

    logic is_nic_start_csr_write;
    assign is_nic_start_csr_write = is_csr_write &&
                                    (mmio_req_hdr.address == addrRegNicStart);

    logic is_num_of_flows_csr_write;
    assign is_num_of_flows_csr_write = is_csr_write &&
                                       (mmio_req_hdr.address == addrRegNumOfFlows);

    logic is_init_csr_write;
    assign is_init_csr_write = is_csr_write &&
                               (mmio_req_hdr.address == addrRegInit);

    logic is_get_nic_cnt_csr_write;
    assign is_get_nic_cnt_csr_write = is_csr_write &&
                                      (mmio_req_hdr.address == addrGetPckCnt);

    logic is_rx_queue_size_csr_write;
    assign is_rx_queue_size_csr_write = is_csr_write &&
                                        (mmio_req_hdr.address == addrRxQueueSize);

    logic is_tx_queue_size_csr_write;
    assign is_tx_queue_size_csr_write = is_csr_write &&
                                        (mmio_req_hdr.address == addrTxQueueSize);

    logic is_tx_batch_size_csr_write;
    assign is_tx_batch_size_csr_write = is_csr_write &&
                                        (mmio_req_hdr.address == addrTxBatchSize);

    logic is_rx_batch_size_csr_write;
    assign is_rx_batch_size_csr_write = is_csr_write &&
                                        (mmio_req_hdr.address == addrRxBatchSize);

    logic is_polling_rate_csr_write;
    assign is_polling_rate_csr_write = is_csr_write &&
                                        (mmio_req_hdr.address == addrPollingRate);

    logic is_conn_setup_frame_write;
    assign is_conn_setup_frame_write = is_csr_write &&
                                        (mmio_req_hdr.address == addrConnSetup);

    logic is_lb_write;
    assign is_lb_write = is_csr_write &&
                                        (mmio_req_hdr.address == addrLB);

    logic is_phy_net_addr_write;
    assign is_phy_net_addr_write = is_csr_write &&
                                        (mmio_req_hdr.address == addrPhyNetAddr);

    logic is_ipv4_net_addr_write;
    assign is_ipv4_net_addr_write = is_csr_write &&
                                        (mmio_req_hdr.address == addrIPv4NetAddr);

    logic is_net_drop_cnt_read;
    assign is_net_drop_cnt_read = is_csr_write &&
                                        (mmio_req_hdr.address == addrNetDropCntRead);

    always_ff @(posedge ccip_clk) begin
        // Default values
        iRegNicInit <= 1'b0;
        iRegConnSetupFrame_en <= 1'b0;
        iRegReadNetDropCntValid <= 1'b0;

        if (is_mem_tx_addr_csr_write) begin
            $display("NIC%d: iRegMemTxAddr configured: %08h", NIC_ID, sRx.c0.data);
            iRegMemTxAddr <= t_ccip_clAddr'(sRx.c0.data);
        end

        if (is_mem_rx_addr_csr_write) begin
            $display("NIC%d: iRegMemRxAddr configured: %08h", NIC_ID, sRx.c0.data);
            iRegMemRxAddr <= t_ccip_clAddr'(sRx.c0.data);
        end

        if (is_nic_start_csr_write) begin
            $display("NIC%d: iRegNicStart configured: %08h", NIC_ID, sRx.c0.data);
            iRegNicStart <= sRx.c0.data[0];
        end

        if (is_num_of_flows_csr_write) begin
            $display("NIC%d: iRegNumOfFlows configured: %08h", NIC_ID, sRx.c0.data);
            iRegNumOfFlows <= sRx.c0.data[LMAX_NUM_OF_FLOWS-1:0] - 1;
        end

        if (is_init_csr_write) begin
            $display("NIC%d: iRegNicInit received", NIC_ID);
            iRegNicInit <= 1;
        end

        if (is_get_nic_cnt_csr_write) begin
            $display("NIC%d: iRegGetPckCnt received: %08h", NIC_ID, sRx.c0.data);
            iRegGetPckCnt <= sRx.c0.data[7:0];
        end

        if (is_rx_queue_size_csr_write) begin
            $display("NIC%d: iRegRxQueueSize received: %08h", NIC_ID, sRx.c0.data);
            iRegRxQueueSize <= sRx.c0.data[LMAX_RX_QUEUE_SIZE-1:0] - 1;
        end

        if (is_tx_queue_size_csr_write) begin
            $display("NIC%d: iRegTxQueueSize received: %08h", NIC_ID, sRx.c0.data);
            iRegTxQueueSize <= sRx.c0.data[LMAX_TX_QUEUE_SIZE:0];
        end

        if (is_tx_batch_size_csr_write) begin
            $display("NIC%d: lRegTxBatchSize received: %08h", NIC_ID, sRx.c0.data);
            lRegTxBatchSize <= sRx.c0.data[LMAX_CCIP_BATCH-1:0];
        end

        if (is_rx_batch_size_csr_write) begin
            $display("NIC%d: iRegRxBatchSize received: %08h", NIC_ID, sRx.c0.data);
            iRegRxBatchSize <= sRx.c0.data[LMAX_CCIP_DMA_BATCH-1:0];
        end

        if (is_polling_rate_csr_write) begin
            $display("NIC%d: iRegPollingRate received: %08h", NIC_ID, sRx.c0.data);
            iRegPollingRate <= sRx.c0.data[LMAX_POLLING_RATE-1:0];
        end

        if (is_conn_setup_frame_write) begin
            $display("NIC%d: iRegConnSetupFrame received: %08h", NIC_ID, sRx.c0.data);
            iRegConnSetupFrame <= sRx.c0.data[$bits(ConnSetupFrame)-1:0];
            iRegConnSetupFrame_en <= 1'b1;
        end

        if (is_lb_write) begin
            iLB <= sRx.c0.data[$bits(iLB)-1:0];
        end

        if (is_phy_net_addr_write) begin
            iRegPhyNetAddr.b0 <= sRx.c0.data[7:0];
            iRegPhyNetAddr.b1 <= sRx.c0.data[15:8];
            iRegPhyNetAddr.b2 <= sRx.c0.data[23:16];
            iRegPhyNetAddr.b3 <= sRx.c0.data[31:24];
            iRegPhyNetAddr.b4 <= sRx.c0.data[39:32];
            iRegPhyNetAddr.b5 <= sRx.c0.data[47:40];
        end

        if (is_ipv4_net_addr_write) begin
            iRegIpv4NetAddr.b0 <= sRx.c0.data[7:0];
            iRegIpv4NetAddr.b1 <= sRx.c0.data[15:8];
            iRegIpv4NetAddr.b2 <= sRx.c0.data[23:16];
            iRegIpv4NetAddr.b3 <= sRx.c0.data[31:24];
        end

        if (is_net_drop_cnt_read) begin
            iRegReadNetDropCnt <= sRx.c0.data[3:0];
            iRegReadNetDropCntValid <= 1'b1;
        end

        if (reset) begin
            iRegNicStart <= 1'b0;
            iRegNicInit  <= 1'b0;
            iRegConnSetupFrame_en <= 1'b0;
            iRegReadNetDropCntValid <= 1'b0;
        end
    end


    // =============================================================
    // CCI-P layer
    // =============================================================
    logic ccip_layer_initialized;

    RpcIf from_ccip;
    logic from_ccip_valid;

    logic ccip_tx_ready;
    RpcIf to_ccip;
    logic to_ccip_valid;

    logic pdrop_tx_flows;
    logic ccip_error;

`ifdef CCIP_MMIO
    $info("Building CCI-P MMIO-based nic");

    ccip_mmio #(
        .NIC_ID(NIC_ID),
        .LMAX_NUM_OF_FLOWS(LMAX_NUM_OF_FLOWS),
        .LMAX_TX_QUEUE_SIZE(LMAX_TX_QUEUE_SIZE)
    ) ccip_mmio (
        .clk(ccip_clk),
        .reset(reset),

        .number_of_flows(iRegNumOfFlows),
        .rx_base_addr(iRegMemRxAddr),
        .tx_base_addr(iRegMemTxAddr),
        .l_tx_batch_size(lRegTxBatchSize),
        .tx_queue_size(iRegTxQueueSize),
        .start(iRegNicStart),

        .initialize(iRegNicInit),
        .initialized(ccip_layer_initialized),
        .error(ccip_error),

        .sRx_c0TxAlmFull(sRx.c0TxAlmFull),
        .sRx_c1TxAlmFull(sRx.c1TxAlmFull),
        .sRx_c0MMIOWrValid(sRx.c0.mmioWrValid),
        .sRx_c0(sRx.c0),
        .sTx_c1(sTx.c1),

        .rpc_out(from_ccip.rpc_data),
        .rpc_out_valid(from_ccip_valid),
        .rpc_flow_id_out(from_ccip.flow_id),

        .lb_select(iLB),

        .ccip_tx_ready(ccip_tx_ready),
        .rpc_in(to_ccip.rpc_data),
        .rpc_in_valid(to_ccip_valid),
        .rpc_flow_id_in(to_ccip.flow_id),

        .pdrop_tx_flows_out(pdrop_tx_flows)
    );

    // Set NIC mode infrmation register
    assign iNicMode.ccip_mode = ccipMMIO;

`elsif CCIP_POLLING
    $info("Building CCI-P polling-based nic");

    ccip_polling #(
        .NIC_ID(NIC_ID),
        .LMAX_NUM_OF_FLOWS(LMAX_NUM_OF_FLOWS),
        .NUM_SUB_AFUS(NUM_SUB_AFUS),
        .FORWARD_VC(CCIP_FORWARD_VC),
        .FORWARD_RD_TYPE(CCIP_FORWARD_RD_TYPE),
        .BACKWARD_VC(CCIP_BACKWARD_VC),
        .BACKWARD_WR_TYPE(CCIP_BACKWARD_WR_TYPE),
        .POLLING_RATE(CCIP_POLLING_RATE)
    ) ccip_poll (
        .clk(ccip_clk),
        .reset(reset),

        .rx_base_addr(iRegMemRxAddr),
        .tx_base_addr(iRegMemTxAddr),
        .number_of_flows(iRegNumOfFlows),
        .start(iRegNicStart),

        .initialize(iRegNicInit),
        .initialized(ccip_layer_initialized),

        .sRx_c0TxAlmFull(sRx.c0TxAlmFull),
        .sRx_c1TxAlmFull(sRx.c1TxAlmFull),
        .sRx_c0(sRx.c0),
        .sTx_c0(sTx.c0),
        .sTx_c1(sTx.c1),

        .rpc_out(from_ccip.rpc_data),
        .rpc_out_valid(from_ccip_valid),
        .rpc_flow_id_out(from_ccip.flow_id),

        .ccip_tx_ready(ccip_tx_ready),
        .rpc_in(to_ccip.rpc_data),
        .rpc_in_valid(to_ccip_valid),
        .rpc_flow_id_in(to_ccip.flow_id),

        .pdrop_tx_flows_out(pdrop_tx_flows)
    );

    // Set NIC mode infrmation register
    assign iNicMode.ccip_mode = ccipPolling;

`elsif CCIP_DMA
    $info("Building CCI-P DMA-based nic");

    ccip_dma #(
        .NIC_ID(NIC_ID),
        .LMAX_NUM_OF_FLOWS(LMAX_NUM_OF_FLOWS),
        .NUM_SUB_AFUS(NUM_SUB_AFUS)
    ) ccip_dma (
        .clk(ccip_clk),
        .reset(reset),

        .number_of_flows(iRegNumOfFlows),
        .rx_mmio_addr(addrCcipDmaMmio),
        .rx_base_addr(iRegMemRxAddr),
        .rx_batch_size(iRegRxBatchSize),
        .tx_base_addr(iRegMemTxAddr),
        .l_tx_batch_size(lRegTxBatchSize),

        .start(iRegNicStart),

        .initialize(iRegNicInit),
        .initialized(ccip_layer_initialized),
        .error(ccip_error),

        .sRx_c0TxAlmFull(sRx.c0TxAlmFull),
        .sRx_c1TxAlmFull(sRx.c1TxAlmFull),
        .sRx_c0MMIOWrValid(sRx.c0.mmioWrValid),
        .sRx_c0(sRx.c0),
        .sTx_c0(sTx.c0),
        .sTx_c1(sTx.c1),

        .rpc_out(from_ccip.rpc_data),
        .rpc_out_valid(from_ccip_valid),
        .rpc_flow_id_out(from_ccip.flow_id),

        .ccip_tx_ready(ccip_tx_ready),
        .rpc_in(to_ccip.rpc_data),
        .rpc_in_valid(to_ccip_valid),
        .rpc_flow_id_in(to_ccip.flow_id),

        .pdrop_tx_flows_out(pdrop_tx_flows)
    );

    // Set NIC mode infrmation register
    assign iNicMode.ccip_mode = ccipDMA;

`elsif CCIP_QUEUE_POLLING
    $info("Building CCI-P polling-based nic with queues");

    ccip_queue_polling #(
        .NIC_ID(NIC_ID),
        .NUM_SUB_AFUS(NUM_SUB_AFUS),
        .LMAX_POLLING_RATE(LMAX_POLLING_RATE),
        .LMAX_NUM_OF_FLOWS(LMAX_NUM_OF_FLOWS),
        .LMAX_RX_QUEUE_SIZE(LMAX_RX_QUEUE_SIZE),
        .LMAX_TX_QUEUE_SIZE(LMAX_TX_QUEUE_SIZE)
    ) ccip_queue_poll (
        .clk(ccip_clk),
        .reset(reset),

        .number_of_flows(iRegNumOfFlows),
        .rx_base_addr(iRegMemRxAddr),
        .rx_bk_base_addr(),
        .rx_queue_size(iRegRxQueueSize),
        .tx_base_addr(iRegMemTxAddr),
        .l_tx_batch_size(lRegTxBatchSize),
        .tx_queue_size(iRegTxQueueSize),
        .tx_polling_rate(iRegPollingRate),

        .start(iRegNicStart),

        .initialize(iRegNicInit),
        .initialized(ccip_layer_initialized),
        .error(ccip_error),

        .sRx_c0TxAlmFull(sRx.c0TxAlmFull),
        .sRx_c1TxAlmFull(sRx.c1TxAlmFull),
        .sRx_c0(sRx.c0),
        .sTx_c0(sTx.c0),
        .sTx_c1(sTx.c1),

        .rpc_out(from_ccip.rpc_data),
        .rpc_out_valid(from_ccip_valid),
        .rpc_flow_id_out(from_ccip.flow_id),

        .lb_select(iLB),

        .ccip_tx_ready(ccip_tx_ready),
        .rpc_in(to_ccip.rpc_data),
        .rpc_in_valid(to_ccip_valid),
        .rpc_flow_id_in(to_ccip.flow_id),

        .pdrop_tx_flows_out(pdrop_tx_flows)
    );

    // Set NIC mode infrmation register
    assign iNicMode.ccip_mode = ccipQueuePolling;

`else
    $error("** Illegal Configuration ** CCI-P mode is not set");

`endif


    // =============================================================
    // RPC layer
    // =============================================================
    // To RPC channel
    logic rpc_rx_fifo_error;

    RpcIf to_rpc;
    logic to_rpc_valid;

    NetworkIf network_tx, network_rx;

    async_fifo_channel #(
            .DATA_WIDTH($bits(RpcIf)),
            .LOG_DEPTH(RPC_IO_FIFO_LDEPTH)
        )
    ccip_to_rpc_fifo_channel (
            .clear(reset),
            .clk_1(ccip_clk),
            .push_en(from_ccip_valid),
            .push_data(from_ccip),
            .clk_2(rpc_clk),
            .pop_enable(1'b1),
            .pop_valid(to_rpc_valid),
            .pop_data(to_rpc),
            .pop_dw(),
            .loss_out(),
            .error(rpc_rx_fifo_error)
        );

    // From RPC channel
    logic rpc_tx_fifo_error;

    RpcIf from_rpc;
    logic from_rpc_valid;

    async_fifo_channel #(
            .DATA_WIDTH($bits(RpcIf)),
            .LOG_DEPTH(RPC_IO_FIFO_LDEPTH)
        )
    rpc_to_ccip_fifo_channel (
            .clear(reset),
            .clk_1(rpc_clk),
            .push_en(from_rpc_valid),
            .push_data(from_rpc),
            .clk_2(ccip_clk),
            .pop_enable(ccip_tx_ready),
            .pop_valid(to_ccip_valid),
            .pop_data(to_ccip),
            .pop_dw(),
            .loss_out(),
            .error(rpc_tx_fifo_error)
        );

    // RPC processing
    // FIFO to synch the RF and RPC
    ConnSetupFrame conn_setup_frame;
    logic conn_setup_en;
    async_fifo_channel #(
            .DATA_WIDTH($bits(iRegConnSetupFrame)),
            .LOG_DEPTH(RPC_IO_FIFO_LDEPTH)
        )
    fr_to_rpc_fifo_channel (
            .clear(reset),
            .clk_1(ccip_clk),
            .push_en(iRegConnSetupFrame_en),
            .push_data(iRegConnSetupFrame),
            .clk_2(rpc_clk),
            .pop_enable(1'b1),
            .pop_valid(conn_setup_en),
            .pop_data(conn_setup_frame),
            .pop_dw(),
            .loss_out(),
            .error()
        );

    // Generate rpc initialization pulse (2 ccip cycles)
    logic rpc_init;
    pulse_gen #(2) init_pulse_gen (
            .clk(ccip_clk),
            .reset(reset),
            .sig_in(iRegNicInit),
            .pulse_out(rpc_init)
        );

    rpc #(NIC_ID) rpc_ (
            .clk(rpc_clk),
            .reset(reset),

            .initialize(rpc_init),
            .initialized(rpc_initialized),
            .error(rpc_error),

            .conn_setup_en_in(conn_setup_en),
            .conn_setup_frame_in(conn_setup_frame),
            .conn_setup_status_out(rpc_conn_setup_status),

            .rpc_valid_in(to_rpc_valid),
            .rpc_in(to_rpc),
            .rpc_valid_out(from_rpc_valid),
            .rpc_out(from_rpc),

            .network_tx_out(network_tx),
            .network_rx_in(network_rx)
        );


    // =============================================================
    // Networking layer
    // =============================================================
    // Dump network packets (as $display)
    always @(posedge network_clk) begin
        if (network_tx.valid) begin
            $display("NIC%d: network TX packet requested %p", NIC_ID, network_tx);
        end
        if (network_rx.valid) begin
            $display("NIC%d: network RX packet requested %p", NIC_ID, network_rx);
        end
    end

`ifdef PHY_NETWORK
    // UDP/IP
    udp_ip udp_ (
            .host_phy_addr(iRegPhyNetAddr),
            .host_ipv4_addr(iRegIpv4NetAddr),

            .clk(network_clk),
            .reset(reset),
            .network_tx_in(network_tx),
            .network_tx_size_in(16'd64),
            .network_rx_out(network_rx),

            .tx_clk_in (tx_clk_in),
            .tx_reset_in (tx_reset_in),
            .tx_ready_in (tx_ready_in),
            .tx_data_out (tx_data_out),
            .tx_valid_out (tx_valid_out),
            .tx_sop_out (tx_sop_out),
            .tx_eop_out (tx_eop_out),
            .tx_empty_out (tx_empty_out),
            .tx_error_out (tx_error_out),

            .rx_clk_in (rx_clk_in),
            .rx_reset_in (rx_reset_in),
            .rx_data_in (rx_data_in),
            .rx_valid_in (rx_valid_in),
            .rx_sop_in (rx_sop_in),
            .rx_eop_in (rx_eop_in),
            .rx_empty_in (rx_empty_in),
            .rx_error_in (rx_error_in),
            .rx_ready_out (rx_ready_out),

            .pckt_drop_cnt_in(iRegReadNetDropCnt),
            .pckt_drop_cnt_valid_in(iRegReadNetDropCntValid),
            .pckt_drop_cnt_out(iRegNetDropCnt),

            .error()
        );

    // Set NIC mode infrmation register
    assign iNicMode.phy_network_mode = PhyNetEnabled;

`else
    // L4 I/O
    assign network_clk_out = network_clk;
    assign network_tx_out = network_tx;
    assign network_rx = network_rx_in;

    // Set NIC mode infrmation register
    assign iNicMode.phy_network_mode = PhyNetDisabled;

`endif


    // =============================================================
    // NIC status
    // =============================================================
    // NOTE: careful with crossing clock domains here
    logic system_initialized;
    assign system_initialized = ccip_layer_initialized &
                                rpc_initialized;

    always @(posedge ccip_clk) begin
        if (reset) begin
            iRegNicStatus         <= {($bits(iRegNicStatus)){1'b0}};
            iRegNicStatus.nic_id  <= NIC_ID;
            iRegNicStatus.ready   <= 1'b0;
            iRegNicStatus.running <= 1'b0;

        end else begin
            iRegNicStatus.nic_id <= NIC_ID;

            // Runnig status
            iRegNicStatus.ready   <= system_initialized;
            iRegNicStatus.running <= system_initialized & iRegNicStart;

            // Errors
            iRegNicStatus.err_rpcRxFifoOvf <= rpc_rx_fifo_error;
            iRegNicStatus.err_rpcTxFifoOvf <= rpc_tx_fifo_error;
            iRegNicStatus.err_ccip         <= ccip_error;
            iRegNicStatus.err_rpc          <= rpc_error;

            iRegNicStatus.error <= rpc_rx_fifo_error |
                                   rpc_tx_fifo_error |
                                   ccip_error |
                                   rpc_error;

        end
    end


    // =============================================================
    // Performance counters
    // =============================================================
    logic [$bits(iRegCcipRps)-1:0] rps_cnt;
    logic [$bits(iRegCcipRps)-1:0] ccip_rps_rate;
    logic from_ccip_valid_reg;

    always @(posedge ccip_clk) begin
        if (reset) begin
            from_ccip_valid_reg <= 1'b0;
            rps_cnt             <= {($bits(iRegCcipRps)){1'b0}};
            ccip_rps_rate       <= {($bits(iRegCcipRps)){1'b0}};
            iRegCcipRps         <= {($bits(iRegCcipRps)){1'b0}};

        end else begin
            from_ccip_valid_reg <= from_ccip_valid;

            if (from_ccip_valid_reg) begin
                ccip_rps_rate <= ccip_rps_rate + 1;
            end

            // Count 1 sec
            if (rps_cnt == ccip_clk_hz) begin
                iRegCcipRps   <= ccip_rps_rate;
                ccip_rps_rate <= {($bits(iRegCcipRps)){1'b0}};
                rps_cnt       <= {($bits(iRegCcipRps)){1'b0}};

            end else begin
                rps_cnt <= rps_cnt + 1;
            end

        end
    end


    // =============================================================
    // Packet counters
    // =============================================================
    nic_counters nic_pck_counters_ (
            .reset(reset),

            .clk_0(ccip_clk),
            .t_incoming_rpc(from_ccip_valid),
            .t_outcoming_rpc(to_ccip_valid),
            .t_pdrop_tx_flows(pdrop_tx_flows),

            .clk_1(network_clk),
            .t_outcoming_network_packets(network_tx.valid),
            .t_incoming_network_packets(network_rx.valid),

            .clk_io(ccip_clk),
            .counter_id_in(iRegGetPckCnt),
            .counter_value_out(iRegPckCnt)
        );


endmodule
