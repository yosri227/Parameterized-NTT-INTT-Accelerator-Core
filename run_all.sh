#!/usr/bin/env bash
# run_all.sh - regenerate golden vectors and run the full RTL regression suite.
# Requires: python3, iverilog + vvp (Icarus Verilog, `apt-get install iverilog`)
set -e
cd "$(dirname "$0")"

echo "== Regenerating golden-model vectors and twiddle ROMs =="
(cd scripts && python3 gen_vectors.py)

cd tb
cp ../rtl/twiddle_fwd.hex ../rtl/twiddle_inv.hex .

run() {
  name=$1; shift
  echo
  echo "== $name =="
  iverilog -g2012 -o /tmp/sim_$name $@ 2>&1 | grep -v "sorry:" || true
  vvp /tmp/sim_$name
}

run barrett   ../rtl/ntt_pkg.sv ../rtl/barrett_reduce.sv tb_barrett.sv
run bu_comb   ../rtl/ntt_pkg.sv ../rtl/mod_addsub.sv ../rtl/barrett_reduce.sv ../rtl/butterfly_unit.sv tb_butterfly_comb.sv
run bu_pipe   ../rtl/ntt_pkg.sv ../rtl/mod_addsub.sv ../rtl/barrett_reduce.sv ../rtl/butterfly_unit.sv tb_butterfly.sv
run tw_exp    ../rtl/ntt_pkg.sv ../rtl/reorder_unit.sv tb_tw_exp.sv
run rotate    ../rtl/ntt_pkg.sv ../rtl/reorder_unit.sv tb_rotate.sv
run top       ../rtl/ntt_pkg.sv ../rtl/mod_addsub.sv ../rtl/barrett_reduce.sv ../rtl/butterfly_unit.sv ../rtl/reorder_unit.sv ../rtl/twiddle_rom.sv ../rtl/ntt_top.sv tb_ntt_top.sv

echo
echo "== All testbenches executed - check *** PASS *** markers above =="
