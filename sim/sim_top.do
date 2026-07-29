# sim_top.do - simulate ntt_top with waveform window
# Usage: do sim_top.do

do compile.do

vsim -voptargs=+acc work.tb_ntt_top

# add top-level signals to wave
add wave -r /tb_ntt_top/*

run -all
