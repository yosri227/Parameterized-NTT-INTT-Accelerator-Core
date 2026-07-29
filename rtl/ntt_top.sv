// =============================================================================
// ntt_top.sv
// Top-level parameterized NTT/INTT accelerator.
//
// Dataflow (constant-geometry / Pease algorithm, see reorder_unit.sv):
//   - Two N-word ping-pong buffers (bufA, bufB). Each stage reads the
//     "current" buffer and writes the "other" buffer -> zero read/write
//     port conflicts, no in-place hazards, no extra buffering.
//   - Every stage, for every lane i in [0, N/2), the pairing is FIXED at
//     (i, i+N/2) (the MSB-split property of constant-geometry NTT), so the
//     two Butterfly Units always operate on independent, non-conflicting
//     halves of the memory.
//   - Dual BUs process two lanes per cycle (BU0 -> lane, BU1 -> lane+N/4),
//     so a stage completes in N/4 cycles.
//   - FWD (CT): read address = lane index directly; write address =
//     ru_rotate-left(lane index)  (reorder applied on write-back).
//   - INV (GS): read address = ru_rotate-right(lane index) (reorder applied
//     on read); write address = lane index directly.
//   - FWD starts at bufA, ends at bufB (LOGN stages, odd LOGN -> lands in B).
//   - INV starts at bufB (so it can directly consume a preceding FWD's
//     output with no copy) and ends at bufA, followed by one scale-by-1/N
//     pass over bufA using the shared Barrett reducer.
// =============================================================================
module ntt_top #(
  parameter int unsigned Q     = ntt_pkg::Q,
  parameter int unsigned W     = ntt_pkg::W,
  parameter int unsigned MULW  = ntt_pkg::MULW,
  parameter int unsigned N     = ntt_pkg::N,
  parameter int unsigned LOGN  = ntt_pkg::LOGN,
  parameter longint unsigned MU = ntt_pkg::BARRETT_MU,
  parameter int unsigned NINV  = ntt_pkg::N_INV
)(
  input  logic               clk,
  input  logic               rst_n,

  // load interface (drive before `start`)
  input  logic                load_en,
  input  logic [LOGN-1:0]     load_addr,
  input  logic [W-1:0]        load_data,

  // control
  input  logic                start,
  input  ntt_pkg::ntt_mode_e  op_mode,
  output logic                busy,
  output logic                done,

  // read-out interface (valid once `done` is high, stays valid until next start)
  input  logic [LOGN-1:0]     rd_addr,
  output logic [W-1:0]        rd_data
);

  import ntt_pkg::*;

  localparam int unsigned HALF   = N/2;
  localparam int unsigned QTR    = N/4;
  localparam int unsigned LANEW  = LOGN-1;         // width of a lane index (0..N/2-1)
  localparam int unsigned CNTW   = (QTR <= 1) ? 1 : $clog2(QTR);

  // ------------------------------------------------------------------
  // Storage: two ping-pong buffers, each N words. Modeled as simple
  // multi-port register arrays here for clarity/simulation; a real ASIC/FPGA
  // target would map these onto banked SRAM (2 read + 2 write ports each).
  // ------------------------------------------------------------------
  logic [W-1:0] bufA [0:N-1];
  logic [W-1:0] bufB [0:N-1];

  typedef enum logic [1:0] {ST_IDLE, ST_RUN, ST_SCALE, ST_DONE} state_e;
  state_e state, state_n;

  // current/other buffer selector: 0 => current=A,other=B ; 1 => current=B,other=A
  logic cur_sel, cur_sel_n;

  // ------------------------------------------------------------------
  // FSR-based stage sequencer (Reordering Unit)
  // ------------------------------------------------------------------
  logic stage_adv, stage_ld;
  logic [LOGN-1:0] stage_num;
  logic last_stage;

  reorder_unit #(.N(N), .LOGN(LOGN)) u_ru (
    .clk(clk), .rst_n(rst_n),
    .stage_adv(stage_adv), .stage_ld(stage_ld),
    .mode(op_mode),
    .stage_num(stage_num), .last_stage(last_stage)
  );

  // INV runs stages in reverse algorithmic order (LOGN-1 .. 0) even though
  // the FSR ring always counts its own passes 0..LOGN-1; this reversed
  // index is what the twiddle-exponent formula actually needs (verified
  // against the Python golden model).
  logic [LOGN-1:0] stage_eff;
  assign stage_eff = (op_mode == MODE_FWD) ? stage_num : (LOGN-1 - stage_num);

  // lane counter: 0 .. QTR-1, two lanes serviced per cycle (lane, lane+QTR)
  logic [CNTW-1:0] lane_cnt, lane_cnt_n;
  logic lane_last;
  assign lane_last = (lane_cnt == QTR-1);

  // ------------------------------------------------------------------
  // Address / permutation generation
  // ------------------------------------------------------------------
  logic [LANEW-1:0] lane0, lane1;          // this cycle's two lane indices
  assign lane0 = {{(LANEW-CNTW){1'b0}}, lane_cnt};
  assign lane1 = lane0 + QTR[LANEW-1:0];

  logic [LOGN-1:0] pairA0_rd, pairA1_rd, pairB0_rd, pairB1_rd; // read addrs (2 per lane * 2 lanes)
  logic [LOGN-1:0] pairA0_wr, pairA1_wr, pairB0_wr, pairB1_wr; // write addrs

  // rotate networks (2 lanes x 2 half-indices = 4 rotators for read-side INV,
  // reused combinationally; write-side FWD uses the same 4 rotators on the
  // *read* index since read_addr==lane index for FWD)
  logic [LOGN-1:0] idxA0, idxA1, idxB0, idxB1;      // (lane, lane+HALF) for each of 2 lanes
  assign idxA0 = {1'b0, lane0};                      // lane0        (bank0 half)
  assign idxA1 = {1'b1, lane0};                       // lane0+HALF   (bank1 half)
  assign idxB0 = {1'b0, lane1};                      // lane1
  assign idxB1 = {1'b1, lane1};                       // lane1+HALF

  logic [LOGN-1:0] rotA0, rotA1, rotB0, rotB1;
  ru_rotate #(.LOGN(LOGN)) u_rotA0 (.addr_in(idxA0), .addr_out(rotA0));
  ru_rotate #(.LOGN(LOGN)) u_rotA1 (.addr_in(idxA1), .addr_out(rotA1));
  ru_rotate #(.LOGN(LOGN)) u_rotB0 (.addr_in(idxB0), .addr_out(rotB0));
  ru_rotate #(.LOGN(LOGN)) u_rotB1 (.addr_in(idxB1), .addr_out(rotB1));

  always_comb begin
    if (op_mode == MODE_FWD) begin
      // read directly, rotate-left applied on write-back
      pairA0_rd = idxA0; pairA1_rd = idxA1;
      pairB0_rd = idxB0; pairB1_rd = idxB1;
      pairA0_wr = rotA0; pairA1_wr = rotA1;
      pairB0_wr = rotB0; pairB1_wr = rotB1;
    end else begin
      // rotate-right applied on read, write directly
      pairA0_rd = rotA0; pairA1_rd = rotA1;
      pairB0_rd = rotB0; pairB1_rd = rotB1;
      pairA0_wr = idxA0; pairA1_wr = idxA1;
      pairB0_wr = idxB0; pairB1_wr = idxB1;
    end
  end

  // twiddle exponents (same lane arithmetic feeds both the exponent
  // generator and the address rotator - this is the "recomputed from
  // stage index" addressing the twiddle ROM shares between FWD/INV planes)
  logic [LANEW-1:0] twaddr0, twaddr1;
  tw_exp_gen #(.LOGN(LOGN), .N(N)) u_twexp0 (.stage_num(stage_eff), .lane_idx(lane0), .tw_addr(twaddr0));
  tw_exp_gen #(.LOGN(LOGN), .N(N)) u_twexp1 (.stage_num(stage_eff), .lane_idx(lane1), .tw_addr(twaddr1));

  logic [W-1:0] tw0, tw1;
  twiddle_rom #(.Q(Q), .W(W), .N(N)) u_twrom (
    .clk(clk), .mode(op_mode),
    .addr_a(twaddr0), .tw_a(tw0),
    .addr_b(twaddr1), .tw_b(tw1)
  );

  // ------------------------------------------------------------------
  // Memory read mux (current buffer) for the two BUs
  // ------------------------------------------------------------------
  logic [W-1:0] bu0_a_in, bu0_b_in, bu1_a_in, bu1_b_in;
  logic [LOGN-1:0] rdA0, rdA1, rdB0, rdB1; // BU0 reads (rdA0,rdA1); BU1 reads (rdB0,rdB1)
  assign rdA0 = pairA0_rd; assign rdA1 = pairA1_rd;
  assign rdB0 = pairB0_rd; assign rdB1 = pairB1_rd;

  always_comb begin
    if (cur_sel == 1'b0) begin // current = bufA
      bu0_a_in = bufA[rdA0]; bu0_b_in = bufA[rdA1];
      bu1_a_in = bufA[rdB0]; bu1_b_in = bufA[rdB1];
    end else begin             // current = bufB
      bu0_a_in = bufB[rdA0]; bu0_b_in = bufB[rdA1];
      bu1_a_in = bufB[rdB0]; bu1_b_in = bufB[rdB1];
    end
  end

  // ------------------------------------------------------------------
  // Dual Butterfly Units
  // ------------------------------------------------------------------
  logic bu_valid_in, bu0_valid_out, bu1_valid_out;
  logic [W-1:0] bu0_y0, bu0_y1, bu1_y0, bu1_y1;

  butterfly_unit #(.Q(Q), .W(W), .MULW(MULW), .MU(MU), .PIPELINE(1)) u_bu0 (
    .clk(clk), .rst_n(rst_n), .valid_in(bu_valid_in), .mode(op_mode),
    .a_in(bu0_a_in), .b_in(bu0_b_in), .w_in(tw0),
    .y0_out(bu0_y0), .y1_out(bu0_y1), .valid_out(bu0_valid_out)
  );
  butterfly_unit #(.Q(Q), .W(W), .MULW(MULW), .MU(MU), .PIPELINE(1)) u_bu1 (
    .clk(clk), .rst_n(rst_n), .valid_in(bu_valid_in), .mode(op_mode),
    .a_in(bu1_a_in), .b_in(bu1_b_in), .w_in(tw1),
    .y0_out(bu1_y0), .y1_out(bu1_y1), .valid_out(bu1_valid_out)
  );

  // delay the write-address/other-buffer-select by 1 cycle to match the BU's
  // fixed 1-cycle pipeline latency (no extra buffering: a single register)
  logic [LOGN-1:0] wrA0_d, wrA1_d, wrB0_d, wrB1_d;
  logic wr_other_d, wr_valid_d;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      wr_valid_d <= 1'b0;
    end else begin
      wrA0_d <= pairA0_wr; wrA1_d <= pairA1_wr;
      wrB0_d <= pairB0_wr; wrB1_d <= pairB1_wr;
      wr_other_d <= ~cur_sel;
      wr_valid_d <= bu_valid_in && (state == ST_RUN);
    end
  end

  always_ff @(posedge clk) begin
    if (wr_valid_d) begin
      if (wr_other_d == 1'b0) begin // other = bufA
        bufA[wrA0_d] <= bu0_y0; bufA[wrA1_d] <= bu0_y1;
        bufA[wrB0_d] <= bu1_y0; bufA[wrB1_d] <= bu1_y1;
      end else begin                 // other = bufB
        bufB[wrA0_d] <= bu0_y0; bufB[wrA1_d] <= bu0_y1;
        bufB[wrB0_d] <= bu1_y0; bufB[wrB1_d] <= bu1_y1;
      end
    end
  end

  // ------------------------------------------------------------------
  // 1/N scaling pass (INV only): reuse a Barrett reducer to multiply every
  // word of bufA by N_INV mod Q once the last INV stage has drained.
  // ------------------------------------------------------------------
  logic [LOGN-1:0] scale_addr, scale_addr_n;
  logic [MULW-1:0] scale_prod;
  logic [W-1:0]    scale_res;
  logic            scale_valid_d;
  logic [LOGN-1:0] scale_addr_d;
  logic [W-1:0]    scale_res_d;

  assign scale_prod = bufA[scale_addr] * NINV[W-1:0];
  barrett_reduce #(.Q(Q), .W(W), .MULW(MULW), .MU(MU)) u_scale_barrett (
    .in_val(scale_prod), .out_val(scale_res)
  );

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      scale_valid_d <= 1'b0;
    end else begin
      scale_valid_d <= (state == ST_SCALE);
      scale_addr_d  <= scale_addr;
      scale_res_d   <= scale_res;   // must be captured the SAME cycle as scale_addr_d,
                                     // since scale_res is purely combinational from
                                     // scale_addr - registering only the address and
                                     // not the data would desync them by one cycle.
    end
  end
  always_ff @(posedge clk) begin
    if (scale_valid_d) bufA[scale_addr_d] <= scale_res_d;
  end

  // FWD loads into bufA (starting buffer). INV loads into the starting
  // buffer: bufB for odd LOGN, bufA for even LOGN.
  always_ff @(posedge clk) begin
    if (load_en) begin
      if (op_mode == MODE_FWD)                            bufA[load_addr] <= load_data;
      else if (LOGN[0])                                   bufB[load_addr] <= load_data;
      else                                                bufA[load_addr] <= load_data;
    end
  end

  // FWD result lands in: B if LOGN odd, A if LOGN even.
  // INV result always lands in A (after SCALE), regardless of LOGN parity.
  assign rd_data = (op_mode == MODE_FWD) ?
    (LOGN[0] ? bufB[rd_addr] : bufA[rd_addr]) :
    bufA[rd_addr];

  // ------------------------------------------------------------------
  // Control FSM
  // ------------------------------------------------------------------
  always_comb begin
    state_n      = state;
    cur_sel_n    = cur_sel;
    lane_cnt_n   = lane_cnt;
    stage_adv    = 1'b0;
    stage_ld     = 1'b0;
    bu_valid_in  = 1'b0;
    scale_addr_n = scale_addr;

    unique case (state)
      ST_IDLE: begin
        if (start) begin
          state_n   = ST_RUN;
          // FWD always starts reading from bufA. INV starts reading from the
          // buffer the preceding FWD left its result in (bufB if LOGN odd,
          // bufA if LOGN even) so that the INV NTT result always lands in
          // bufA for the SCALE pass.
          cur_sel_n = (op_mode == MODE_FWD) ? 1'b0 : LOGN[0];
          lane_cnt_n = '0;
          stage_ld  = 1'b1;
        end
      end

      ST_RUN: begin
        bu_valid_in = 1'b1;
        if (lane_last) begin
          lane_cnt_n = '0;
          stage_adv  = 1'b1;
          cur_sel_n  = ~cur_sel;
          if (last_stage) begin
            if (op_mode == MODE_INV) state_n = ST_SCALE;
            else                     state_n = ST_DONE;
            scale_addr_n = '0;
          end
        end else begin
          lane_cnt_n = lane_cnt + 1'b1;
        end
      end

      ST_SCALE: begin
        if (scale_addr == N-1) state_n = ST_DONE;
        else                    scale_addr_n = scale_addr + 1'b1;
      end

      ST_DONE: begin
        if (start) begin
          state_n   = ST_RUN;
          cur_sel_n = (op_mode == MODE_FWD) ? 1'b0 : LOGN[0];
          lane_cnt_n = '0;
          stage_ld  = 1'b1;
        end
      end

      default: state_n = ST_IDLE;
    endcase
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state    <= ST_IDLE;
      cur_sel  <= 1'b0;
      lane_cnt <= '0;
      scale_addr <= '0;
    end else begin
      state    <= state_n;
      cur_sel  <= cur_sel_n;
      lane_cnt <= lane_cnt_n;
      scale_addr <= scale_addr_n;
    end
  end

  assign busy = (state == ST_RUN) || (state == ST_SCALE);
  assign done = (state == ST_DONE);

endmodule : ntt_top
