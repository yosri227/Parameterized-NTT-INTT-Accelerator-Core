# run_testsuite.do — compile and run all NTT test cases (ModelSim/Questa)
# Run from sim/:  vsim -c -do run_testsuite.do
#     or GUI:     do run_testsuite.do

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

onbreak resume

set num_cases 16
set passed 0
set failed 0

for {set i 0} {$i < $num_cases} {incr i} {
    set label [format "case_%02d" $i]
    puts "  Running $label ..."

    catch {quit -sim}
    vsim -voptargs=+acc -GIDX=$i work.tb_ntt_suite
    run -all

    # check transcript for PASS/FAIL markers
    set matched 0
    set lines [split [transcript] \n]
    foreach line $lines {
        if {[string match "*PASS*" $line] && ![string match "*FAIL*" $line]} {
            puts "  $label: PASS"
            incr passed
            set matched 1
            break
        }
        if {[string match "*FAIL*" $line] && ![string match "*PASS*" $line]} {
            puts "  $label: FAIL"
            incr failed
            set matched 1
            break
        }
    }
    if {!$matched} { incr failed }
}

puts "\n=== Test Suite Summary ==="
puts "  Passed: $passed / $num_cases"
puts "  Failed: $failed / $num_cases"
if {$failed == 0} { puts "  *** ALL TESTS PASS ***" }

quit
