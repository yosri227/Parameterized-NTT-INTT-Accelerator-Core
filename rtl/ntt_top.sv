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
//
// Completion semantics: `done` asserts only after every pending write has
// actually landed in memory. A DRAIN state (WR_LAT cycles) follows the last
// RUN stage and the SCALE pass, covering the BU's fixed pipeline latency;
// entering ST_DONE therefore coincides with the final data commit, so
// results can be read out combinationally in the first `done` cycle.
//
// Read-out stability: the output-buffer select is captured at `start`,
// so changing `op_mode` after completion cannot mux the wrong buffer.
// The operating mode is likewise captured at `start` (mode_q): a glitch or
// change on op_mode mid-operation cannot corrupt addressing/twiddles. The
// load interface and the output-select capture intentionally sample live
// op_mode - drive both before asserting `start`.
// =============================================================================
module ntt_top #(
  parameter int unsigned Q     = ntt_pkg::Q,
  parameter int unsigned W     = ntt_pkg::W,
  parameter int unsigned MULW  = ntt_pkg::MULW,
  parameter int unsigned N     = ntt_pkg::N,
  parameter int unsigned LOGN  = ntt_pkg::LOGN,
  parameter longint unsigned MU = ntt_pkg::BARRETT_MU,
  parameter int unsigned NINV  = ntt_pkg::N_INV,
  parameter bit          PIPELINE = 1'b1
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

  // Write-back delay that matches the butterfly output latency. A pipelined
  // BU holds its outputs stable for WR_LAT=2 cycles (one full stage-A/B
  // round trip), so the address/valid path is delayed by a matching shift
  // register. A combinational BU (latency 0) changes outputs every cycle,
  // so its results MUST be written back in the same cycle - any delay would
  // capture the next lane's data. DRAIN_CYCLES is the FSM wait that lets
  // every in-flight write commit before ST_DONE; it also always covers the
  // scale pass's fixed 1-cycle result register.
  localparam int unsigned WR_LAT       = PIPELINE ? 2 : 0;
  localparam int unsigned DRAIN_CYCLES = PIPELINE ? 2 : 1;

  // The pipelined BU commits its writes WR_LAT cycles after the corresponding
  // read, so across a stage boundary the early lanes of stage s+1 can race the
  // final writes of stage s. The worst-case cross-stage dependency lag is
  // QTR/2-1 cycles, which is only covered by the QTR-cycle stage span when
  // QTR >= 4, i.e. N >= 16. All supported schemes have N >= 128.
  initial begin
    if (((Q - 1) % (2 * N)) != 0) begin
      $display("FATAL: ntt_top: Q-1 is not divisible by 2N - incomplete radix-2 NTT (bad SCHEME/N pair)");
      $finish;
    end
    if (N < 16) begin
      $display("FATAL: ntt_top: N=%0d < 16 - ping-pong write pipeline races next-stage reads (stage span QTR=%0d must be >= 4)", N, QTR);
      $finish;
    end
  end

  // ------------------------------------------------------------------
  // Storage: two ping-pong buffers, each N words. Modeled as simple
  // multi-port register arrays here for clarity/simulation; a real ASIC/FPGA
  // target would map these onto banked SRAM (2 read + 2 write ports each).
  // ------------------------------------------------------------------
  logic [W-1:0] bufA [0:N-1];
  logic [W-1:0] bufB [0:N-1];

  typedef enum logic [2:0] {ST_IDLE, ST_RUN, ST_DRAIN, ST_SCALE, ST_DONE} state_e;
  state_e state, state_n;

  // current/other buffer selector: 0 => current=A,other=B ; 1 => current=B,other=A
  logic cur_sel, cur_sel_n;

  // op_mode latched at start; drives all RUN-phase datapath and control.
  // FSM branches that consume start itself keep sampling live op_mode
  // because mode_q still holds the previous op on that edge.
  ntt_pkg::ntt_mode_e mode_q;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)     mode_q <= ntt_pkg::MODE_FWD;
    else if (start) mode_q <= op_mode;
  end

  // ------------------------------------------------------------------
  // FSR-based stage sequencer (Reordering Unit)
  // ------------------------------------------------------------------
  logic stage_adv, stage_ld;
  logic [LOGN-1:0] stage_num;
  logic last_stage;

  reorder_unit #(.N(N), .LOGN(LOGN)) u_ru (
    .clk(clk), .rst_n(rst_n),
    .stage_adv(stage_adv), .stage_ld(stage_ld),
    .stage_num(stage_num), .last_stage(last_stage)
  );

  // INV runs stages in reverse algorithmic order (LOGN-1 .. 0) even though
  // the FSR ring always counts its own passes 0..LOGN-1; this reversed
  // index is what the twiddle-exponent formula actually needs (verified
  // against the Python golden model).
  logic [LOGN-1:0] stage_eff;
  assign stage_eff = (mode_q == MODE_FWD) ? stage_num : (LOGN-1 - stage_num);

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
    if (mode_q == MODE_FWD) begin
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
    .mode(mode_q),
    .addr_a(twaddr0), .tw_a(tw0),
    .addr_b(twaddr1), .tw_b(tw1)
  );

  // ------------------------------------------------------------------
  // Memory read mux (current buffer) for the two BUs
  // ------------------------------------------------------------------
  logic [W-1:0] bu0_a_in, bu0_b_in, bu1_a_in, bu1_b_in;

  always_comb begin
    if (cur_sel == 1'b0) begin // current = bufA
      bu0_a_in = bufA[pairA0_rd]; bu0_b_in = bufA[pairA1_rd];
      bu1_a_in = bufA[pairB0_rd]; bu1_b_in = bufA[pairB1_rd];
    end else begin             // current = bufB
      bu0_a_in = bufB[pairA0_rd]; bu0_b_in = bufB[pairA1_rd];
      bu1_a_in = bufB[pairB0_rd]; bu1_b_in = bufB[pairB1_rd];
    end
  end

  // ------------------------------------------------------------------
  // Dual Butterfly Units
  // ------------------------------------------------------------------
  logic bu_valid_in, bu0_valid_out, bu1_valid_out;
  logic [W-1:0] bu0_y0, bu0_y1, bu1_y0, bu1_y1;

  butterfly_unit #(.Q(Q), .W(W), .MULW(MULW), .MU(MU), .PIPELINE(PIPELINE)) u_bu0 (
    .clk(clk), .rst_n(rst_n), .valid_in(bu_valid_in), .mode(mode_q),
    .a_in(bu0_a_in), .b_in(bu0_b_in), .w_in(tw0),
    .y0_out(bu0_y0), .y1_out(bu0_y1), .valid_out(bu0_valid_out)
  );
  butterfly_unit #(.Q(Q), .W(W), .MULW(MULW), .MU(MU), .PIPELINE(PIPELINE)) u_bu1 (
    .clk(clk), .rst_n(rst_n), .valid_in(bu_valid_in), .mode(mode_q),
    .a_in(bu1_a_in), .b_in(bu1_b_in), .w_in(tw1),
    .y0_out(bu1_y0), .y1_out(bu1_y1), .valid_out(bu1_valid_out)
  );

  // ------------------------------------------------------------------
  // Write-back: delay address / target-buffer-select / valid by exactly
  // WR_LAT cycles to match the BU's pipeline latency (no extra buffering:
  // one shift register chain). Only the valid chain needs a reset; the
  // address/select chains are garbage-safe while invalid.
  // ------------------------------------------------------------------
  generate
    if (WR_LAT > 0) begin : g_wr_pipe
      logic [LOGN-1:0]   wrA0_q [WR_LAT];
      logic [LOGN-1:0]   wrA1_q [WR_LAT];
      logic [LOGN-1:0]   wrB0_q [WR_LAT];
      logic [LOGN-1:0]   wrB1_q [WR_LAT];
      logic              wr_other_q [WR_LAT];
      logic [WR_LAT-1:0] wr_valid_q;

      always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
          wr_valid_q <= '0;
        end else begin
          wr_valid_q[0] <= bu_valid_in && (state == ST_RUN);
          for (int d = 1; d < WR_LAT; d++) wr_valid_q[d] <= wr_valid_q[d-1];

          wrA0_q[0] <= pairA0_wr; wrA1_q[0] <= pairA1_wr;
          wrB0_q[0] <= pairB0_wr; wrB1_q[0] <= pairB1_wr;
          wr_other_q[0] <= ~cur_sel;
          for (int d = 1; d < WR_LAT; d++) begin
            wrA0_q[d] <= wrA0_q[d-1]; wrA1_q[d] <= wrA1_q[d-1];
            wrB0_q[d] <= wrB0_q[d-1]; wrB1_q[d] <= wrB1_q[d-1];
            wr_other_q[d] <= wr_other_q[d-1];
          end
        end
      end

      always_ff @(posedge clk) begin
        if (wr_valid_q[WR_LAT-1]) begin
          if (wr_other_q[WR_LAT-1] == 1'b0) begin // other = bufA
            bufA[wrA0_q[WR_LAT-1]] <= bu0_y0; bufA[wrA1_q[WR_LAT-1]] <= bu0_y1;
            bufA[wrB0_q[WR_LAT-1]] <= bu1_y0; bufA[wrB1_q[WR_LAT-1]] <= bu1_y1;
          end else begin                          // other = bufB
            bufB[wrA0_q[WR_LAT-1]] <= bu0_y0; bufB[wrA1_q[WR_LAT-1]] <= bu0_y1;
            bufB[wrB0_q[WR_LAT-1]] <= bu1_y0; bufB[wrB1_q[WR_LAT-1]] <= bu1_y1;
          end
        end
      end
    end else begin : g_wr_direct
      // combinational BU: results are only valid this cycle - write now
      always_ff @(posedge clk) begin
        if (bu_valid_in && (state == ST_RUN)) begin
          if (~cur_sel == 1'b0) begin             // other = bufA
            bufA[pairA0_wr] <= bu0_y0; bufA[pairA1_wr] <= bu0_y1;
            bufA[pairB0_wr] <= bu1_y0; bufA[pairB1_wr] <= bu1_y1;
          end else begin                          // other = bufB
            bufB[pairA0_wr] <= bu0_y0; bufB[pairA1_wr] <= bu0_y1;
            bufB[pairB0_wr] <= bu1_y0; bufB[pairB1_wr] <= bu1_y1;
          end
        end
      end
    end
  endgenerate

  // ------------------------------------------------------------------
  // 1/N scaling pass (INV only): multiply every word of bufA by N_INV mod Q
  // through a dedicated Barrett reducer once the last INV stage has drained.
  // ------------------------------------------------------------------
  logic [LOGN-1:0] scale_addr, scale_addr_n;
  logic [MULW-1:0] sc_prod;
  logic [MULW-1:0] sc_barrett_in;
  logic [W-1:0]    sc_res;

  assign sc_prod = bufA[scale_addr] * NINV[W-1:0];

  barrett_reduce #(.Q(Q), .W(W), .MULW(MULW), .MU(MU)) u_scale_barrett (
    .in_val(sc_barrett_in), .out_val(sc_res)
  );

  generate
    if (PIPELINE) begin : g_scale_pipe
      // read -> reg -> Barrett (comb) -> reg -> write, matching WR_LAT = 2:
      // the final scaled word commits on the last DRAIN cycle before ST_DONE.
      // The address travels through BOTH register stages alongside the data
      // so the write always pairs each result with its own address.
      logic [MULW-1:0]  sc_prod_q;
      logic [W-1:0]     sc_res_q;
      logic [LOGN-1:0]  sc_addr_q [WR_LAT];
      logic [WR_LAT-1:0] sc_valid_q;

      assign sc_barrett_in = sc_prod_q;

      always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
          sc_valid_q <= '0;
        end else begin
          sc_valid_q[0] <= (state == ST_SCALE);
          for (int d = 1; d < WR_LAT; d++) sc_valid_q[d] <= sc_valid_q[d-1];
          sc_prod_q     <= sc_prod;
          sc_addr_q[0]  <= scale_addr;
          sc_res_q      <= sc_res;
          for (int d = 1; d < WR_LAT; d++) sc_addr_q[d] <= sc_addr_q[d-1];
        end
      end
      always_ff @(posedge clk) begin
        if (sc_valid_q[WR_LAT-1]) bufA[sc_addr_q[WR_LAT-1]] <= sc_res_q;
      end
    end else begin : g_scale_comb
      // unpipelined BU variant keeps the original single-register scheme:
      // read + Barrett in the same cycle, result registered beside its
      // address (registering only the address would desync them by one cycle).
      logic [LOGN-1:0] sc_addr_q;
      logic [W-1:0]    sc_res_q;
      logic            sc_valid_q;

      assign sc_barrett_in = sc_prod;

      always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
          sc_valid_q <= 1'b0;
        end else begin
          sc_valid_q <= (state == ST_SCALE);
          sc_addr_q  <= scale_addr;
          sc_res_q   <= sc_res;
        end
      end
      always_ff @(posedge clk) begin
        if (sc_valid_q) bufA[sc_addr_q] <= sc_res_q;
      end
    end
  endgenerate

  // FWD loads into bufA (starting buffer). INV loads into the starting
  // buffer: bufB for odd LOGN, bufA for even LOGN.
  always_ff @(posedge clk) begin
    if (load_en) begin
      if (op_mode == MODE_FWD)                            bufA[load_addr] <= load_data;
      else if (LOGN[0])                                   bufB[load_addr] <= load_data;
      else                                                bufA[load_addr] <= load_data;
    end
  end

  // Output-buffer select captured at start: FWD lands in B iff LOGN odd,
  // INV always lands in A (after SCALE). Latching keeps read-out stable even
  // if op_mode changes afterwards.
  logic rd_buf_b_q;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)     rd_buf_b_q <= 1'b0;
    else if (start) rd_buf_b_q <= (op_mode == MODE_FWD) ? LOGN[0] : 1'b0;
  end
  assign rd_data = rd_buf_b_q ? bufB[rd_addr] : bufA[rd_addr];

  // ------------------------------------------------------------------
  // Control FSM
  //
  //   IDLE -> RUN -> DRAIN -> [SCALE -> DRAIN] -> DONE
  //
  // DRAIN (WR_LAT cycles) covers the BU/scale-pipeline latency after the
  // last RUN lane and after the SCALE pass, so ST_DONE - and therefore
  // `done` - is only ever reached once every write has been committed.
  // ------------------------------------------------------------------
  localparam int unsigned DCW = (DRAIN_CYCLES <= 1) ? 1 : $clog2(DRAIN_CYCLES);
  logic [DCW-1:0] drain_cnt, drain_cnt_n;
  logic drain_to_scale, drain_to_scale_n;

  always_comb begin
    state_n      = state;
    cur_sel_n    = cur_sel;
    lane_cnt_n   = lane_cnt;
    stage_adv    = 1'b0;
    stage_ld     = 1'b0;
    bu_valid_in  = 1'b0;
    scale_addr_n = scale_addr;
    drain_cnt_n  = drain_cnt;
    drain_to_scale_n = drain_to_scale;

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
            state_n          = ST_DRAIN;
            drain_cnt_n      = '0;
            drain_to_scale_n = (mode_q == MODE_INV);
          end
        end else begin
          lane_cnt_n = lane_cnt + 1'b1;
        end
      end

      ST_DRAIN: begin
        if (drain_cnt == DRAIN_CYCLES-1) begin
          if (drain_to_scale) begin
            state_n      = ST_SCALE;
            scale_addr_n = '0;
          end else begin
            state_n = ST_DONE;
          end
        end else begin
          drain_cnt_n = drain_cnt + 1'b1;
        end
      end

      ST_SCALE: begin
        if (scale_addr == N-1) begin
          state_n          = ST_DRAIN;
          drain_cnt_n      = '0;
          drain_to_scale_n = 1'b0;
        end else begin
          scale_addr_n = scale_addr + 1'b1;
        end
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
      state       <= ST_IDLE;
      cur_sel     <= 1'b0;
      lane_cnt    <= '0;
      scale_addr  <= '0;
      drain_cnt   <= '0;
      drain_to_scale <= 1'b0;
    end else begin
      state       <= state_n;
      cur_sel     <= cur_sel_n;
      lane_cnt    <= lane_cnt_n;
      scale_addr  <= scale_addr_n;
      drain_cnt   <= drain_cnt_n;
      drain_to_scale <= drain_to_scale_n;
    end
  end

  assign busy = (state == ST_RUN) || (state == ST_DRAIN) || (state == ST_SCALE);
  assign done = (state == ST_DONE);

endmodule : ntt_top
