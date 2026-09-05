#������Լ���ļ�

#ʱ��Լ��
create_clock -period 10.000 -waveform {0.000 5.000} [get_ports sys_clk_p]

#IO����Լ��
#----------------------ϵͳʱ��---------------------------
set_property IOSTANDARD DIFF_HSTL_I_12 [get_ports sys_clk_p]
set_property IOSTANDARD DIFF_HSTL_I_12 [get_ports sys_clk_n]
set_property PACKAGE_PIN AE5 [get_ports sys_clk_p]
set_property PACKAGE_PIN AF5 [get_ports sys_clk_n]

#----------------------ϵͳ��λ---------------------------
set_property -dict {PACKAGE_PIN F13 IOSTANDARD LVCMOS33} [get_ports rst_n]

#-------------------------PL_USB UART-----------------------
set_property -dict {PACKAGE_PIN D12 IOSTANDARD LVCMOS33} [get_ports uart_rxd]
set_property -dict {PACKAGE_PIN C12 IOSTANDARD LVCMOS33} [get_ports uart_txd]

#----------------------extra uart---------------------------
set_property -dict {PACKAGE_PIN E12 IOSTANDARD LVCMOS33} [get_ports dbg_uart_txd]

#-------------------DDR4------------------------
set_property -dict {PACKAGE_PIN AD4 IOSTANDARD SSTL12_DCI} [get_ports c0_ddr4_act_n]
set_property -dict {PACKAGE_PIN AG8 IOSTANDARD SSTL12_DCI} [get_ports {c0_ddr4_adr[0]}]
set_property -dict {PACKAGE_PIN AB8 IOSTANDARD SSTL12_DCI} [get_ports {c0_ddr4_adr[1]}]
set_property -dict {PACKAGE_PIN AF8 IOSTANDARD SSTL12_DCI} [get_ports {c0_ddr4_adr[2]}]
set_property -dict {PACKAGE_PIN AC8 IOSTANDARD SSTL12_DCI} [get_ports {c0_ddr4_adr[3]}]
set_property -dict {PACKAGE_PIN AF7 IOSTANDARD SSTL12_DCI} [get_ports {c0_ddr4_adr[4]}]
set_property -dict {PACKAGE_PIN AD7 IOSTANDARD SSTL12_DCI} [get_ports {c0_ddr4_adr[5]}]
set_property -dict {PACKAGE_PIN AH7 IOSTANDARD SSTL12_DCI} [get_ports {c0_ddr4_adr[6]}]
set_property -dict {PACKAGE_PIN AE9 IOSTANDARD SSTL12_DCI} [get_ports {c0_ddr4_adr[7]}]
set_property -dict {PACKAGE_PIN AH8 IOSTANDARD SSTL12_DCI} [get_ports {c0_ddr4_adr[8]}]
set_property -dict {PACKAGE_PIN AC9 IOSTANDARD SSTL12_DCI} [get_ports {c0_ddr4_adr[9]}]
set_property -dict {PACKAGE_PIN AE7 IOSTANDARD SSTL12_DCI} [get_ports {c0_ddr4_adr[10]}]
set_property -dict {PACKAGE_PIN AH9 IOSTANDARD SSTL12_DCI} [get_ports {c0_ddr4_adr[11]}]
set_property -dict {PACKAGE_PIN AC6 IOSTANDARD SSTL12_DCI} [get_ports {c0_ddr4_adr[12]}]
set_property -dict {PACKAGE_PIN AD9 IOSTANDARD SSTL12_DCI} [get_ports {c0_ddr4_adr[13]}]
set_property -dict {PACKAGE_PIN AF6 IOSTANDARD SSTL12_DCI} [get_ports {c0_ddr4_adr[14]}]
set_property -dict {PACKAGE_PIN AB7 IOSTANDARD SSTL12_DCI} [get_ports {c0_ddr4_adr[15]}]
set_property -dict {PACKAGE_PIN AB5 IOSTANDARD SSTL12_DCI} [get_ports {c0_ddr4_adr[16]}]
set_property -dict {PACKAGE_PIN AH6 IOSTANDARD SSTL12_DCI} [get_ports {c0_ddr4_ba[0]}]
set_property -dict {PACKAGE_PIN AC7 IOSTANDARD SSTL12_DCI} [get_ports {c0_ddr4_ba[1]}]
set_property -dict {PACKAGE_PIN AE8 IOSTANDARD SSTL12_DCI} [get_ports {c0_ddr4_bg}]
set_property -dict {PACKAGE_PIN AE4 IOSTANDARD SSTL12_DCI} [get_ports {c0_ddr4_cke}]
set_property -dict {PACKAGE_PIN AH4 IOSTANDARD SSTL12_DCI} [get_ports {c0_ddr4_odt}]
set_property -dict {PACKAGE_PIN AB6 IOSTANDARD SSTL12_DCI} [get_ports {c0_ddr4_cs_n}]
set_property -dict {PACKAGE_PIN AG6 IOSTANDARD DIFF_SSTL12_DCI} [get_ports {c0_ddr4_ck_t}]
set_property -dict {PACKAGE_PIN AG5 IOSTANDARD DIFF_SSTL12_DCI} [get_ports {c0_ddr4_ck_c}]
set_property -dict {PACKAGE_PIN AG9 IOSTANDARD LVCMOS12} [get_ports {c0_ddr4_reset_n}]
set_property -dict {PACKAGE_PIN AG4 IOSTANDARD POD12_DCI} [get_ports {c0_ddr4_dm_dbi_n[0]}]
set_property -dict {PACKAGE_PIN AD5 IOSTANDARD POD12_DCI} [get_ports {c0_ddr4_dm_dbi_n[1]}]
set_property -dict {PACKAGE_PIN AG1 IOSTANDARD POD12_DCI} [get_ports {c0_ddr4_dq[0]}]
set_property -dict {PACKAGE_PIN AF1 IOSTANDARD POD12_DCI} [get_ports {c0_ddr4_dq[1]}]
set_property -dict {PACKAGE_PIN AH1 IOSTANDARD POD12_DCI} [get_ports {c0_ddr4_dq[2]}]
set_property -dict {PACKAGE_PIN AH2 IOSTANDARD POD12_DCI} [get_ports {c0_ddr4_dq[3]}]
set_property -dict {PACKAGE_PIN AF3 IOSTANDARD POD12_DCI} [get_ports {c0_ddr4_dq[4]}]
set_property -dict {PACKAGE_PIN AE3 IOSTANDARD POD12_DCI} [get_ports {c0_ddr4_dq[5]}]
set_property -dict {PACKAGE_PIN AH3 IOSTANDARD POD12_DCI} [get_ports {c0_ddr4_dq[6]}]
set_property -dict {PACKAGE_PIN AG3 IOSTANDARD POD12_DCI} [get_ports {c0_ddr4_dq[7]}]
set_property -dict {PACKAGE_PIN AC1 IOSTANDARD POD12_DCI} [get_ports {c0_ddr4_dq[8]}]
set_property -dict {PACKAGE_PIN AB1 IOSTANDARD POD12_DCI} [get_ports {c0_ddr4_dq[9]}]
set_property -dict {PACKAGE_PIN AC2 IOSTANDARD POD12_DCI} [get_ports {c0_ddr4_dq[10]}]
set_property -dict {PACKAGE_PIN AB2 IOSTANDARD POD12_DCI} [get_ports {c0_ddr4_dq[11]}]
set_property -dict {PACKAGE_PIN AB3 IOSTANDARD POD12_DCI} [get_ports {c0_ddr4_dq[12]}]
set_property -dict {PACKAGE_PIN AB4 IOSTANDARD POD12_DCI} [get_ports {c0_ddr4_dq[13]}]
set_property -dict {PACKAGE_PIN AC3 IOSTANDARD POD12_DCI} [get_ports {c0_ddr4_dq[14]}]
set_property -dict {PACKAGE_PIN AC4 IOSTANDARD POD12_DCI} [get_ports {c0_ddr4_dq[15]}]
set_property -dict {PACKAGE_PIN AF2 IOSTANDARD DIFF_POD12_DCI} [get_ports {c0_ddr4_dqs_c[0]}]
set_property -dict {PACKAGE_PIN AD1 IOSTANDARD DIFF_POD12_DCI} [get_ports {c0_ddr4_dqs_c[1]}]
set_property -dict {PACKAGE_PIN AE2 IOSTANDARD DIFF_POD12_DCI} [get_ports {c0_ddr4_dqs_t[0]}]
set_property -dict {PACKAGE_PIN AD2 IOSTANDARD DIFF_POD12_DCI} [get_ports {c0_ddr4_dqs_t[1]}]
