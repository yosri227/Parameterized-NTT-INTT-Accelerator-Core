# compile_testsuite.do — compile RTL + testbench for GUI use
# Usage in ModelSim GUI: do compile_testsuite.do
# Then: vsim -GIDX=0 work.tb_ntt_suite  (or any index 0..15)
#       add wave -r /*
#       run -all

set TB_DIR ../tb
set RTL_DIR ../rtl

file copy -force $RTL_DIR/twiddle_fwd.hex .
file copy -force $RTL_DIR/twiddle_inv.hex .

if {[file exists work]} { vdel -all }
vlib work

vlog -sv $RTL_DIR/ntt_pkg.sv
vlog -sv $RTL_DIR/barrett_reduce.sv
vlog -sv $RTL_DIR/mod_addsub.sv
vlog -sv $RTL_DIR/butterfly_unit.sv
vlog -sv $RTL_DIR/reorder_unit.sv
vlog -sv $RTL_DIR/twiddle_rom.sv
vlog -sv $RTL_DIR/ntt_top.sv
vlog -sv $TB_DIR/tb_ntt_suite.sv

puts ""
puts "Compilation done. To simulate a test case:"
puts "  vsim -GIDX=0 work.tb_ntt_suite"
puts "  add wave -r /*"
puts "  run -all"
