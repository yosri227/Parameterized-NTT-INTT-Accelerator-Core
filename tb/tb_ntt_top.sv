`timescale 1ns/1ps
module tb_ntt_top;
  import ntt_pkg::*;

  logic clk = 0;
  logic rst_n = 0;
  logic load_en;
  logic [LOGN-1:0] load_addr;
  logic [W-1:0] load_data;
  logic start;
  ntt_mode_e op_mode;
  logic busy, done;
  logic [LOGN-1:0] rd_addr;
  logic [W-1:0] rd_data;

  ntt_top dut (
    .clk(clk), .rst_n(rst_n),
    .load_en(load_en), .load_addr(load_addr), .load_data(load_data),
    .start(start), .op_mode(op_mode),
    .busy(busy), .done(done),
    .rd_addr(rd_addr), .rd_data(rd_data)
  );

  always #5 clk = ~clk;

  integer coeff_mem [0:N-1];
  integer fwd_exp   [0:N-1];
  integer rt_exp    [0:N-1];

  integer f, code, i, errors_fwd, errors_rt;

  task automatic load_file_into(input string fname, input integer sel);
    integer fh, c, v, idx;
    begin
      fh = $fopen(fname, "r");
      if (fh == 0) begin
        $display("ERROR: cannot open %s", fname);
        $finish;
      end
      idx = 0;
      while (!$feof(fh) && idx < N) begin
        c = $fscanf(fh, "%d\n", v);
        if (c == 1) begin
          case (sel)
            0: coeff_mem[idx] = v;
            1: fwd_exp[idx]   = v;
            2: rt_exp[idx]    = v;
          endcase
          idx = idx + 1;
        end
      end
      $fclose(fh);
    end
  endtask

  task automatic pulse_start();
    begin
      @(posedge clk);
      #1;
      start = 1'b1;
      @(posedge clk);
      #1;
      start = 1'b0;
    end
  endtask

  initial begin
    load_file_into("input_coeffs.txt", 0);
    load_file_into("expected_fwd.txt", 1);
    load_file_into("expected_roundtrip.txt", 2);

    load_en = 0; load_addr = '0; load_data = '0;
    start = 0; op_mode = MODE_FWD; rd_addr = '0;

    repeat (3) @(posedge clk);
    rst_n = 1;
    @(posedge clk);
    #1;

    // ---------------- Forward NTT ----------------
    op_mode = MODE_FWD;
    for (i = 0; i < N; i = i + 1) begin
      @(posedge clk);
      #1;
      load_en   = 1'b1;
      load_addr = i[LOGN-1:0];
      load_data = coeff_mem[i][W-1:0];
    end
    @(posedge clk);
    #1;
    load_en = 1'b0;

    pulse_start();
    wait (done == 1'b1);
    @(posedge clk); #1;

    errors_fwd = 0;
    for (i = 0; i < N; i = i + 1) begin
      rd_addr = i[LOGN-1:0];
      #1;
      if (rd_data !== fwd_exp[i][W-1:0]) begin
        errors_fwd++;
        if (errors_fwd <= 10)
          $display("FWD MISMATCH idx=%0d exp=%0d got=%0d", i, fwd_exp[i], rd_data);
      end
    end
    $display("Forward NTT: %0d errors out of %0d coefficients", errors_fwd, N);
    if (errors_fwd == 0) $display("*** FORWARD NTT PASS ***");
    else $display("*** FORWARD NTT FAIL ***");

    // ---------------- Inverse NTT (chained directly off the FWD result) ----------------
    op_mode = MODE_INV;
    @(posedge clk); #1;
    pulse_start();

    // debug: capture bufA right as we enter the SCALE state (pre-scale)
    wait (dut.state == dut.ST_SCALE);

    wait (done == 1'b1);
    @(posedge clk); #1;

    errors_rt = 0;
    for (i = 0; i < N; i = i + 1) begin
      rd_addr = i[LOGN-1:0];
      #1;
      if (rd_data !== rt_exp[i][W-1:0]) begin
        errors_rt++;
        if (errors_rt <= 10)
          $display("ROUNDTRIP MISMATCH idx=%0d exp=%0d got=%0d", i, rt_exp[i], rd_data);
      end
    end
    $display("Round-trip (FWD->INV): %0d errors out of %0d coefficients", errors_rt, N);
    if (errors_rt == 0) $display("*** ROUND-TRIP PASS: RTL matches Python golden model bit-for-bit ***");
    else $display("*** ROUND-TRIP FAIL ***");

    $finish;
  end

  // safety watchdog
  initial begin
    #200000;
    $display("TIMEOUT - simulation did not complete");
    $finish;
  end

endmodule
