`include "define.sv"

// Cache bridge wrapper for direct connection to AXI crossbar interface slots.
module bridge_top (
    input                       aclk,
    input                       arst_n,

    input                       icache_req_valid,
    output                      icache_req_ready,
    input      [`InstAddrBus]   icache_req_addr,
    output                      icache_rsp_valid,
    output     [`InstBus]       icache_rsp_rdata,

    input                       dcache_req_valid,
    output                      dcache_req_ready,
    input      [`DataAddrBus]   dcache_req_addr,
    input      [`DataBus]       dcache_req_wdata,
    input      [3:0]            dcache_req_wstrb,
    input                       dcache_req_write,
    output                      dcache_rsp_valid,
    output     [`DataBus]       dcache_rsp_rdata,

    input                       ldr_req_valid,
    output                      ldr_req_ready,
    input      [`DataAddrBus]   ldr_req_addr,
    input      [`DataBus]       ldr_req_wdata,
    input      [3:0]            ldr_req_wstrb,
    output                      ldr_rsp_valid,
    input                       ldr_rsp_ready,
    output                      ldr_rsp_error,

    input      [`ByteWidth]     dbg_uart_tx_data,
    input                       dbg_uart_tx_valid,
    output                      dbg_uart_tx_ready,
    output                      dbg_rsp_valid,
    input                       dbg_rsp_ready,
    output                      dbg_rsp_error,

    // CPU MEM stage -> MMIO AXI master bridge.
    input                       mmio_req_valid,
    output                      mmio_req_ready,
    input      [`DataAddrBus]   mmio_req_addr,
    input      [`DataBus]       mmio_req_wdata,
    input      [3:0]            mmio_req_wstrb,
    input                       mmio_req_write,
    output                      mmio_rsp_valid,
    input                       mmio_rsp_ready,
    output     [`DataBus]       mmio_rsp_rdata,

    // AXI MMIO slave bridge -> MMIO router.
    output                      router_req_valid,
    input                       router_req_ready,
    output     [`DataAddrBus]   router_req_addr,
    output     [`DataBus]       router_req_wdata,
    output     [3:0]            router_req_wstrb,
    output                      router_req_write,
    input                       router_rsp_valid,
    output                      router_rsp_ready,
    input      [`DataBus]       router_rsp_rdata,

    // Connect to crossbar read slot 0.
    taxi_axi_if.rd_mst          m_axi_rd,
    // Connect to crossbar read/write slot 1.
    taxi_axi_if.rd_mst          dcache_axi_rd,
    taxi_axi_if.wr_mst          dcache_axi_wr,
    // Connect to crossbar write slot 2.
    taxi_axi_if.wr_mst          loader_axi_wr,
    // Connect the CPU UART/MMIO writer to crossbar write slot 3.
    taxi_axi_if.wr_mst          uart_axi_wr,
    // Connect the CPU generic MMIO bridge to a crossbar input slot.
    taxi_axi_if.rd_mst          mmio_axi_rd,
    taxi_axi_if.wr_mst          mmio_axi_wr,
    // Connect the crossbar MMIO output slot to the native MMIO router.
    taxi_axi_if.rd_slv          mmio_target_axi_rd,
    taxi_axi_if.wr_slv          mmio_target_axi_wr
);

icache_bridge u_icache_bridge (
    .aclk              (aclk),
    .arst_n            (arst_n),

    .icache_req_valid  (icache_req_valid),
    .icache_req_ready  (icache_req_ready),
    .icache_req_addr   (icache_req_addr),
    .icache_rsp_valid  (icache_rsp_valid),
    .icache_rsp_rdata  (icache_rsp_rdata),

    .m_axi_rid         (m_axi_rd.rid),
    .m_axi_rdata       (m_axi_rd.rdata),
    .m_axi_rresp       (m_axi_rd.rresp),
    .m_axi_rlast       (m_axi_rd.rlast),
    .m_axi_ruser       (m_axi_rd.ruser),
    .m_axi_rvalid      (m_axi_rd.rvalid),
    .m_axi_rready      (m_axi_rd.rready),

    .m_axi_araddr      (m_axi_rd.araddr),
    .m_axi_arlen       (m_axi_rd.arlen),
    .m_axi_arsize      (m_axi_rd.arsize),
    .m_axi_arburst     (m_axi_rd.arburst),
    .m_axi_arvalid     (m_axi_rd.arvalid),
    .m_axi_arready     (m_axi_rd.arready),
    .m_axi_arid        (m_axi_rd.arid),
    .m_axi_arlock      (m_axi_rd.arlock),
    .m_axi_arcache     (m_axi_rd.arcache),
    .m_axi_arprot      (m_axi_rd.arprot),
    .m_axi_arqos       (m_axi_rd.arqos),
    .m_axi_arregion    (m_axi_rd.arregion),
    .m_axi_aruser      (m_axi_rd.aruser)
);

dcache_bridge u_dcache_bridge (
    .aclk              (aclk),
    .arst_n            (arst_n),

    .dcache_req_valid  (dcache_req_valid),
    .dcache_req_ready  (dcache_req_ready),
    .dcache_req_addr   (dcache_req_addr),
    .dcache_req_wdata  (dcache_req_wdata),
    .dcache_req_wstrb  (dcache_req_wstrb),
    .dcache_req_write  (dcache_req_write),
    .dcache_rsp_valid  (dcache_rsp_valid),
    .dcache_rsp_rdata  (dcache_rsp_rdata),

    .m_axi_wdata       (dcache_axi_wr.wdata),
    .m_axi_wstrb       (dcache_axi_wr.wstrb),
    .m_axi_wlast       (dcache_axi_wr.wlast),
    .m_axi_wuser       (dcache_axi_wr.wuser),
    .m_axi_wvalid      (dcache_axi_wr.wvalid),
    .m_axi_wready      (dcache_axi_wr.wready),

    .m_axi_awid        (dcache_axi_wr.awid),
    .m_axi_awaddr      (dcache_axi_wr.awaddr),
    .m_axi_awlen       (dcache_axi_wr.awlen),
    .m_axi_awsize      (dcache_axi_wr.awsize),
    .m_axi_awburst     (dcache_axi_wr.awburst),
    .m_axi_awlock      (dcache_axi_wr.awlock),
    .m_axi_awcache     (dcache_axi_wr.awcache),
    .m_axi_awprot      (dcache_axi_wr.awprot),
    .m_axi_awqos       (dcache_axi_wr.awqos),
    .m_axi_awregion    (dcache_axi_wr.awregion),
    .m_axi_awuser      (dcache_axi_wr.awuser),
    .m_axi_awvalid     (dcache_axi_wr.awvalid),
    .m_axi_awready     (dcache_axi_wr.awready),

    .m_axi_bid         (dcache_axi_wr.bid),
    .m_axi_bresp       (dcache_axi_wr.bresp),
    .m_axi_buser       (dcache_axi_wr.buser),
    .m_axi_bvalid      (dcache_axi_wr.bvalid),
    .m_axi_bready      (dcache_axi_wr.bready),

    .m_axi_arid        (dcache_axi_rd.arid),
    .m_axi_araddr      (dcache_axi_rd.araddr),
    .m_axi_arlen       (dcache_axi_rd.arlen),
    .m_axi_arsize      (dcache_axi_rd.arsize),
    .m_axi_arburst     (dcache_axi_rd.arburst),
    .m_axi_arlock      (dcache_axi_rd.arlock),
    .m_axi_arcache     (dcache_axi_rd.arcache),
    .m_axi_arprot      (dcache_axi_rd.arprot),
    .m_axi_arqos       (dcache_axi_rd.arqos),
    .m_axi_arregion    (dcache_axi_rd.arregion),
    .m_axi_aruser      (dcache_axi_rd.aruser),
    .m_axi_arvalid     (dcache_axi_rd.arvalid),
    .m_axi_arready     (dcache_axi_rd.arready),

    .m_axi_rid         (dcache_axi_rd.rid),
    .m_axi_rdata       (dcache_axi_rd.rdata),
    .m_axi_rresp       (dcache_axi_rd.rresp),
    .m_axi_rlast       (dcache_axi_rd.rlast),
    .m_axi_ruser       (dcache_axi_rd.ruser),
    .m_axi_rvalid      (dcache_axi_rd.rvalid),
    .m_axi_rready      (dcache_axi_rd.rready)
);

loader_bridge u_loader_bridge (
    .aclk              (aclk),
    .arst_n            (arst_n),

    .ldr_req_valid     (ldr_req_valid),
    .ldr_req_ready     (ldr_req_ready),
    .ldr_req_addr      (ldr_req_addr),
    .ldr_req_wdata     (ldr_req_wdata),
    .ldr_req_wstrb     (ldr_req_wstrb),

    .ldr_rsp_valid     (ldr_rsp_valid),
    .ldr_rsp_ready     (ldr_rsp_ready),
    .ldr_rsp_error     (ldr_rsp_error),

    .m_axi_wdata       (loader_axi_wr.wdata),
    .m_axi_wstrb       (loader_axi_wr.wstrb),
    .m_axi_wlast       (loader_axi_wr.wlast),
    .m_axi_wuser       (loader_axi_wr.wuser),
    .m_axi_wvalid      (loader_axi_wr.wvalid),
    .m_axi_wready      (loader_axi_wr.wready),

    .m_axi_awid        (loader_axi_wr.awid),
    .m_axi_awaddr      (loader_axi_wr.awaddr),
    .m_axi_awlen       (loader_axi_wr.awlen),
    .m_axi_awsize      (loader_axi_wr.awsize),
    .m_axi_awburst     (loader_axi_wr.awburst),
    .m_axi_awlock      (loader_axi_wr.awlock),
    .m_axi_awcache     (loader_axi_wr.awcache),
    .m_axi_awprot      (loader_axi_wr.awprot),
    .m_axi_awqos       (loader_axi_wr.awqos),
    .m_axi_awregion    (loader_axi_wr.awregion),
    .m_axi_awuser      (loader_axi_wr.awuser),
    .m_axi_awvalid     (loader_axi_wr.awvalid),
    .m_axi_awready     (loader_axi_wr.awready),

    .m_axi_bid         (loader_axi_wr.bid),
    .m_axi_bresp       (loader_axi_wr.bresp),
    .m_axi_buser       (loader_axi_wr.buser),
    .m_axi_bvalid      (loader_axi_wr.bvalid),
    .m_axi_bready      (loader_axi_wr.bready)
);

uart_bridge u_uart_bridge (
    .aclk              (aclk),
    .arst_n            (arst_n),

    .dbg_uart_tx_data  (dbg_uart_tx_data),
    .dbg_uart_tx_valid (dbg_uart_tx_valid),
    .dbg_uart_tx_ready (dbg_uart_tx_ready),

    .dbg_rsp_valid     (dbg_rsp_valid),
    .dbg_rsp_ready     (dbg_rsp_ready),
    .dbg_rsp_error     (dbg_rsp_error),

    .m_axi_wdata       (uart_axi_wr.wdata),
    .m_axi_wstrb       (uart_axi_wr.wstrb),
    .m_axi_wlast       (uart_axi_wr.wlast),
    .m_axi_wuser       (uart_axi_wr.wuser),
    .m_axi_wvalid      (uart_axi_wr.wvalid),
    .m_axi_wready      (uart_axi_wr.wready),

    .m_axi_awid        (uart_axi_wr.awid),
    .m_axi_awaddr      (uart_axi_wr.awaddr),
    .m_axi_awlen       (uart_axi_wr.awlen),
    .m_axi_awsize      (uart_axi_wr.awsize),
    .m_axi_awburst     (uart_axi_wr.awburst),
    .m_axi_awlock      (uart_axi_wr.awlock),
    .m_axi_awcache     (uart_axi_wr.awcache),
    .m_axi_awprot      (uart_axi_wr.awprot),
    .m_axi_awqos       (uart_axi_wr.awqos),
    .m_axi_awregion    (uart_axi_wr.awregion),
    .m_axi_awuser      (uart_axi_wr.awuser),
    .m_axi_awvalid     (uart_axi_wr.awvalid),
    .m_axi_awready     (uart_axi_wr.awready),

    .m_axi_bid         (uart_axi_wr.bid),
    .m_axi_bresp       (uart_axi_wr.bresp),
    .m_axi_buser       (uart_axi_wr.buser),
    .m_axi_bvalid      (uart_axi_wr.bvalid),
    .m_axi_bready      (uart_axi_wr.bready)
);

// Convert CPU native MMIO requests into AXI transactions for the crossbar.
mmio_bridge u_mmio_bridge (
    .aclk              (aclk),
    .arst_n            (arst_n),

    .mmio_req_valid    (mmio_req_valid),
    .mmio_req_ready    (mmio_req_ready),
    .mmio_req_addr     (mmio_req_addr),
    .mmio_req_wdata    (mmio_req_wdata),
    .mmio_req_wstrb    (mmio_req_wstrb),
    .mmio_req_write    (mmio_req_write),
    .mmio_rsp_valid    (mmio_rsp_valid),
    .mmio_rsp_ready    (mmio_rsp_ready),
    .mmio_rsp_rdata    (mmio_rsp_rdata),

    .m_axi_wdata       (mmio_axi_wr.wdata),
    .m_axi_wstrb       (mmio_axi_wr.wstrb),
    .m_axi_wlast       (mmio_axi_wr.wlast),
    .m_axi_wuser       (mmio_axi_wr.wuser),
    .m_axi_wvalid      (mmio_axi_wr.wvalid),
    .m_axi_wready      (mmio_axi_wr.wready),

    .m_axi_awid        (mmio_axi_wr.awid),
    .m_axi_awaddr      (mmio_axi_wr.awaddr),
    .m_axi_awlen       (mmio_axi_wr.awlen),
    .m_axi_awsize      (mmio_axi_wr.awsize),
    .m_axi_awburst     (mmio_axi_wr.awburst),
    .m_axi_awlock      (mmio_axi_wr.awlock),
    .m_axi_awcache     (mmio_axi_wr.awcache),
    .m_axi_awprot      (mmio_axi_wr.awprot),
    .m_axi_awqos       (mmio_axi_wr.awqos),
    .m_axi_awregion    (mmio_axi_wr.awregion),
    .m_axi_awuser      (mmio_axi_wr.awuser),
    .m_axi_awvalid     (mmio_axi_wr.awvalid),
    .m_axi_awready     (mmio_axi_wr.awready),

    .m_axi_bid         (mmio_axi_wr.bid),
    .m_axi_bresp       (mmio_axi_wr.bresp),
    .m_axi_buser       (mmio_axi_wr.buser),
    .m_axi_bvalid      (mmio_axi_wr.bvalid),
    .m_axi_bready      (mmio_axi_wr.bready),

    .m_axi_arid        (mmio_axi_rd.arid),
    .m_axi_araddr      (mmio_axi_rd.araddr),
    .m_axi_arlen       (mmio_axi_rd.arlen),
    .m_axi_arsize      (mmio_axi_rd.arsize),
    .m_axi_arburst     (mmio_axi_rd.arburst),
    .m_axi_arlock      (mmio_axi_rd.arlock),
    .m_axi_arcache     (mmio_axi_rd.arcache),
    .m_axi_arprot      (mmio_axi_rd.arprot),
    .m_axi_arqos       (mmio_axi_rd.arqos),
    .m_axi_arregion    (mmio_axi_rd.arregion),
    .m_axi_aruser      (mmio_axi_rd.aruser),
    .m_axi_arvalid     (mmio_axi_rd.arvalid),
    .m_axi_arready     (mmio_axi_rd.arready),

    .m_axi_rid         (mmio_axi_rd.rid),
    .m_axi_rdata       (mmio_axi_rd.rdata),
    .m_axi_rresp       (mmio_axi_rd.rresp),
    .m_axi_rlast       (mmio_axi_rd.rlast),
    .m_axi_ruser       (mmio_axi_rd.ruser),
    .m_axi_rvalid      (mmio_axi_rd.rvalid),
    .m_axi_rready      (mmio_axi_rd.rready)
);

// Convert the crossbar MMIO AXI target into the native router interface.
axi2native_mmio u_axi2native_mmio (
    .aclk              (aclk),
    .arst_n            (arst_n),

    .mmio_req_valid    (router_req_valid),
    .mmio_req_ready    (router_req_ready),
    .mmio_req_addr     (router_req_addr),
    .mmio_req_wdata    (router_req_wdata),
    .mmio_req_wstrb    (router_req_wstrb),
    .mmio_req_write    (router_req_write),
    .mmio_rsp_valid    (router_rsp_valid),
    .mmio_rsp_ready    (router_rsp_ready),
    .mmio_rsp_rdata    (router_rsp_rdata),

    .m_axi_wdata       (mmio_target_axi_wr.wdata),
    .m_axi_wstrb       (mmio_target_axi_wr.wstrb),
    .m_axi_wlast       (mmio_target_axi_wr.wlast),
    .m_axi_wuser       (mmio_target_axi_wr.wuser),
    .m_axi_wvalid      (mmio_target_axi_wr.wvalid),
    .m_axi_wready      (mmio_target_axi_wr.wready),

    .m_axi_awid        (mmio_target_axi_wr.awid),
    .m_axi_awaddr      (mmio_target_axi_wr.awaddr),
    .m_axi_awlen       (mmio_target_axi_wr.awlen),
    .m_axi_awsize      (mmio_target_axi_wr.awsize),
    .m_axi_awburst     (mmio_target_axi_wr.awburst),
    .m_axi_awlock      (mmio_target_axi_wr.awlock),
    .m_axi_awcache     (mmio_target_axi_wr.awcache),
    .m_axi_awprot      (mmio_target_axi_wr.awprot),
    .m_axi_awqos       (mmio_target_axi_wr.awqos),
    .m_axi_awregion    (mmio_target_axi_wr.awregion),
    .m_axi_awuser      (mmio_target_axi_wr.awuser),
    .m_axi_awvalid     (mmio_target_axi_wr.awvalid),
    .m_axi_awready     (mmio_target_axi_wr.awready),

    .m_axi_bid         (mmio_target_axi_wr.bid),
    .m_axi_bresp       (mmio_target_axi_wr.bresp),
    .m_axi_buser       (mmio_target_axi_wr.buser),
    .m_axi_bvalid      (mmio_target_axi_wr.bvalid),
    .m_axi_bready      (mmio_target_axi_wr.bready),

    .m_axi_arid        (mmio_target_axi_rd.arid),
    .m_axi_araddr      (mmio_target_axi_rd.araddr),
    .m_axi_arlen       (mmio_target_axi_rd.arlen),
    .m_axi_arsize      (mmio_target_axi_rd.arsize),
    .m_axi_arburst     (mmio_target_axi_rd.arburst),
    .m_axi_arlock      (mmio_target_axi_rd.arlock),
    .m_axi_arcache     (mmio_target_axi_rd.arcache),
    .m_axi_arprot      (mmio_target_axi_rd.arprot),
    .m_axi_arqos       (mmio_target_axi_rd.arqos),
    .m_axi_arregion    (mmio_target_axi_rd.arregion),
    .m_axi_aruser      (mmio_target_axi_rd.aruser),
    .m_axi_arvalid     (mmio_target_axi_rd.arvalid),
    .m_axi_arready     (mmio_target_axi_rd.arready),

    .m_axi_rid         (mmio_target_axi_rd.rid),
    .m_axi_rdata       (mmio_target_axi_rd.rdata),
    .m_axi_rresp       (mmio_target_axi_rd.rresp),
    .m_axi_rlast       (mmio_target_axi_rd.rlast),
    .m_axi_ruser       (mmio_target_axi_rd.ruser),
    .m_axi_rvalid      (mmio_target_axi_rd.rvalid),
    .m_axi_rready      (mmio_target_axi_rd.rready)
);

endmodule
