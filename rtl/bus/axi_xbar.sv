// AXI4 crossbar: N masters, M slaves, address decode, round-robin
// arbitration per slave, a DECERR responder for unmapped addresses
// (Phase G, buildplan 6.2).
//
// Decode: slave s owns every address with (addr & S_MASK[s]) == S_BASE[s];
// the first match wins; no match goes to the DECERR responder, which takes
// the whole burst and answers DECERR (reads: every beat, RLAST on the last).
//
// Arbitration, per slave and per direction: a registered grant. At an edge
// where a slave is free, its arbiter picks one of the masters requesting it,
// round-robin from the master after the last one granted; from the next
// cycle that master's AR (or AW) is forwarded until the slave takes it.
// READY towards a master is then only ever its granted slave's READY, and
// a master is never granted on a VALID it has not raised, so no READY here
// depends combinationally on any VALID: no ready/valid loop can form, for
// any master or slave. The cost is one cycle per transaction.
//
// Outstanding transactions: one read and one write per master, and one
// read and one write per slave, at a time (MAX_OUTSTANDING = 1). A read
// path is held from AR until RLAST is taken, a write path from AW until B is
// taken, so responses need no IDs and reach the right master by construction.
// W follows AW: a master's write data is routed only once its address has
// been granted (AXI lets a slave wait for AW before WREADY; the masters on
// this SoC raise AWVALID without waiting for WREADY).
//
// Ports are packed arrays, index = master or slave number.

