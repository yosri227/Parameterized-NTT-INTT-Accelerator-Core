`timescale 1ns/1ps

// tb_ntt_suite.sv — parameterized multi-case NTT testbench.
// Select test case with -DTEST_IDX=<N> (0..15).
// Expects files at: <CASE_DIR>/case_NN/input.txt expected_fwd.txt
module tb_ntt_suite;
  import ntt_pkg::*;

  localparam string CASE_DIR = "../testsuite";
  parameter int IDX = 0;

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
  integer fwd_exp  [0:N-1];
  integer rt_exp   [0:N-1];

  integer i, errors_fwd, errors_rt;
  integer fh, c, v, idx;

  initial begin
    string in_file, fwd_file;
    in_file = $sformatf("%s/case_%02d/input.txt", CASE_DIR, IDX);
    fwd_file = $sformatf("%s/case_%02d/expected_fwd.txt", CASE_DIR, IDX);

    // ---- load input coefficients ----
    fh = $fopen(in_file, "r");
    if (fh == 0) begin $display("FAIL Cannot open %s", in_file); $finish; end
    for (i = 0; i < N && !$feof(fh); i = i + 1) begin
      c = $fscanf(fh, "%d\n", v);
      if (c == 1) coeff_mem[i] = v;
    end
    $fclose(fh);

    // ---- load expected FWD output ----
    fh = $fopen(fwd_file, "r");
    if (fh == 0) begin $display("FAIL Cannot open %s", fwd_file); $finish; end
    for (i = 0; i < N && !$feof(fh); i = i + 1) begin
      c = $fscanf(fh, "%d\n", v);
      if (c == 1) fwd_exp[i] = v;
    end
    $fclose(fh);

    load_en = 0; load_addr = '0; load_data = '0;
    start = 0; op_mode = MODE_FWD; rd_addr = '0;

    repeat (3) @(posedge clk);
    rst_n = 1;
    @(posedge clk);
    #1;

    // ---- Forward NTT ----
    op_mode = MODE_FWD;
    for (i = 0; i < N; i = i + 1) begin
      @(posedge clk); #1;
      load_en   = 1'b1;
      load_addr = i[LOGN-1:0];
      load_data = coeff_mem[i][W-1:0];
    end
    @(posedge clk); #1;
    load_en = 1'b0;

    @(posedge clk); #1;
    start = 1'b1;
    @(posedge clk); #1;
    start = 1'b0;

    wait (done == 1'b1);
    @(posedge clk); #1;

    // ---- compare FWD output ----
    errors_fwd = 0;
    for (i = 0; i < N; i = i + 1) begin
      rd_addr = i[LOGN-1:0];
      #1;
      if (rd_data !== fwd_exp[i][W-1:0]) begin
        errors_fwd++;
        if (errors_fwd <= 5)
          $display("  MISMATCH idx=%0d exp=%0d got=%0d", i, fwd_exp[i], rd_data);
      end
    end

    // ---- Inverse NTT (round-trip) ----
    op_mode = MODE_INV;
    @(posedge clk); #1;
    start = 1'b1;
    @(posedge clk); #1;
    start = 1'b0;

    wait (done == 1'b1);
    @(posedge clk); #1;

    // ---- compare round-trip with original input ----
    errors_rt = 0;
    for (i = 0; i < N; i = i + 1) begin
      rd_addr = i[LOGN-1:0];
      #1;
      if (rd_data !== coeff_mem[i][W-1:0]) begin
        errors_rt++;
        if (errors_rt <= 5)
          $display("  RT MISMATCH idx=%0d exp=%0d got=%0d", i, coeff_mem[i], rd_data);
      end
    end

    $display("TEST_CASE_%02d FWD: %0d / %0d errors", IDX, errors_fwd, N);
    $display("TEST_CASE_%02d RNDTRIP: %0d / %0d errors", IDX, errors_rt, N);

    if (errors_fwd == 0 && errors_rt == 0)
      $display("*** TEST_CASE_%02d PASS ***", IDX);
    else
      $display("*** TEST_CASE_%02d FAIL ***", IDX);

    $finish;
  end

  initial begin
    #200000;
    $display("TEST_CASE_%02d TIMEOUT", IDX);
    $finish;
  end
endmodule
