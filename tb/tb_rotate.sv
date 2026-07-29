`timescale 1ns/1ps
module tb_rotate;
  import ntt_pkg::*;

  ntt_mode_e mode;
  logic [LOGN-1:0] addr_in, addr_out;

  ru_rotate dut (.addr_in(addr_in), .addr_out(addr_out));

  integer f, code, errors, count, m_v, a_v, e_v;

  initial begin
    errors = 0; count = 0;
    f = $fopen("rotate_vecs.txt", "r");
    if (f == 0) begin $display("ERROR opening file"); $finish; end
    while (!$feof(f)) begin
      code = $fscanf(f, "%d %d %d\n", m_v, a_v, e_v);
      if (code == 3) begin
        mode    = ntt_mode_e'(m_v[0]);
        addr_in = a_v[LOGN-1:0];
        #1;
        count++;
        if (addr_out !== e_v[LOGN-1:0]) begin
          errors++;
          if (errors <= 10)
            $display("MISMATCH mode=%0d addr=%0d exp=%0d got=%0d", m_v, a_v, e_v, addr_out);
        end
      end
    end
    $fclose(f);
    $display("ru_rotate test: %0d vectors, %0d errors", count, errors);
    if (errors == 0) $display("*** ROTATE PASS ***");
    $finish;
  end
endmodule
