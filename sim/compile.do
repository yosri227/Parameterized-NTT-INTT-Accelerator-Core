# compile.do - compile all sources in GUI mode (no simulation)
# Usage: do compile.do

set TB_DIR ../tb
set RTL_DIR ../rtl

file copy -force $RTL_DIR/twiddle_fwd.hex .
file copy -force $RTL_DIR/twiddle_inv.hex .
file copy -force $TB_DIR/barrett_vecs.txt .
file copy -force $TB_DIR/bu_vecs.txt .
file copy -force $TB_DIR/tw_exp_vecs.txt .
file copy -force $TB_DIR/rotate_vecs.txt .
file copy -force $TB_DIR/input_coeffs.txt .
file copy -force $TB_DIR/expected_fwd.txt .
file copy -force $TB_DIR/expected_roundtrip.txt .

if {[file exists work]} { vdel -all }
vlib work

vlog -sv $RTL_DIR/ntt_pkg.sv
vlog -sv $RTL_DIR/barrett_reduce.sv
vlog -sv $RTL_DIR/mod_addsub.sv
vlog -sv $RTL_DIR/butterfly_unit.sv
vlog -sv $RTL_DIR/reorder_unit.sv
vlog -sv $RTL_DIR/twiddle_rom.sv
vlog -sv $RTL_DIR/ntt_top.sv
vlog -sv $TB_DIR/tb_barrett.sv
vlog -sv $TB_DIR/tb_butterfly_comb.sv
vlog -sv $TB_DIR/tb_butterfly.sv
vlog -sv $TB_DIR/tb_tw_exp.sv
vlog -sv $TB_DIR/tb_rotate.sv
vlog -sv $TB_DIR/tb_ntt_top.sv
