// Copyright 2026
// Solderpad Hardware License, Version 2.1,see LICENSE.md for details.
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// Author: Nik Erlandsson
// Author: Oskar Swärd

module quadrilatero_csr_tile_loader #(
    parameter int unsigned BUS_WIDTH = 128,
    parameter int unsigned N_REGS = 8,
    parameter int unsigned N_ROWS = 4,
    localparam int unsigned RLEN = BUS_WIDTH
) (
    input  logic                          clk_i,
    input  logic                          rst_ni,

    // Bus interface
    output logic                          data_req_o,
    output logic [31:0]                   data_addr_o,
    output logic                          data_we_o,
    output logic [BUS_WIDTH/8 - 1:0]      data_be_o,
    output logic [BUS_WIDTH-1:0]          data_wdata_o,
    input  logic                          data_gnt_i,
    input  logic                          data_rvalid_i,
    input  logic [BUS_WIDTH-1:0]          data_rdata_i,

    // Register Write Port for load unit
    output logic [$clog2(N_REGS)-1:0]     waddr_o,
    output logic [$clog2(N_ROWS)-1:0]     wrowaddr_o,
    output logic [RLEN-1:0]               wdata_o,
    output logic                          we_o,
    output logic                          wlast_o,
    input  logic                          wready_i,

    output logic [xif_pkg::X_ID_WIDTH-1:0] lsu_id_o,

    // Configuration Signals
    input  logic                          start_i,
    input  logic [31:0]                   nnz_offset_i,
    input  logic [31:0]                   cfg_addr_i,
    input  logic [$clog2(N_REGS)-1:0]     operand_reg_i,
    input  logic [xif_pkg::X_ID_WIDTH-1:0] instr_id_i,
    input  logic [31:0]                   n_rows_i,
    output logic                          busy_o,

    output logic                          finished_o,
    input  logic                          finished_ack_i,
    output logic [xif_pkg::X_ID_WIDTH-1:0] finished_instr_id_o
);

  localparam int unsigned BUS_BYTES = BUS_WIDTH / 8;
  localparam int unsigned BUS_ADDR_LSB = (BUS_BYTES > 1) ? $clog2(BUS_BYTES) : 1;

  typedef enum logic [3:0] {
    S_IDLE,
    S_READ_CFG_VAL_BASE,
    S_READ_CFG_COL_BASE,
    S_READ_CFG_ROW_BASE,
    S_FIND_ROW_NEXT,
    S_READ_TILE_COL,
    S_READ_ROW_START,
    S_READ_ROW_END,
    S_READ_COL,
    S_READ_VAL,
    S_WRITE_ROWS,
    S_FINISH
  } sparse_state_t;

  sparse_state_t state_q;
  sparse_state_t state_d;

  logic active_q;
  logic active_d;

  logic wait_rvalid_q;
  logic wait_rvalid_d;
  logic [31:0] pending_addr_q;
  logic [31:0] pending_addr_d;

  logic [31:0] read_word;
  logic        read_done;

  logic [31:0] row_scan_q;
  logic [31:0] row_scan_d;
  logic [31:0] r0_q;
  logic [31:0] r0_d;
  logic [31:0] row_start_q;
  logic [31:0] row_start_d;
  logic [31:0] row_end_q;
  logic [31:0] row_end_d;
  logic [31:0] p_q;
  logic [31:0] p_d;

  logic [2:0] tr_q;
  logic [2:0] tr_d;
  logic [1:0] col_lane_q;
  logic [1:0] col_lane_d;
  logic [2:0] wb_row_q;
  logic [2:0] wb_row_d;

  logic [31:0] nnz_offset_q;
  logic [31:0] nnz_offset_d;
  logic [31:0] cfg_addr_q;
  logic [31:0] cfg_addr_d;
  logic [31:0] val_base_q;
  logic [31:0] val_base_d;
  logic [31:0] col_idx_base_q;
  logic [31:0] col_idx_base_d;
  logic [31:0] row_ptr_base_q;
  logic [31:0] row_ptr_base_d;
  logic [31:0] tile_col0_q;
  logic [31:0] tile_col0_d;

  logic [$clog2(N_REGS)-1:0] waddr_q;
  logic [$clog2(N_REGS)-1:0] waddr_d;
  logic [xif_pkg::X_ID_WIDTH-1:0] instr_id_q;
  logic [xif_pkg::X_ID_WIDTH-1:0] instr_id_d;

  logic [31:0] tile_q [0:3][0:3];
  logic [31:0] tile_d [0:3][0:3];

  logic        mem_need_read;
  logic [31:0] mem_read_addr;
  logic        req_fire;

  logic [31:0] row_idx;

  integer rr;
  integer cc;

  always_comb begin
    row_idx = r0_q + {30'b0, tr_q};
    read_done = wait_rvalid_q && data_rvalid_i;

    data_req_o   = mem_need_read && !wait_rvalid_q;
    data_addr_o  = {mem_read_addr[31:BUS_ADDR_LSB], {BUS_ADDR_LSB{1'b0}}};
    data_we_o    = 1'b0;
    data_be_o    = '1;
    data_wdata_o = '0;

    read_word = data_rdata_i[pending_addr_q[BUS_ADDR_LSB-1:2] * 32 +: 32];
  end

  always_comb begin
    mem_need_read = 1'b0;
    mem_read_addr = 32'h0;

    state_d = state_q;
    active_d = active_q;
    wait_rvalid_d = wait_rvalid_q;
    pending_addr_d = pending_addr_q;

    row_scan_d = row_scan_q;
    r0_d = r0_q;
    row_start_d = row_start_q;
    row_end_d = row_end_q;
    p_d = p_q;
    tr_d = tr_q;
    col_lane_d = col_lane_q;
    wb_row_d = wb_row_q;
    nnz_offset_d = nnz_offset_q;
    cfg_addr_d = cfg_addr_q;
    val_base_d = val_base_q;
    col_idx_base_d = col_idx_base_q;
    row_ptr_base_d = row_ptr_base_q;
    tile_col0_d = tile_col0_q;
    waddr_d = waddr_q;
    instr_id_d = instr_id_q;

    for (rr = 0; rr < 4; rr++) begin
      for (cc = 0; cc < 4; cc++) begin
        tile_d[rr][cc] = tile_q[rr][cc];
      end
    end

    case (state_q)
      S_IDLE: begin
        if (start_i) begin
          for (rr = 0; rr < 4; rr++) begin
            for (cc = 0; cc < 4; cc++) begin
              tile_d[rr][cc] = 32'h0;
            end
          end
          active_d     = 1'b1;
          row_scan_d   = 32'h0;
          r0_d         = 32'h0;
          row_start_d  = 32'h0;
          row_end_d    = 32'h0;
          p_d          = 32'h0;
          tr_d         = 3'b000;
          wb_row_d     = 3'b000;
          col_lane_d   = 2'b00;
          nnz_offset_d = nnz_offset_i;
          cfg_addr_d   = cfg_addr_i;
          val_base_d   = 32'h0;
          col_idx_base_d = 32'h0;
          row_ptr_base_d = 32'h0;
          waddr_d      = operand_reg_i;
          instr_id_d   = instr_id_i;
          state_d = S_READ_CFG_VAL_BASE;
        end
      end

      S_READ_CFG_VAL_BASE: begin
        mem_need_read = 1'b1;
        mem_read_addr = cfg_addr_q;
        if (read_done) begin
          val_base_d = read_word;
          state_d = S_READ_CFG_COL_BASE;
        end
      end

      S_READ_CFG_COL_BASE: begin
        mem_need_read = 1'b1;
        mem_read_addr = cfg_addr_q + 32'd4;
        if (read_done) begin
          col_idx_base_d = read_word;
          state_d = S_READ_CFG_ROW_BASE;
        end
      end

      S_READ_CFG_ROW_BASE: begin
        mem_need_read = 1'b1;
        mem_read_addr = cfg_addr_q + 32'd8;
        if (read_done) begin
          row_ptr_base_d = read_word;
          state_d = S_FIND_ROW_NEXT;
        end
      end

      S_FIND_ROW_NEXT: begin
        if ((row_scan_q + 1) >= n_rows_i) begin
          r0_d = row_scan_q;
          state_d = S_READ_TILE_COL;
        end else begin
          mem_need_read = 1'b1;
          mem_read_addr = row_ptr_base_q + ((row_scan_q + 1) << 2);
          if (read_done) begin
            if (read_word <= nnz_offset_q) begin
              row_scan_d = row_scan_q + 1;
            end else begin
              r0_d = row_scan_q;
              state_d = S_READ_TILE_COL;
            end
          end
        end
      end

      S_READ_TILE_COL: begin
        mem_need_read = 1'b1;
        mem_read_addr = col_idx_base_q + (nnz_offset_q << 2);
        if (read_done) begin
          tile_col0_d = {read_word[31:2], 2'b00};
          tr_d = 3'b000;
          state_d = S_READ_ROW_START;
        end
      end

      S_READ_ROW_START: begin
        if (tr_q == 3'd4 || row_idx >= n_rows_i) begin
          wb_row_d = 3'b000;
          state_d = S_WRITE_ROWS;
        end else begin
          mem_need_read = 1'b1;
          mem_read_addr = row_ptr_base_q + (row_idx << 2);
          if (read_done) begin
            row_start_d = read_word;
            state_d = S_READ_ROW_END;
          end
        end
      end

      S_READ_ROW_END: begin
        mem_need_read = 1'b1;
        mem_read_addr = row_ptr_base_q + ((row_idx + 1) << 2);
        if (read_done) begin
          row_end_d = read_word;
          p_d = row_start_q;
          state_d = S_READ_COL;
        end
      end

      S_READ_COL: begin
        if (p_q >= row_end_q) begin
          tr_d = tr_q + 1;
          state_d = S_READ_ROW_START;
        end else begin
          mem_need_read = 1'b1;
          mem_read_addr = col_idx_base_q + (p_q << 2);
          if (read_done) begin
            if (read_word < tile_col0_q) begin
              p_d = p_q + 1;
            end else if (read_word >= (tile_col0_q + 4)) begin
              tr_d = tr_q + 1;
              state_d = S_READ_ROW_START;
            end else begin
              col_lane_d = read_word[1:0];
              state_d = S_READ_VAL;
            end
          end
        end
      end

      S_READ_VAL: begin
        mem_need_read = 1'b1;
        mem_read_addr = val_base_q + (p_q << 2);
        if (read_done) begin
          tile_d[tr_q][col_lane_q] = read_word;
          p_d = p_q + 1;
          state_d = S_READ_COL;
        end
      end

      S_WRITE_ROWS: begin
        if (wready_i) begin
          if (wb_row_q == 3'd3) begin
            state_d = S_FINISH;
          end else begin
            wb_row_d = wb_row_q + 1;
          end
        end
      end

      S_FINISH: begin
        active_d = 1'b0;
        state_d = S_IDLE;
      end

      default: begin
        state_d = S_IDLE;
        active_d = 1'b0;
      end
    endcase

    req_fire = mem_need_read && !wait_rvalid_q && data_gnt_i;
    if (req_fire) begin
      wait_rvalid_d = 1'b1;
      pending_addr_d = mem_read_addr;
    end

    if (read_done) begin
      wait_rvalid_d = 1'b0;
    end
  end

  always_comb begin
    we_o      = (state_q == S_WRITE_ROWS);
    wlast_o   = (state_q == S_WRITE_ROWS) && (wb_row_q == 3'd3);
    waddr_o   = waddr_q;
    wrowaddr_o= wb_row_q;
    wdata_o   = {tile_q[wb_row_q][3], tile_q[wb_row_q][2], tile_q[wb_row_q][1], tile_q[wb_row_q][0]};

    busy_o = active_q;
    lsu_id_o = instr_id_q;
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q <= S_IDLE;
      active_q <= 1'b0;
      wait_rvalid_q <= 1'b0;
      pending_addr_q <= '0;
      row_scan_q <= '0;
      r0_q <= '0;
      row_start_q <= '0;
      row_end_q <= '0;
      p_q <= '0;
      tr_q <= '0;
      col_lane_q <= '0;
      wb_row_q <= '0;
      nnz_offset_q <= '0;
      cfg_addr_q <= '0;
      val_base_q <= '0;
      col_idx_base_q <= '0;
      row_ptr_base_q <= '0;
      tile_col0_q <= '0;
      waddr_q <= '0;
      instr_id_q <= '0;
      for (rr = 0; rr < 4; rr++) begin
        for (cc = 0; cc < 4; cc++) begin
          tile_q[rr][cc] <= '0;
        end
      end
    end else begin
      state_q <= state_d;
      active_q <= active_d;
      wait_rvalid_q <= wait_rvalid_d;
      pending_addr_q <= pending_addr_d;
      row_scan_q <= row_scan_d;
      r0_q <= r0_d;
      row_start_q <= row_start_d;
      row_end_q <= row_end_d;
      p_q <= p_d;
      tr_q <= tr_d;
      col_lane_q <= col_lane_d;
      wb_row_q <= wb_row_d;
      nnz_offset_q <= nnz_offset_d;
      cfg_addr_q <= cfg_addr_d;
      val_base_q <= val_base_d;
      col_idx_base_q <= col_idx_base_d;
      row_ptr_base_q <= row_ptr_base_d;
      tile_col0_q <= tile_col0_d;
      waddr_q <= waddr_d;
      instr_id_q <= instr_id_d;
      for (rr = 0; rr < 4; rr++) begin
        for (cc = 0; cc < 4; cc++) begin
          tile_q[rr][cc] <= tile_d[rr][cc];
        end
      end
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      finished_o <= 1'b0;
      finished_instr_id_o <= '0;
    end else begin
      if (state_q == S_FINISH) begin
        finished_o <= 1'b1;
        finished_instr_id_o <= instr_id_q;
      end
      if (finished_ack_i) begin
        finished_o <= 1'b0;
        finished_instr_id_o <= '0;
      end
    end
  end

  if (BUS_WIDTH != 128) begin
    $error("[quadrilatero_csr_tile_loader] BUS_WIDTH must be 128 for 4x4 int32 tile writes.");
  end

endmodule
