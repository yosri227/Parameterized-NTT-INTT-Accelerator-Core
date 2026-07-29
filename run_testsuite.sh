#!/usr/bin/env bash
# run_testsuite.sh — generate vectors and run all test cases (Linux / iverilog)
set -e
cd "$(dirname "$0")"

echo "== Generating test vectors =="
(cd scripts && python3 testsuite.py)

echo "== Preparing simulation files =="
cp rtl/twiddle_fwd.hex rtl/twiddle_inv.hex tb/

RTL_SRC="../rtl/ntt_pkg.sv ../rtl/barrett_reduce.sv ../rtl/mod_addsub.sv ../rtl/butterfly_unit.sv \
         ../rtl/reorder_unit.sv ../rtl/twiddle_rom.sv ../rtl/ntt_top.sv"

cd tb

NUM_CASES=$(ls -d ../testsuite/case_* | wc -l)
PASSED=0
FAILED=0

for i in $(seq 0 $((NUM_CASES - 1))); do
  printf "  [%02d/%02d] case_%02d ... " $((i+1)) $NUM_CASES $i
  iverilog -g2012 -o /tmp/sim_suite_$i -P tb_ntt_suite.IDX=$i \
    $RTL_SRC tb_ntt_suite.sv 2>/dev/null
  output=$(vvp /tmp/sim_suite_$i 2>&1)
  if echo "$output" | grep -q "PASS"; then
    echo "PASS"
    PASSED=$((PASSED + 1))
  else
    echo "FAIL"
    echo "$output" | grep -E "MISMATCH|error|Error"
    FAILED=$((FAILED + 1))
  fi
done

echo ""
echo "=== Test Suite Summary ==="
echo "  Passed: $PASSED / $NUM_CASES"
echo "  Failed: $FAILED / $NUM_CASES"
if [ $FAILED -eq 0 ]; then
  echo "  *** ALL TESTS PASS ***"
else
  echo "  *** SOME TESTS FAILED ***"
  exit 1
fi
