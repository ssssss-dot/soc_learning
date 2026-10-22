# OV5645 receiver for MPSoC-P5B / XCZU5EV, Vivado 2022.2 (MIPI RX v5.2).
# Run with: vivado -mode batch -source create_mipi_rgb565.tcl
# Or source this file from an open project for the same FPGA part.
# MIPI_OUTPUT_DIR optionally selects the generated IP/project directory.

set camera_script_dir [file dirname [file normalize [info script]]]
set camera_output_dir [file join $camera_script_dir generated]
if {[info exists ::env(MIPI_OUTPUT_DIR)] && $::env(MIPI_OUTPUT_DIR) ne ""} {
    set camera_output_dir [file normalize $::env(MIPI_OUTPUT_DIR)]
}
set camera_part xczu5ev-sfvc784-2-e
set camera_ip_name mipi_csi2_rx_subsystem_0
file mkdir [file join $camera_output_dir ip]

if {[current_project -quiet] eq ""} {
    create_project mipi_rgb565 [file join $camera_output_dir project] -part $camera_part
} elseif {[get_property PART [current_project]] ne $camera_part} {
    error "This camera pin configuration requires $camera_part"
}

if {[llength [get_ips -quiet $camera_ip_name]] != 0} {
    error "$camera_ip_name already exists. Re-customize it or use a new project."
}

create_ip -name mipi_csi2_rx_subsystem -vendor xilinx.com -library ip \
    -version 5.2 -module_name $camera_ip_name -dir [file join $camera_output_dir ip]

# Current ROM retains the reference 24 MHz XCLK and PLL values:
# 3037=13, 3036=70, 3035=21. The source register table specifies
# 448 Mb/s per lane (224 MHz differential clock), despite 128x128 output.
# 1 pixel/clock, RGB565: peak pixel bandwidth requires 56 MHz or more.
# Use a 100 MHz video_aclk; D-PHY requires 200 MHz.
# Configuration is fixed at generation time: no AXI-Lite register interface.
set_property -dict [list \
    CONFIG.CMN_NUM_LANES {2} \
    CONFIG.C_DPHY_LANES {2} \
    CONFIG.CMN_NUM_PIXELS {1} \
    CONFIG.CMN_PXL_FORMAT {RGB565} \
    CONFIG.CMN_INC_VFB {true} \
    CONFIG.VFB_TU_WIDTH {1} \
    CONFIG.CMN_VC {All} \
    CONFIG.CSI_BUF_DEPTH {2048} \
    CONFIG.CSI_CONTROLLER_REG_IF {false} \
    CONFIG.C_CSI_EN_ACTIVELANES {false} \
    CONFIG.DPY_EN_REG_IF {false} \
    CONFIG.DPY_LINE_RATE {448} \
    CONFIG.C_OOC_VID_CLK {10.000} \
    CONFIG.SupportLevel {1} \
    CONFIG.HP_IO_BANK_SELECTION {65} \
    CONFIG.CLK_LANE_IO_LOC {W8} \
    CONFIG.CLK_LANE_IO_LOC_NAME {IO_L1P_T0L_N0_DBC_65} \
    CONFIG.DATA_LANE0_IO_LOC {R8} \
    CONFIG.DATA_LANE0_IO_LOC_NAME {IO_L4P_T0U_N6_DBC_AD7P_SMBALERT_65} \
    CONFIG.DATA_LANE1_IO_LOC {U8} \
    CONFIG.DATA_LANE1_IO_LOC_NAME {IO_L3P_T0L_N4_AD15P_65} \
] [get_ips $camera_ip_name]

generate_target all [get_ips $camera_ip_name]
foreach camera_property {CMN_PXL_FORMAT CMN_NUM_LANES CMN_NUM_PIXELS DPY_LINE_RATE C_HS_LINE_RATE CSI_CONTROLLER_REG_IF C_OOC_VID_CLK} {
    puts "CAMERA: $camera_property = [get_property CONFIG.$camera_property [get_ips $camera_ip_name]]"
}
puts "CAMERA: generated IP in $camera_output_dir; use the generated .veo for RTL port connections."
