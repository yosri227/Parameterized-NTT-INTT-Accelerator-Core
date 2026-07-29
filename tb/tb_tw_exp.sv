`timescale 1ns/1ps
module tb_tw_exp;
  import ntt_pkg::*;

  logic [LOGN-1:0] stage_num;
  logic [LOGN-2:0] lane_idx;
  logic [LOGN-2:0] tw_addr;

  tw_exp_gen dut (.stage_num(stage_num), .lane_idx(lane_idx), .tw_addr(tw_addr));

  integer f, code, errors, count, s_v, i_v, e_v;

  initial begin
    errors = 0; count = 0;
    f = $fopen("tw_exp_vecs.txt", "r");
    if (f == 0) begin $display("ERROR opening file"); $finish; end
    while (!$feof(f)) begin
      code = $fscanf(f, "%d %d %d\n", s_v, i_v, e_v);
      if (code == 3) begin
        stage_num = s_v[LOGN-1:0];
        lane_idx  = i_v[LOGN-2:0];
        #1;
        count++;
        if (tw_addr !== e_v[LOGN-2:0]) begin
          errors++;
          if (errors <= 10)
            $display("MISMATCH s=%0d i=%0d exp=%0d got=%0d", s_v, i_v, e_v, tw_addr);
        end
      end
    end
    $fclose(f);
    $display("tw_exp_gen test: %0d vectors, %0d errors", count, errors);
    if (errors == 0) $display("*** TW_EXP PASS ***");
    $finish;
  end
endmodule
