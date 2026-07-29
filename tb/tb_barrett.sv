`timescale 1ns/1ps
module tb_barrett;
  import ntt_pkg::*;

  logic [MULW-1:0] in_val;
  logic [W-1:0]    out_val;

  barrett_reduce #(.Q(Q), .W(W), .MULW(MULW), .MU(BARRETT_MU)) dut (
    .in_val(in_val),
    .out_val(out_val)
  );

  integer f, code, errors, count;
  longint unsigned p_val, exp_val;

  initial begin
    errors = 0;
    count  = 0;
    f = $fopen("barrett_vecs.txt", "r");
    if (f == 0) begin
      $display("ERROR: could not open barrett_vecs.txt");
      $finish;
    end
    while (!$feof(f)) begin
      code = $fscanf(f, "%d %d\n", p_val, exp_val);
      if (code == 2) begin
        in_val = p_val[MULW-1:0];
        #1;
        count++;
        if (out_val !== exp_val[W-1:0]) begin
          errors++;
          if (errors <= 10)
            $display("MISMATCH: in=%0d exp=%0d got=%0d", p_val, exp_val, out_val);
        end
      end
    end
    $fclose(f);
    $display("Barrett test: %0d vectors, %0d errors", count, errors);
    if (errors == 0) $display("*** BARRETT PASS ***");
    else $display("*** BARRETT FAIL ***");
    $finish;
  end
endmodule
