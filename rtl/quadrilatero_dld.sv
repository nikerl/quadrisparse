// Copyright 2024 EPFL
// Solderpad Hardware License, Version 2.1, see LICENSE.md for details.
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// Author: Nik Erlandsson

module quadrilatero_dld #(
	parameter int unsigned BUS_WIDTH = 128,
	parameter int unsigned N_REGS    = 8,
	parameter int unsigned N_ROWS    = 4,
	localparam int unsigned RLEN     = BUS_WIDTH,
	localparam int unsigned EL_WIDTH = BUS_WIDTH / N_ROWS,
	localparam int unsigned SEL_ROW_IDX = 1
) (
	input  logic                          clk_i,
	input  logic                          rst_ni,

	// Bus interface
	output logic                          data_req_o,
	output logic [                  31:0] data_addr_o,
	output logic                          data_we_o,
	output logic [     BUS_WIDTH/8 - 1:0] data_be_o,
	output logic [         BUS_WIDTH-1:0] data_wdata_o,
	input  logic                          data_gnt_i,
	input  logic                          data_rvalid_i,
	input  logic [         BUS_WIDTH-1:0] data_rdata_i,

	output logic [xif_pkg::X_ID_WIDTH-1:0] lsu_id_o,

	// Register Write Port
	output logic [    $clog2(N_REGS)-1:0] waddr_o,
	output logic [    $clog2(N_ROWS)-1:0] wrowaddr_o,
	output logic [              RLEN-1:0] wdata_o,
	output logic                          we_o,
	output logic                          wlast_o,
	input  logic                          wready_i,

	// Register Read Port (for index row)
	output logic [    $clog2(N_REGS)-1:0] raddr_o,
	output logic [    $clog2(N_ROWS)-1:0] rrowaddr_o,
	input  logic [              RLEN-1:0] rdata_i,
	input  logic                          rdata_valid_i,
	output logic                          rdata_ready_o,
	output logic                          rlast_o,

	// Configuration
	input  logic                           start_i,
	output logic                           busy_o,
	input  logic [                   31:0] stride_i,
	input  logic [                   31:0] address_i,
	input  logic [     $clog2(N_REGS)-1:0] operand_reg_i,
	input  logic [     $clog2(N_REGS)-1:0] index_reg_i,
	input  logic [xif_pkg::X_ID_WIDTH-1:0] instr_id_i,
	input  logic [                   31:0] n_bytes_cols_i,
	input  logic [                   31:0] n_rows_i,

	output logic                           finished_o,
	input  logic                           finished_ack_i,
	output logic [xif_pkg::X_ID_WIDTH-1:0] finished_instr_id_o
);

	typedef enum logic [2:0] {
		IDLE,
		READ_INDEX_ROW,
		REQ_ROW,
		WAIT_ROW_DATA,
		WRITE_ROW
	} dld_state_e;

	dld_state_e state_q;
	dld_state_e state_d;

	logic [31:0] stride_q;
	logic [31:0] stride_d;
	logic [31:0] base_addr_q;
	logic [31:0] base_addr_d;
	logic [$clog2(N_REGS)-1:0] dst_reg_q;
	logic [$clog2(N_REGS)-1:0] dst_reg_d;
	logic [$clog2(N_REGS)-1:0] idx_reg_q;
	logic [$clog2(N_REGS)-1:0] idx_reg_d;
	logic [xif_pkg::X_ID_WIDTH-1:0] instr_id_q;
	logic [xif_pkg::X_ID_WIDTH-1:0] instr_id_d;
	logic [31:0] n_bytes_cols_q;
	logic [31:0] n_bytes_cols_d;

	logic [RLEN-1:0] idx_row_data_q;
	logic [RLEN-1:0] idx_row_data_d;
	logic [RLEN-1:0] row_data_q;
	logic [RLEN-1:0] row_data_d;

	logic [$clog2(N_ROWS)-1:0] row_cnt_q;
	logic [$clog2(N_ROWS)-1:0] row_cnt_d;

	logic [$clog2(N_ROWS+1)-1:0] rows_target_q;
	logic [$clog2(N_ROWS+1)-1:0] rows_target_d;

	logic [31:0] selected_row_idx;
	logic [31:0] selected_mem_addr;
	logic [31:0] first_selected_row_idx;
	logic [31:0] first_selected_mem_addr;
	logic [31:0] first_selected_row_idx_start;
	logic [31:0] first_selected_mem_addr_start;
	logic [$clog2(N_ROWS)-1:0] next_row_cnt;
	logic [31:0] next_selected_row_idx;
	logic [31:0] next_selected_mem_addr;
	logic [RLEN-1:0] data_mask;

	logic do_write;
	logic wait_direct_write;
	logic wait_direct_fire;
	logic finish_pulse;
	logic finished_q;
	logic finished_d;
	logic [xif_pkg::X_ID_WIDTH-1:0] finished_instr_id_q;
	logic [xif_pkg::X_ID_WIDTH-1:0] finished_instr_id_d;
	logic last_row;

	// Combinational logic for selecting the current row index and memory address based on the index row data
	always_comb begin
		selected_row_idx = idx_row_data_q[row_cnt_q*EL_WIDTH +: EL_WIDTH];
		selected_mem_addr = base_addr_q + selected_row_idx * stride_q;
		first_selected_row_idx = rdata_i[0*EL_WIDTH +: EL_WIDTH];
		first_selected_mem_addr = base_addr_q + first_selected_row_idx * stride_q;
		first_selected_row_idx_start = rdata_i[0*EL_WIDTH +: EL_WIDTH];
		first_selected_mem_addr_start = address_i + first_selected_row_idx_start * stride_i;
		next_row_cnt = row_cnt_q + 1'b1;
		next_selected_row_idx = idx_row_data_q[next_row_cnt*EL_WIDTH +: EL_WIDTH];
		next_selected_mem_addr = base_addr_q + next_selected_row_idx * stride_q;
	end

	always_comb begin
		data_mask = '1 << (8 * n_bytes_cols_q);
		wait_direct_write = (state_q == WAIT_ROW_DATA) && data_rvalid_i;
		wait_direct_fire  = wait_direct_write && wready_i;
		do_write  = (state_q == WRITE_ROW) || wait_direct_write;
		last_row  = (rows_target_q > 0) && (row_cnt_q == rows_target_q - 1);
		finish_pulse = do_write && wready_i && last_row;

		// OBI defaults
		data_req_o   = 1'b0;
		data_addr_o  = selected_mem_addr;
		data_we_o    = 1'b0;
		data_be_o    = '1;
		data_wdata_o = '0;

		if (state_q == REQ_ROW) begin
			data_req_o  = 1'b1;
		end

		// Overlap writeback of row N with request of row N+1 when possible.
		if ((state_q == WRITE_ROW) && do_write && wready_i && !last_row) begin
			data_req_o  = 1'b1;
			data_addr_o = next_selected_mem_addr;
		end

		if ((state_q == WAIT_ROW_DATA) && wait_direct_fire && !last_row) begin
			data_req_o  = 1'b1;
			data_addr_o = next_selected_mem_addr;
		end

		if ((state_q == READ_INDEX_ROW) && rdata_valid_i && rdata_ready_o && (rows_target_q != '0)) begin
			data_req_o  = 1'b1;
			data_addr_o = first_selected_mem_addr;
		end

		if ((state_q == IDLE) && start_i && rdata_valid_i && rdata_ready_o && (n_rows_i != '0)) begin
			data_req_o  = 1'b1;
			data_addr_o = first_selected_mem_addr_start;
		end

		// RF write port
		we_o      	= do_write;
		waddr_o   	= dst_reg_q;
		wrowaddr_o 	= row_cnt_q;
		if (wait_direct_write) wdata_o = data_rdata_i & ~data_mask;
		else wdata_o = row_data_q & ~data_mask;
		wlast_o   	= do_write && wready_i && last_row;

		// RF read port (for index row)
		raddr_o       = ((state_q == IDLE) && start_i) ? index_reg_i : idx_reg_q;
		rrowaddr_o    = $clog2(N_ROWS)'(SEL_ROW_IDX);
		rdata_ready_o = (state_q == READ_INDEX_ROW) || ((state_q == IDLE) && start_i);
		rlast_o       = rdata_ready_o && rdata_valid_i;

		lsu_id_o = ((state_q == IDLE) && start_i) ? instr_id_i : instr_id_q;
		busy_o   = (state_q != IDLE);

		finished_o = finished_q || finish_pulse;
		if (finish_pulse) finished_instr_id_o = instr_id_q;
		else finished_instr_id_o = finished_instr_id_q;
	end

	always_comb begin
		state_d        = state_q;
		stride_d       = stride_q;
		base_addr_d    = base_addr_q;
		dst_reg_d      = dst_reg_q;
		idx_reg_d      = idx_reg_q;
		instr_id_d     = instr_id_q;
		n_bytes_cols_d = n_bytes_cols_q;
		idx_row_data_d = idx_row_data_q;
		row_data_d     = row_data_q;
		row_cnt_d      = row_cnt_q;
		rows_target_d  = rows_target_q;
		finished_d = (finished_q || finish_pulse) && !finished_ack_i;
		if (finish_pulse) finished_instr_id_d = instr_id_q;
		else if (finished_ack_i) finished_instr_id_d = '0;
		else finished_instr_id_d = finished_instr_id_q;

		case (state_q)
			// Wait for start signal then latch configuration and start reading the index row
			IDLE: begin
			if (start_i) begin
				stride_d       = stride_i;
				base_addr_d    = address_i;
				dst_reg_d      = operand_reg_i;
				idx_reg_d      = index_reg_i;
				instr_id_d     = instr_id_i;
				n_bytes_cols_d = n_bytes_cols_i;
				idx_row_data_d = '0;
				row_data_d     = '0;
				row_cnt_d      = '0;

				if (n_rows_i < N_ROWS) rows_target_d = n_rows_i[$clog2(N_ROWS+1)-1:0];
				else rows_target_d = N_ROWS[$clog2(N_ROWS+1)-1:0];

				if (rdata_valid_i && rdata_ready_o) begin
					idx_row_data_d = rdata_i;
					if (rows_target_d == '0) state_d = IDLE;
					else if (data_gnt_i) state_d = WAIT_ROW_DATA;
					else state_d = REQ_ROW;
				end else begin
					state_d = READ_INDEX_ROW;
				end
			end
			end

			// Read selector row once, then release the whole scoreboard entry via rlast.
			READ_INDEX_ROW: begin
			if (rdata_valid_i && rdata_ready_o) begin
				idx_row_data_d = rdata_i;
				row_cnt_d = '0;
				if (rows_target_q == 0) state_d = IDLE;
				else if (data_gnt_i) state_d = WAIT_ROW_DATA;
				else state_d = REQ_ROW;
			end
			end

			// Wait for memory request to be granted
			REQ_ROW: begin
			if (data_req_o && data_gnt_i) begin
				state_d = WAIT_ROW_DATA;
			end
			end

			// Wait for the requested row data to be valid
			WAIT_ROW_DATA: begin
			if (data_rvalid_i) begin
				if (wready_i) begin
					if (last_row) begin
						state_d = IDLE;
					end else begin
						row_cnt_d = row_cnt_q + 1;
						if (data_gnt_i) state_d = WAIT_ROW_DATA;
						else state_d = REQ_ROW;
					end
				end else begin
					row_data_d = data_rdata_i;
					state_d = WRITE_ROW;
				end
			end
			end

			// Write the row data to the register file
			// then either go back to request the next row or finish if it was the last row
			WRITE_ROW: begin
			if (do_write && wready_i) begin
				if (last_row) begin
					state_d = IDLE;
				end else begin
					row_cnt_d = row_cnt_q + 1;
					if (data_gnt_i) state_d = WAIT_ROW_DATA;
					else state_d = REQ_ROW;
				end
			end
			end

			default: state_d = IDLE;
		endcase
	end

	always_ff @(posedge clk_i or negedge rst_ni) begin
		if (!rst_ni) begin
			state_q               <= IDLE;
			stride_q              <= '0;
			base_addr_q           <= '0;
			dst_reg_q             <= '0;
			idx_reg_q             <= '0;
			instr_id_q            <= '0;
			n_bytes_cols_q        <= '0;
			idx_row_data_q        <= '0;
			row_data_q            <= '0;
			row_cnt_q             <= '0;
			rows_target_q         <= '0;
			finished_q            <= 1'b0;
			finished_instr_id_q   <= '0;
		end else begin
			state_q               <= state_d;
			stride_q              <= stride_d;
			base_addr_q           <= base_addr_d;
			dst_reg_q             <= dst_reg_d;
			idx_reg_q             <= idx_reg_d;
			instr_id_q            <= instr_id_d;
			n_bytes_cols_q        <= n_bytes_cols_d;
			idx_row_data_q        <= idx_row_data_d;
			row_data_q            <= row_data_d;
			row_cnt_q             <= row_cnt_d;
			rows_target_q         <= rows_target_d;
			finished_q            <= finished_d;
			finished_instr_id_q   <= finished_instr_id_d;
		end
	end
endmodule
