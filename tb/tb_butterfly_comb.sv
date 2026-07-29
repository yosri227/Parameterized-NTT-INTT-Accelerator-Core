`timescale 1ns/1ps
module tb_butterfly_comb;
  import ntt_pkg::*;

  logic clk = 0;
  logic rst_n = 1;
  logic valid_in;
  ntt_mode_e mode;
  logic [W-1:0] a_in, b_in, w_in;
  logic [W-1:0] y0_out, y1_out;
  logic valid_out;

  butterfly_unit #(.PIPELINE(0)) dut (
    .clk(clk), .rst_n(rst_n),
    .valid_in(valid_in), .mode(mode),
    .a_in(a_in), .b_in(b_in), .w_in(w_in),
    .y0_out(y0_out), .y1_out(y1_out), .valid_out(valid_out)
  );

  integer f, code, errors, count, mode_i;
  integer a_v, b_v, w_v, y0_v, y1_v;

  initial begin
    errors = 0; count = 0;
    valid_in = 1;
    f = $fopen("bu_vecs.txt", "r");
    if (f == 0) begin $display("ERROR opening file"); $finish; end
    while (!$feof(f)) begin
      code = $fscanf(f, "%d %d %d %d %d %d\n", mode_i, a_v, b_v, w_v, y0_v, y1_v);
      if (code == 6) begin
        mode = ntt_mode_e'(mode_i[0]);
        a_in = a_v[W-1:0];
        b_in = b_v[W-1:0];
        w_in = w_v[W-1:0];
        #1;
        count++;
        if (y0_out !== y0_v[W-1:0] || y1_out !== y1_v[W-1:0]) begin
          errors++;
          if (errors <= 10)
            $display("MISMATCH #%0d mode=%0d a=%0d b=%0d w=%0d got y0=%0d y1=%0d exp y0=%0d y1=%0d",
                      count, mode_i, a_v, b_v, w_v, y0_out, y1_out, y0_v, y1_v);
        end
      end
    end
    $fclose(f);
    $display("Combinational BU test: %0d vectors, %0d errors", count, errors);
    if (errors == 0) $display("*** BUTTERFLY COMB PASS ***");
    $finish;
  end
endmodule
