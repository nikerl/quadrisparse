// Copyright 2024 EPFL
// Solderpad Hardware License, Version 2.1, see LICENSE.md for details.
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// Author: Danilo Cammarata

/*

TODO:
- handle matrices operations with matrices < MESH_WIDTH based on the configuration CSRs
    - basically you need to inject zeros instead of actual elements
*/

module quadrilatero_systolic_array #(
    parameter  int MESH_WIDTH  = 4                      ,
    parameter  int DATA_WIDTH  = 32                     ,
    parameter  int N_REGS      = 8                      ,
    parameter  int ENABLE_SIMD = 1                      ,
    localparam int N_ROWS      = MESH_WIDTH             ,
    localparam int RLEN        = DATA_WIDTH * MESH_WIDTH,
    parameter FPU = 1
) (
    input  logic                           clk_i               ,
    input  logic                           rst_ni              ,

    output logic                           sa_ready_o          ,
    input  logic                           start_i             ,

    // Only has effect if ENABLE_SIMD == 1
    input  quadrilatero_pkg::sa_ctrl_t       sa_ctrl_i           ,

    input  logic [     $clog2(N_REGS)-1:0] data_reg_i          ,  // data register
    input  logic [     $clog2(N_REGS)-1:0] acc_reg_i           ,  // accumulator register
    input  logic [     $clog2(N_REGS)-1:0] weight_reg_i        ,  // weight register
    input  logic [xif_pkg::X_ID_WIDTH-1:0] id_i                ,  // id of the instruction

    // Weight Read Register Port
    output logic [     $clog2(N_REGS)-1:0] weight_raddr_o      ,
    output logic [     $clog2(N_ROWS)-1:0] weight_rrowaddr_o   ,
    input  logic [               RLEN-1:0] weight_rdata_i      ,
    input  logic                           weight_rdata_valid_i,
    output logic                           weight_rdata_ready_o,
    output logic                           weight_rlast_o      ,

    // Data Read Register Port
    output logic [     $clog2(N_REGS)-1:0] data_raddr_o        ,
    output logic [     $clog2(N_ROWS)-1:0] data_rrowaddr_o     ,
    input  logic [               RLEN-1:0] data_rdata_i        ,
    input  logic                           data_rdata_valid_i  ,
    output logic                           data_rdata_ready_o  ,
    output logic                           data_rlast_o        ,

    // Accumulator Read Register Port
    output logic [     $clog2(N_REGS)-1:0] acc_raddr_o         ,
    output logic [     $clog2(N_ROWS)-1:0] acc_rrowaddr_o      ,
    input  logic [               RLEN-1:0] acc_rdata_i         ,
    input  logic                           acc_rdata_valid_i   ,
    output logic                           acc_rdata_ready_o   ,
    output logic                           acc_rlast_o         ,

    // Accumulator Out Write Register Port
    output logic [     $clog2(N_REGS)-1:0] res_waddr_o         ,
    output logic [     $clog2(N_ROWS)-1:0] res_wrowaddr_o      ,
    output logic [               RLEN-1:0] res_wdata_o         ,
    output logic                           res_we_o            ,
    output logic                           res_wlast_o         ,
    input  logic                           res_wready_i        ,

    // RF Instruction ID
    output logic [xif_pkg::X_ID_WIDTH-1:0] sa_input_id_o       ,
    output logic [xif_pkg::X_ID_WIDTH-1:0] sa_output_id_o      ,

    // Finish
    output logic                           finished_o          ,
    input  logic                           finished_ack_i      ,
    output logic [xif_pkg::X_ID_WIDTH-1:0] finished_instr_id_o
);

  localparam int CNT_W = (MESH_WIDTH > 1) ? $clog2(MESH_WIDTH + 1) : 1;
  typedef enum logic [1:0] {
    ST_IDLE,
    ST_LOAD,
    ST_WRITE
  } sa_state_t;

  sa_state_t state_d;
  sa_state_t state_q;

  logic [CNT_W-1:0] load_cnt_d;
  logic [CNT_W-1:0] load_cnt_q;
  logic [CNT_W-1:0] write_cnt_d;
  logic [CNT_W-1:0] write_cnt_q;

  logic [$clog2(N_REGS)-1:0] data_reg_d;
  logic [$clog2(N_REGS)-1:0] data_reg_q;
  logic [$clog2(N_REGS)-1:0] acc_reg_d;
  logic [$clog2(N_REGS)-1:0] acc_reg_q;
  logic [$clog2(N_REGS)-1:0] weight_reg_d;
  logic [$clog2(N_REGS)-1:0] weight_reg_q;
  logic [$clog2(N_REGS)-1:0] dest_reg_d;
  logic [$clog2(N_REGS)-1:0] dest_reg_q;

  logic [xif_pkg::X_ID_WIDTH-1:0] id_d;
  logic [xif_pkg::X_ID_WIDTH-1:0] id_q;
  quadrilatero_pkg::sa_ctrl_t       sa_ctrl_d;
  quadrilatero_pkg::sa_ctrl_t       sa_ctrl_q;

  logic                           finished_d;
  logic                           finished_q;
  logic [xif_pkg::X_ID_WIDTH-1:0] finished_instr_id_d;
  logic [xif_pkg::X_ID_WIDTH-1:0] finished_instr_id_q;

  logic [MESH_WIDTH-1:0][MESH_WIDTH-1:0][DATA_WIDTH-1:0] weight_matrix_d;
  logic [MESH_WIDTH-1:0][MESH_WIDTH-1:0][DATA_WIDTH-1:0] weight_matrix_q;
  logic [MESH_WIDTH-1:0][MESH_WIDTH-1:0][DATA_WIDTH-1:0] acc_matrix_d;
  logic [MESH_WIDTH-1:0][MESH_WIDTH-1:0][DATA_WIDTH-1:0] acc_matrix_q;
  logic [MESH_WIDTH-1:0][DATA_WIDTH-1:0]                 a_row_d;
  logic [MESH_WIDTH-1:0][DATA_WIDTH-1:0]                 a_row_q;

  logic [MESH_WIDTH-1:0][MESH_WIDTH-1:0][DATA_WIDTH-1:0] reduce_partial;
  logic [MESH_WIDTH-1:0][DATA_WIDTH-1:0]                 reduced_bottom;

  logic [DATA_WIDTH-1:0] row_write_data [MESH_WIDTH-1:0];

  logic load_handshake;
  logic write_handshake;

  assign load_handshake   = (state_q == ST_LOAD) && weight_rdata_ready_o &&
                            weight_rdata_valid_i && data_rdata_valid_i && acc_rdata_valid_i;
  assign write_handshake  = (state_q == ST_WRITE) && res_we_o             && res_wready_i;

  // Integer downward reduction network:
  // A[row] is broadcast on each row and multiplied by statically mapped B[row][col].
  genvar i, j;
  generate
    for (i = 0; i < MESH_WIDTH; i++) begin : gen_reduce_rows
      for (j = 0; j < MESH_WIDTH; j++) begin : gen_reduce_cols
        quadrilatero_mac_int #(
            .ENABLE_SIMD(ENABLE_SIMD)
        ) reduce_mac_i (
            .weight_i      (weight_matrix_q[i][j]),
            .data_i        (a_row_q[i]),
            .acc_i         ((i == 0) ? '0 : reduce_partial[i-1][j]),
            .op_datatype_i (sa_ctrl_q.datatype),
            .acc_o         (reduce_partial[i][j]),
            .mac_finished_o()
        );
      end
    end
  endgenerate

  always_comb begin: reduction_block
    for (int col = 0; col < MESH_WIDTH; col++) begin
      if (sa_ctrl_q.is_float) begin
        reduced_bottom[col] = acc_matrix_q[MESH_WIDTH-1][col];
      end else begin
        reduced_bottom[col] = reduce_partial[MESH_WIDTH-1][col] + acc_matrix_q[MESH_WIDTH-1][col];
      end
    end
  end

  always_comb begin: rf_block
    logic [$clog2(N_ROWS)-1:0] weight_row;
    logic [$clog2(N_ROWS)-1:0] data_row;
    logic [$clog2(N_ROWS)-1:0] acc_row;
    logic [$clog2(N_ROWS)-1:0] write_row;

    weight_row = (load_cnt_q >= CNT_W'(MESH_WIDTH)) ? $clog2(N_ROWS)'(MESH_WIDTH-1)
                             : load_cnt_q[$clog2(N_ROWS)-1:0];
    data_row   = weight_row;
    acc_row    = weight_row;
    write_row  = (write_cnt_q  >= CNT_W'(MESH_WIDTH)) ? $clog2(N_ROWS)'(MESH_WIDTH-1)
                                                       : write_cnt_q[$clog2(N_ROWS)-1:0];

    weight_raddr_o       = weight_reg_q;
    weight_rrowaddr_o    = weight_row;
    weight_rdata_ready_o = (state_q == ST_LOAD) && (load_cnt_q < CNT_W'(MESH_WIDTH));
    weight_rlast_o       = (load_cnt_q == CNT_W'(MESH_WIDTH-1));

    data_raddr_o         = data_reg_q;
    data_rrowaddr_o      = data_row;
    data_rdata_ready_o   = (state_q == ST_LOAD) && (load_cnt_q < CNT_W'(MESH_WIDTH));
    data_rlast_o         = (load_cnt_q == CNT_W'(MESH_WIDTH-1));

    acc_raddr_o          = acc_reg_q;
    acc_rrowaddr_o       = acc_row;
    acc_rdata_ready_o    = (state_q == ST_LOAD) && (load_cnt_q < CNT_W'(MESH_WIDTH));
    acc_rlast_o          = (load_cnt_q == CNT_W'(MESH_WIDTH-1));

    res_waddr_o          = dest_reg_q;
    res_wrowaddr_o       = write_row;
    res_we_o             = (state_q == ST_WRITE) && (write_cnt_q < CNT_W'(MESH_WIDTH));
    res_wlast_o          = (write_cnt_q == CNT_W'(MESH_WIDTH-1));

    for (int col = 0; col < MESH_WIDTH; col++) begin
      row_write_data[col] = (write_row == $clog2(N_ROWS)'(MESH_WIDTH-1))
          ? reduced_bottom[col]
          : acc_matrix_q[write_row][col];
      res_wdata_o[DATA_WIDTH*col +: DATA_WIDTH] = row_write_data[col];
    end
  end

  always_comb begin: next_value
    state_d             = state_q;

    load_cnt_d          = load_cnt_q;
    write_cnt_d         = write_cnt_q;

    data_reg_d          = data_reg_q;
    acc_reg_d           = acc_reg_q;
    weight_reg_d        = weight_reg_q;
    dest_reg_d          = dest_reg_q;
    id_d                = id_q;
    sa_ctrl_d           = sa_ctrl_q;

    weight_matrix_d     = weight_matrix_q;
    acc_matrix_d        = acc_matrix_q;
    a_row_d             = a_row_q;

    finished_d          = finished_q;
    finished_instr_id_d = finished_instr_id_q;

    if (finished_ack_i) begin
      finished_d          = 1'b0;
      finished_instr_id_d = '0;
    end

    case (state_q)
      ST_IDLE: begin
        load_cnt_d   = '0;
        write_cnt_d  = '0;

        if (start_i && !finished_q) begin
          state_d      = ST_LOAD;
          data_reg_d   = data_reg_i;
          acc_reg_d    = acc_reg_i;
          weight_reg_d = weight_reg_i;
          dest_reg_d   = acc_reg_i;
          id_d         = id_i;
          sa_ctrl_d    = sa_ctrl_i;
          a_row_d      = '0;
        end
      end

      ST_LOAD: begin
        if (load_handshake) begin
          for (int col = 0; col < MESH_WIDTH; col++) begin
            weight_matrix_d[load_cnt_q][col] = weight_rdata_i[DATA_WIDTH*col +: DATA_WIDTH];
          end
          if (load_cnt_q == '0) begin
            for (int col = 0; col < MESH_WIDTH; col++) begin
              a_row_d[col] = data_rdata_i[DATA_WIDTH*col +: DATA_WIDTH];
            end
          end
          for (int col = 0; col < MESH_WIDTH; col++) begin
            acc_matrix_d[load_cnt_q][col] = acc_rdata_i[DATA_WIDTH*col +: DATA_WIDTH];
          end
          load_cnt_d = load_cnt_q + CNT_W'(1);
        end

        if (load_cnt_q == CNT_W'(MESH_WIDTH)) begin
          state_d    = ST_WRITE;
          write_cnt_d = '0;
        end
      end

      ST_WRITE: begin
        if (write_handshake) begin
          if (write_cnt_q == CNT_W'(MESH_WIDTH-1)) begin
            state_d             = ST_IDLE;
            write_cnt_d         = '0;
            finished_d          = 1'b1;
            finished_instr_id_d = id_q;
          end else begin
            write_cnt_d = write_cnt_q + CNT_W'(1);
          end
        end
      end

      default: state_d = ST_IDLE;
    endcase
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin: seq_block
    if (!rst_ni) begin
      state_q             <= ST_IDLE;
      load_cnt_q          <= '0;
      write_cnt_q         <= '0;
      data_reg_q          <= '0;
      acc_reg_q           <= '0;
      weight_reg_q        <= '0;
      dest_reg_q          <= '0;
      id_q                <= '0;
      sa_ctrl_q           <= '0;
      weight_matrix_q     <= '0;
      acc_matrix_q        <= '0;
      a_row_q             <= '0;
      finished_q          <= '0;
      finished_instr_id_q <= '0;
    end else begin
      state_q             <= state_d;
      load_cnt_q          <= load_cnt_d;
      write_cnt_q         <= write_cnt_d;
      data_reg_q          <= data_reg_d;
      acc_reg_q           <= acc_reg_d;
      weight_reg_q        <= weight_reg_d;
      dest_reg_q          <= dest_reg_d;
      id_q                <= id_d;
      sa_ctrl_q           <= sa_ctrl_d;
      weight_matrix_q     <= weight_matrix_d;
      acc_matrix_q        <= acc_matrix_d;
      a_row_q             <= a_row_d;
      finished_q          <= finished_d;
      finished_instr_id_q <= finished_instr_id_d;
    end
  end

  assign sa_ready_o          = (state_q == ST_IDLE) & ~finished_q;
  assign sa_input_id_o       = id_q;
  assign sa_output_id_o      = id_q;
  assign finished_o          = finished_q;
  assign finished_instr_id_o = finished_instr_id_q;

  // --------------------------------------------------------------------

  // Assertions
  if (MESH_WIDTH < 2) begin
    $error(
        "[systolic_array] MESH_WIDTH must be at least 2.\n"
    );
  end

  if (DATA_WIDTH != 32) begin
    $error(
        "[systolic_array] This implementation currently supports DATA_WIDTH == 32.\n"
    );
  end

endmodule