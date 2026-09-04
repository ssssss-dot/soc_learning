# Vivado Tcl project template
# Run:
#   vivado -mode batch -source vivado_project_template.tcl
# or enter Tcl shell first:
#   vivado -mode tcl
#   source vivado_project_template.tcl

# -----------------------------
# 1. Edit these variables first
# -----------------------------
set project_name "5pipeline_tcl"
set project_dir  "./prj"

# Example parts:
#   xc7a35tcsg324-1    ;# Artix-7, often used by Basys 3
#   xc7z020clg400-1    ;# Zynq-7020
#   xcku040-ffva1156-2 ;# Kintex UltraScale
set part_name "xczu5ev-sfvc784-2-e(active)"

# Top module/entity name
set top_name "soc_top"

# HDL source files. Add or remove files here.
set rtl_files [list \
    "./src/top.v" \
]

# Optional constraint files. Put your .xdc here.
set xdc_files [list \
    "./constraints/top.xdc" \
]

#add personal or official ip
#set ip_files [list \
#    "./ip/my_ip.xci" \
#]

# -----------------------------
# 2. Create/open project
# -----------------------------
create_project $project_name $project_dir -part $part_name -force
set_property target_language Verilog [current_project]
set_property simulator_language Mixed [current_project]

# -----------------------------
# 3. Add source files
# -----------------------------
foreach file_path $rtl_files {
    if {[file exists $file_path]} {
        add_files -fileset sources_1 $file_path
    } else {
        puts "WARNING: RTL file not found: $file_path"
    }
}

foreach file_path $xdc_files {
    if {[file exists $file_path]} {
        add_files -fileset constrs_1 $file_path
    } else {
        puts "WARNING: XDC file not found: $file_path"
    }
}

#foreach file_path $ip_files {
#    if {[file exists $file_path]} {
#        add_files -fileset sources_1 $file_path
#        generate_target all [get_files $file_path]
#    } else {
#        puts "WARNING: IP file not found: $file_path"
#    }
#}

update_compile_order -fileset sources_1
set_property top $top_name [current_fileset]

# -----------------------------
# 4. Run synthesis
# -----------------------------
launch_runs synth_1 -jobs 4
wait_on_run synth_1

if {[get_property PROGRESS [get_runs synth_1]] != "100%"} {
    error "Synthesis did not finish successfully."
}

open_run synth_1
report_timing_summary -file "$project_dir/timing_synth.rpt"
report_utilization -file "$project_dir/util_synth.rpt"

# -----------------------------
# 5. Run implementation
# -----------------------------
launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1

if {[get_property PROGRESS [get_runs impl_1]] != "100%"} {
    error "Implementation did not finish successfully."
}

open_run impl_1
report_timing_summary -file "$project_dir/timing_impl.rpt"
report_utilization -file "$project_dir/util_impl.rpt"

puts "DONE: bitstream and reports are in $project_dir"