module axi_xbar #(
  parameter  int                        N      = 2,      // masters
  parameter  int                        M      = 2,      // slaves
  parameter  int                        ADDR_W = 32,
  parameter  int                        DATA_W = 32,
  // slave s's base and mask at [s*ADDR_W +: ADDR_W] (flat: Yosys reads no
  // packed-array parameter)
  parameter  logic [M*ADDR_W-1:0]       S_BASE = '0,
  parameter  logic [M*ADDR_W-1:0]       S_MASK = '0,
  localparam int                        STRB_W = DATA_W / 8,
  localparam int                        MI_W   = (N > 1) ? $clog2(N) : 1,
  localparam int                        SI_W   = $clog2(M + 1)    // + DECERR
) (
  input  logic                         clk_i,
  input  logic                         rst_i,
`ifdef FORMAL
  // per target: read busy, write busy, write's WLAST passed -- for the
  // harness's strengthening invariants (tb/formal/axi_xbar_formal.sv)
  output logic [M:0]                   f_rb_o,
  output logic [M:0]                   f_wb_o,
  output logic [M:0]                   f_wl_o,
`endif

  // from the masters
  input  logic [N-1:0][ADDR_W-1:0]     m_araddr_i,
  input  logic [N-1:0][7:0]            m_arlen_i,
  input  logic [N-1:0][2:0]            m_arsize_i,
  input  logic [N-1:0][1:0]            m_arburst_i,
  input  logic [N-1:0]                 m_arvalid_i,
  output logic [N-1:0]                 m_arready_o,
  output logic [N-1:0][DATA_W-1:0]     m_rdata_o,
  output logic [N-1:0][1:0]            m_rresp_o,
  output logic [N-1:0]                 m_rlast_o,
  output logic [N-1:0]                 m_rvalid_o,
  input  logic [N-1:0]                 m_rready_i,
  input  logic [N-1:0][ADDR_W-1:0]     m_awaddr_i,
  input  logic [N-1:0][7:0]            m_awlen_i,
  input  logic [N-1:0][2:0]            m_awsize_i,
  input  logic [N-1:0][1:0]            m_awburst_i,
  input  logic [N-1:0]                 m_awvalid_i,
  output logic [N-1:0]                 m_awready_o,
  input  logic [N-1:0][DATA_W-1:0]     m_wdata_i,
  input  logic [N-1:0][STRB_W-1:0]     m_wstrb_i,
  input  logic [N-1:0]                 m_wlast_i,
  input  logic [N-1:0]                 m_wvalid_i,
  output logic [N-1:0]                 m_wready_o,
  output logic [N-1:0][1:0]            m_bresp_o,
  output logic [N-1:0]                 m_bvalid_o,
  input  logic [N-1:0]                 m_bready_i,

  // to the slaves
  output logic [M-1:0][ADDR_W-1:0]     s_araddr_o,
  output logic [M-1:0][7:0]            s_arlen_o,
  output logic [M-1:0][2:0]            s_arsize_o,
  output logic [M-1:0][1:0]            s_arburst_o,
  output logic [M-1:0]                 s_arvalid_o,
  input  logic [M-1:0]                 s_arready_i,
  input  logic [M-1:0][DATA_W-1:0]     s_rdata_i,
  input  logic [M-1:0][1:0]            s_rresp_i,
  input  logic [M-1:0]                 s_rlast_i,
  input  logic [M-1:0]                 s_rvalid_i,
  output logic [M-1:0]                 s_rready_o,
  output logic [M-1:0][ADDR_W-1:0]     s_awaddr_o,
  output logic [M-1:0][7:0]            s_awlen_o,
  output logic [M-1:0][2:0]            s_awsize_o,
  output logic [M-1:0][1:0]            s_awburst_o,
  output logic [M-1:0]                 s_awvalid_o,
  input  logic [M-1:0]                 s_awready_i,
  output logic [M-1:0][DATA_W-1:0]     s_wdata_o,
  output logic [M-1:0][STRB_W-1:0]     s_wstrb_o,
  output logic [M-1:0]                 s_wlast_o,
  output logic [M-1:0]                 s_wvalid_o,
  input  logic [M-1:0]                 s_wready_i,
  input  logic [M-1:0][1:0]            s_bresp_i,
  input  logic [M-1:0]                 s_bvalid_i,
  output logic [M-1:0]                 s_bready_o
);

  localparam int          T      = M + 1;      // targets: the slaves, then DECERR
  localparam int          DEC    = M;          // the DECERR responder's index
  localparam logic [1:0]  DECERR = 2'b11;

  // ---- decode -------------------------------------------------------------
  function automatic logic [SI_W-1:0] decode(input logic [ADDR_W-1:0] a);
    decode = SI_W'(DEC);
    for (int s = M - 1; s >= 0; s--)
      if ((a & S_MASK[s*ADDR_W +: ADDR_W]) == S_BASE[s*ADDR_W +: ADDR_W]) decode = SI_W'(s);
  endfunction

  logic [N-1:0][SI_W-1:0] ar_tgt, aw_tgt;
  always_comb begin
    for (int m = 0; m < N; m++) begin
      ar_tgt[m] = decode(m_araddr_i[m]);
      aw_tgt[m] = decode(m_awaddr_i[m]);
    end
  end

  // ---- per-target state ----------------------------------------------------
  // granted:  the arbiter picked a master, its address not yet taken
  // busy:     its address was taken, the response not yet finished
  logic [T-1:0]          rg_q, rb_q, wg_q, wb_q;
  logic [T-1:0]          wl_q;      // busy write's WLAST has passed: W closed
  logic [T-1:0][MI_W-1:0] rown_q, wown_q;        // the master, when granted or busy
  logic [T-1:0][MI_W-1:0] rrr_q, wrr_q;          // last granted, for round-robin

  // per master: a read / a write in flight (requested, granted or busy)
  logic [N-1:0] m_rd_q, m_wr_q;

  // a master may be granted when it requests, has nothing in flight
  // already, and is not already granted somewhere
  logic [T-1:0][N-1:0] rreq, wreq;
  always_comb begin
    for (int t = 0; t < T; t++)
      for (int m = 0; m < N; m++) begin
        rreq[t][m] = m_arvalid_i[m] && ar_tgt[m] == SI_W'(t) && !m_rd_q[m];
        wreq[t][m] = m_awvalid_i[m] && aw_tgt[m] == SI_W'(t) && !m_wr_q[m];
      end
  end

  // round-robin: the first requester after the last one granted
  function automatic logic [MI_W:0] pick(input logic [N-1:0] req,
                                         input logic [MI_W-1:0] last);
    pick = '0;                                    // {found, index}
    for (int k = N; k >= 1; k--) begin
      logic [MI_W-1:0] m;
      m = MI_W'((int'(last) + k) % N);
      if (req[m]) pick = {1'b1, m};
    end
  endfunction

  // ---- the DECERR responder ------------------------------------------------
  logic [7:0] dec_rleft_q;
  logic       dec_rvalid_q, dec_wdone_q, dec_bvalid_q;

  // ---- what each target sees, and what comes back ---------------------------
  // target t's forwarded AR/AW: the granted master's, while granted
  logic [T-1:0] t_arvalid, t_arready, t_awvalid, t_awready;
  logic [T-1:0] t_rvalid, t_rlast, t_rready, t_wvalid, t_wready, t_wlast;
  logic [T-1:0] t_bvalid, t_bready;
  logic [T-1:0][DATA_W-1:0] t_rdata;
  logic [T-1:0][1:0]        t_rresp, t_bresp;

  always_comb begin
    for (int t = 0; t < T; t++) begin
      t_arvalid[t] = rg_q[t] && m_arvalid_i[rown_q[t]];
      t_awvalid[t] = wg_q[t] && m_awvalid_i[wown_q[t]];
      // W is routed from AW until WLAST, never after: a master may start its
      // next write's W beats before that write's AW, and those must not
      // reach this target while it finishes the last one (found by formal,
      // X1, 2026-11-05; simulation's masters never started W early)
      t_wvalid[t]  = wb_q[t] && !wl_q[t] && m_wvalid_i[wown_q[t]];
      t_wlast[t]   = m_wlast_i[wown_q[t]];
      t_rready[t]  = rb_q[t] && m_rready_i[rown_q[t]];
      t_bready[t]  = wb_q[t] && m_bready_i[wown_q[t]];
    end
    for (int s = 0; s < M; s++) begin
      t_arready[s] = s_arready_i[s];
      t_awready[s] = s_awready_i[s];
      t_wready[s]  = s_wready_i[s];
      t_rvalid[s]  = s_rvalid_i[s];
      t_rlast[s]   = s_rlast_i[s];
      t_rdata[s]   = s_rdata_i[s];
      t_rresp[s]   = s_rresp_i[s];
      t_bvalid[s]  = s_bvalid_i[s];
      t_bresp[s]   = s_bresp_i[s];
    end
    t_arready[DEC] = 1'b1;
    t_awready[DEC] = 1'b1;
    t_wready[DEC]  = !dec_wdone_q;
    t_rvalid[DEC]  = dec_rvalid_q;
    t_rlast[DEC]   = dec_rleft_q == '0;
    t_rdata[DEC]   = '0;
    t_rresp[DEC]   = DECERR;
    t_bvalid[DEC]  = dec_bvalid_q;
    t_bresp[DEC]   = DECERR;
  end

  // slave ports: the granted master's request and data
  always_comb begin
    for (int s = 0; s < M; s++) begin
      s_araddr_o[s]  = m_araddr_i[rown_q[s]];
      s_arlen_o[s]   = m_arlen_i[rown_q[s]];
      s_arsize_o[s]  = m_arsize_i[rown_q[s]];
      s_arburst_o[s] = m_arburst_i[rown_q[s]];
      s_arvalid_o[s] = t_arvalid[s];
      s_rready_o[s]  = t_rready[s];
      s_awaddr_o[s]  = m_awaddr_i[wown_q[s]];
      s_awlen_o[s]   = m_awlen_i[wown_q[s]];
      s_awsize_o[s]  = m_awsize_i[wown_q[s]];
      s_awburst_o[s] = m_awburst_i[wown_q[s]];
      s_awvalid_o[s] = t_awvalid[s];
      s_wdata_o[s]   = m_wdata_i[wown_q[s]];
      s_wstrb_o[s]   = m_wstrb_i[wown_q[s]];
      s_wlast_o[s]   = t_wlast[s];
      s_wvalid_o[s]  = t_wvalid[s];
      s_bready_o[s]  = t_bready[s];
    end
  end

  // master ports: from whichever target it holds (at most one per direction)
  always_comb begin
    for (int m = 0; m < N; m++) begin
      m_arready_o[m] = 1'b0;
      m_awready_o[m] = 1'b0;
      m_wready_o[m]  = 1'b0;
      m_rvalid_o[m]  = 1'b0;
      m_rlast_o[m]   = 1'b0;
      m_rdata_o[m]   = '0;
      m_rresp_o[m]   = '0;
      m_bvalid_o[m]  = 1'b0;
      m_bresp_o[m]   = '0;
      for (int t = 0; t < T; t++) begin
        if (rg_q[t] && rown_q[t] == MI_W'(m)) m_arready_o[m] = t_arready[t];
        if (wg_q[t] && wown_q[t] == MI_W'(m)) m_awready_o[m] = t_awready[t];
        if (wb_q[t] && !wl_q[t] && wown_q[t] == MI_W'(m)) m_wready_o[m] = t_wready[t];
        if (rb_q[t] && rown_q[t] == MI_W'(m)) begin
          m_rvalid_o[m] = t_rvalid[t];
          m_rlast_o[m]  = t_rlast[t];
          m_rdata_o[m]  = t_rdata[t];
          m_rresp_o[m]  = t_rresp[t];
        end
        if (wb_q[t] && wown_q[t] == MI_W'(m)) begin
          m_bvalid_o[m] = t_bvalid[t];
          m_bresp_o[m]  = t_bresp[t];
        end
      end
    end
  end

  // ---- state ----------------------------------------------------------------
  logic [T-1:0][MI_W:0] rpick, wpick;
  always_comb begin
    for (int t = 0; t < T; t++) begin
      rpick[t] = pick(rreq[t], rrr_q[t]);
      wpick[t] = pick(wreq[t], wrr_q[t]);
    end
  end

  always_ff @(posedge clk_i) begin
    if (rst_i) begin
      rg_q <= '0; rb_q <= '0; wg_q <= '0; wb_q <= '0; wl_q <= '0;
      rown_q <= '0; wown_q <= '0;
      rrr_q <= {T{MI_W'(N - 1)}};
      wrr_q <= {T{MI_W'(N - 1)}};
      m_rd_q <= '0; m_wr_q <= '0;
    end else begin
      for (int t = 0; t < T; t++) begin
        // reads
        if (!rg_q[t] && !rb_q[t]) begin
          if (rpick[t][MI_W]) begin
            rg_q[t]   <= 1'b1;
            rown_q[t] <= rpick[t][MI_W-1:0];
            rrr_q[t]  <= rpick[t][MI_W-1:0];
            m_rd_q[rpick[t][MI_W-1:0]] <= 1'b1;
          end
        end else if (rg_q[t]) begin
          if (t_arvalid[t] && t_arready[t]) begin
            rg_q[t] <= 1'b0;
            rb_q[t] <= 1'b1;
          end
        end else if (t_rvalid[t] && t_rready[t] && t_rlast[t]) begin
          rb_q[t] <= 1'b0;
          m_rd_q[rown_q[t]] <= 1'b0;
        end
        // writes
        if (!wg_q[t] && !wb_q[t]) begin
          if (wpick[t][MI_W]) begin
            wg_q[t]   <= 1'b1;
            wown_q[t] <= wpick[t][MI_W-1:0];
            wrr_q[t]  <= wpick[t][MI_W-1:0];
            m_wr_q[wpick[t][MI_W-1:0]] <= 1'b1;
          end
        end else if (wg_q[t]) begin
          if (t_awvalid[t] && t_awready[t]) begin
            wg_q[t] <= 1'b0;
            wb_q[t] <= 1'b1;
            wl_q[t] <= 1'b0;
          end
        end else begin
          if (t_wvalid[t] && t_wready[t] && t_wlast[t]) wl_q[t] <= 1'b1;
          if (t_bvalid[t] && t_bready[t]) begin
            wb_q[t] <= 1'b0;
            wl_q[t] <= 1'b0;
            m_wr_q[wown_q[t]] <= 1'b0;
          end
        end
      end
    end
  end

  // DECERR: a read answers len + 1 DECERR beats; a write takes every W beat,
  // then answers DECERR once
  always_ff @(posedge clk_i) begin
    if (rst_i) begin
      dec_rleft_q  <= '0;
      dec_rvalid_q <= 1'b0;
      dec_wdone_q  <= 1'b0;
      dec_bvalid_q <= 1'b0;
    end else begin
      if (t_arvalid[DEC]) begin
        dec_rleft_q  <= m_arlen_i[rown_q[DEC]];
        dec_rvalid_q <= 1'b1;
      end else if (dec_rvalid_q && t_rready[DEC]) begin
        if (dec_rleft_q == '0) dec_rvalid_q <= 1'b0;
        else                   dec_rleft_q  <= dec_rleft_q - 1'b1;
      end
      if (t_wvalid[DEC] && !dec_wdone_q && t_wlast[DEC]) begin
        dec_wdone_q  <= 1'b1;
        dec_bvalid_q <= 1'b1;
      end else if (dec_bvalid_q && t_bready[DEC]) begin
        dec_bvalid_q <= 1'b0;
        dec_wdone_q  <= 1'b0;
      end
    end
  end

`ifdef FORMAL
  // ---- properties (buildplan 6.2), proven by tb/formal/axi_xbar.sby -------
  // Every assertion is about what this block drives; the harness assumes
  // the AXI rules of the masters and slaves around it.
  localparam int MAX_OUTSTANDING = 1;
  // f_past_valid must start false; the initialiser is waived as in
  // riscv_core's property block (lint flags it otherwise).
  /* verilator lint_off PROCASSINIT */
  logic f_past_valid = 1'b0;
  /* verilator lint_on PROCASSINIT */
  logic [N-1:0] f_r_wait, f_b_wait;
  logic [M-1:0] f_sar_wait, f_saw_wait, f_sw_wait;
  logic [M-1:0][ADDR_W+8+3+2-1:0] f_sar, f_saw;
  logic [M-1:0][DATA_W+STRB_W+1-1:0] f_sw;
  logic [N-1:0][DATA_W+2+1-1:0] f_r;
  logic [N-1:0][1:0] f_b;
  always_ff @(posedge clk_i) begin
    f_past_valid <= 1'b1;
    for (int m = 0; m < N; m++) begin
      f_r_wait[m] <= m_rvalid_o[m] && !m_rready_i[m] && !rst_i;
      f_b_wait[m] <= m_bvalid_o[m] && !m_bready_i[m] && !rst_i;
      f_r[m]      <= {m_rdata_o[m], m_rresp_o[m], m_rlast_o[m]};
      f_b[m]      <= m_bresp_o[m];
    end
    for (int s = 0; s < M; s++) begin
      f_sar_wait[s] <= s_arvalid_o[s] && !s_arready_i[s] && !rst_i;
      f_saw_wait[s] <= s_awvalid_o[s] && !s_awready_i[s] && !rst_i;
      f_sw_wait[s]  <= s_wvalid_o[s] && !s_wready_i[s] && !rst_i;
      f_sar[s] <= {s_araddr_o[s], s_arlen_o[s], s_arsize_o[s], s_arburst_o[s]};
      f_saw[s] <= {s_awaddr_o[s], s_awlen_o[s], s_awsize_o[s], s_awburst_o[s]};
      f_sw[s]  <= {s_wdata_o[s], s_wstrb_o[s], s_wlast_o[s]};
    end
  end

  always_comb begin
    if (f_past_valid && !rst_i) begin
      for (int s = 0; s < M; s++) begin
        // X1: VALID towards a slave holds until READY, its payload stable
        if (f_sar_wait[s]) assert (s_arvalid_o[s] && f_sar[s] == {s_araddr_o[s], s_arlen_o[s], s_arsize_o[s], s_arburst_o[s]});
        if (f_saw_wait[s]) assert (s_awvalid_o[s] && f_saw[s] == {s_awaddr_o[s], s_awlen_o[s], s_awsize_o[s], s_awburst_o[s]});
        if (f_sw_wait[s])  assert (s_wvalid_o[s] && f_sw[s] == {s_wdata_o[s], s_wstrb_o[s], s_wlast_o[s]});
      end
      for (int m = 0; m < N; m++) begin
        // X1: VALID towards a master holds until READY, its payload stable
        if (f_r_wait[m]) assert (m_rvalid_o[m] && f_r[m] == {m_rdata_o[m], m_rresp_o[m], m_rlast_o[m]});
        if (f_b_wait[m]) assert (m_bvalid_o[m] && f_b[m] == m_bresp_o[m]);
      end
      for (int t = 0; t < T; t++) begin
        // X3: one transaction per target per direction, and the flags agree
        assert (!(rg_q[t] && rb_q[t]) && !(wg_q[t] && wb_q[t]));
        if (rg_q[t] || rb_q[t]) assert (m_rd_q[rown_q[t]]);
        if (wg_q[t] || wb_q[t]) assert (m_wr_q[wown_q[t]]);
      end
      for (int m = 0; m < N; m++) begin
        // X3: per master, never more than MAX_OUTSTANDING per direction,
        // and its in-flight flag says exactly whether it holds a target
        assert (f_nr[m] <= MAX_OUTSTANDING && f_nw[m] <= MAX_OUTSTANDING);
        assert (f_nr[m] == int'(m_rd_q[m]) && f_nw[m] == int'(m_wr_q[m]));
      end
    end
  end

  // X4: write response follows write data. Per master: its write's last W
  // beat has passed through (a W handshake with WLAST on its target);
  // cleared by the B handshake. B towards a master only after it.
  logic [N-1:0] f_wlast_q;
  always_ff @(posedge clk_i) begin
    for (int m = 0; m < N; m++) begin
      if (rst_i || (m_bvalid_o[m] && m_bready_i[m])) f_wlast_q[m] <= 1'b0;
      else if (m_wvalid_i[m] && m_wready_o[m] && m_wlast_i[m]) f_wlast_q[m] <= 1'b1;
    end
  end
  always_comb begin
    if (f_past_valid && !rst_i)
      for (int m = 0; m < N; m++)
        if (m_bvalid_o[m]) assert (f_wlast_q[m]);
  end

  // X2 (part): a free target with a request is granted at the next edge,
  // so no request waits on a target nobody holds. (The other part, no READY
  // combinationally from a VALID, is structural: axi_xbar.sby checks the
  // netlist.)
  logic [T-1:0] f_rfree_req_q, f_wfree_req_q;
  always_ff @(posedge clk_i) begin
    for (int t = 0; t < T; t++) begin
      f_rfree_req_q[t] <= !rst_i && !rg_q[t] && !rb_q[t] && |rreq[t];
      f_wfree_req_q[t] <= !rst_i && !wg_q[t] && !wb_q[t] && |wreq[t];
    end
  end
  always_comb begin
    if (f_past_valid && !rst_i)
      for (int t = 0; t < T; t++) begin
        if (f_rfree_req_q[t]) assert (rg_q[t]);
        if (f_wfree_req_q[t]) assert (wg_q[t]);
      end
  end

  assign f_rb_o = rb_q;
  assign f_wb_o = wb_q;
  assign f_wl_o = wl_q;

  // X4's strengthening: the per-master WLAST flag is the target's
  always_comb begin
    if (f_past_valid && !rst_i)
      for (int t = 0; t < T; t++) begin
        if (wb_q[t]) assert (f_wlast_q[wown_q[t]] == wl_q[t]);
        if (wg_q[t]) assert (!f_wlast_q[wown_q[t]]);
        if (!wb_q[t]) assert (!wl_q[t]);
      end
    if (f_past_valid && !rst_i)
      for (int m = 0; m < N; m++)
        if (!m_wr_q[m]) assert (!f_wlast_q[m]);
    // the DECERR responder's write state is the target's
    if (f_past_valid && !rst_i) begin
      assert (dec_wdone_q == (wb_q[DEC] && wl_q[DEC]));
      assert (dec_bvalid_q == dec_wdone_q);
      assert (dec_rvalid_q == rb_q[DEC]);
    end
  end

  // targets held per master, per direction
  int f_nr [N];
  int f_nw [N];
  always_comb begin
    for (int m = 0; m < N; m++) begin
      f_nr[m] = 0;
      f_nw[m] = 0;
      for (int t = 0; t < T; t++) begin
        f_nr[m] += int'((rg_q[t] || rb_q[t]) && rown_q[t] == MI_W'(m));
        f_nw[m] += int'((wg_q[t] || wb_q[t]) && wown_q[t] == MI_W'(m));
      end
    end
  end
`endif

endmodule
