// (c) Copyright 1995-2026 Xilinx, Inc. All rights reserved.
// 
// This file contains confidential and proprietary information
// of Xilinx, Inc. and is protected under U.S. and
// international copyright and other intellectual property
// laws.
// 
// DISCLAIMER
// This disclaimer is not a license and does not grant any
// rights to the materials distributed herewith. Except as
// otherwise provided in a valid license issued to you by
// Xilinx, and to the maximum extent permitted by applicable
// law: (1) THESE MATERIALS ARE MADE AVAILABLE "AS IS" AND
// WITH ALL FAULTS, AND XILINX HEREBY DISCLAIMS ALL WARRANTIES
// AND CONDITIONS, EXPRESS, IMPLIED, OR STATUTORY, INCLUDING
// BUT NOT LIMITED TO WARRANTIES OF MERCHANTABILITY, NON-
// INFRINGEMENT, OR FITNESS FOR ANY PARTICULAR PURPOSE; and
// (2) Xilinx shall not be liable (whether in contract or tort,
// including negligence, or under any other theory of
// liability) for any loss or damage of any kind or nature
// related to, arising under or in connection with these
// materials, including for any direct, or any indirect,
// special, incidental, or consequential loss or damage
// (including loss of data, profits, goodwill, or any type of
// loss or damage suffered as a result of any action brought
// by a third party) even if such damage or loss was
// reasonably foreseeable or Xilinx had been advised of the
// possibility of the same.
// 
// CRITICAL APPLICATIONS
// Xilinx products are not designed or intended to be fail-
// safe, or for use in any application requiring fail-safe
// performance, such as life-support or safety devices or
// systems, Class III medical devices, nuclear facilities,
// applications related to the deployment of airbags, or any
// other applications that could lead to death, personal
// injury, or severe property or environmental damage
// (individually and collectively, "Critical
// Applications"). Customer assumes the sole risk and
// liability of any use of Xilinx products in Critical
// Applications, subject only to applicable laws and
// regulations governing limitations on product liability.
// 
// THIS COPYRIGHT NOTICE AND DISCLAIMER MUST BE RETAINED AS
// PART OF THIS FILE AT ALL TIMES.
// 
// DO NOT MODIFY THIS FILE.

// IP VLNV: xilinx.com:ip:mipi_csi2_rx_subsystem:5.2
// IP Revision: 0

// The following must be inserted into your Verilog file for this
// core to be instantiated. Change the instance name and port connections
// (in parentheses) to your own signal names.

//----------- Begin Cut here for INSTANTIATION Template ---// INST_TAG
mipi_csi2_rx_subsystem_0 your_instance_name (
  .dphy_clk_200M(dphy_clk_200M),                // input wire dphy_clk_200M
  .rxbyteclkhs(rxbyteclkhs),                    // output wire rxbyteclkhs
  .clkoutphy_out(clkoutphy_out),                // output wire clkoutphy_out
  .system_rst_out(system_rst_out),              // output wire system_rst_out
  .pll_lock_out(pll_lock_out),                  // output wire pll_lock_out
  .video_aclk(video_aclk),                      // input wire video_aclk
  .video_aresetn(video_aresetn),                // input wire video_aresetn
  .ctrl_core_en(ctrl_core_en),                  // input wire ctrl_core_en
  .active_lanes(active_lanes),                  // input wire [1 : 0] active_lanes
  .ctrl_dis_in_prgs(ctrl_dis_in_prgs),          // output wire ctrl_dis_in_prgs
  .errsotsynchs_intr(errsotsynchs_intr),        // output wire errsotsynchs_intr
  .errsoths_intr(errsoths_intr),                // output wire errsoths_intr
  .cl_stopstate_intr(cl_stopstate_intr),        // output wire cl_stopstate_intr
  .dl0_stopstate_intr(dl0_stopstate_intr),      // output wire dl0_stopstate_intr
  .dl1_stopstate_intr(dl1_stopstate_intr),      // output wire dl1_stopstate_intr
  .crc_status_intr(crc_status_intr),            // output wire crc_status_intr
  .ecc_status_intr(ecc_status_intr),            // output wire [1 : 0] ecc_status_intr
  .linebuffer_full(linebuffer_full),            // output wire linebuffer_full
  .frame_rcvd_pulse_out(frame_rcvd_pulse_out),  // output wire frame_rcvd_pulse_out
  .video_out_tdata(video_out_tdata),            // output wire [15 : 0] video_out_tdata
  .video_out_tdest(video_out_tdest),            // output wire [9 : 0] video_out_tdest
  .video_out_tlast(video_out_tlast),            // output wire video_out_tlast
  .video_out_tready(video_out_tready),          // input wire video_out_tready
  .video_out_tuser(video_out_tuser),            // output wire [0 : 0] video_out_tuser
  .video_out_tvalid(video_out_tvalid),          // output wire video_out_tvalid
  .mipi_phy_if_clk_n(mipi_phy_if_clk_n),        // input wire mipi_phy_if_clk_n
  .mipi_phy_if_clk_p(mipi_phy_if_clk_p),        // input wire mipi_phy_if_clk_p
  .mipi_phy_if_data_n(mipi_phy_if_data_n),      // input wire [1 : 0] mipi_phy_if_data_n
  .mipi_phy_if_data_p(mipi_phy_if_data_p)      // input wire [1 : 0] mipi_phy_if_data_p
);
// INST_TAG_END ------ End INSTANTIATION Template ---------

// You must compile the wrapper file mipi_csi2_rx_subsystem_0.v when simulating
// the core, mipi_csi2_rx_subsystem_0. When compiling the wrapper file, be sure to
// reference the Verilog simulation library.

