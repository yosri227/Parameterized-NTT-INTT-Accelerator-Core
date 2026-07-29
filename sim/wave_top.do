# wave_top.do - compile, simulate tb_ntt_top, and show waveforms
do compile.do
vsim -voptargs=+acc work.tb_ntt_top

# Add all signals in the design
add wave -r /tb_ntt_top/*
add wave -r /tb_ntt_top/dut/*

# Run the full simulation
run -all
