// Copyright 2026
// Solderpad Hardware License, Version 2.1,see LICENSE.md for details.
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// Author: Nik Erlandsson
// Author: Oskar Swärd

`timescale 1ns/1ps

module quadrisparse_xif_tb;
	`include "quadrisparse_utils.svh";
	`include "quadrisparse_instructions.svh";

	import quadrilatero_pkg::*;
	import xif_pkg::*;

	localparam int CLK_PERIOD_NS 	= 10;

	string data_file_prefix;
	int dim;

	int N_ROWS;
	int N_COLS;
	int ROW_STRIDE;
	localparam logic [31:0] VAL_BASE      	= 32'h0001_0000;
	localparam logic [31:0] COL_BASE      	= 32'h0002_0000;
	localparam logic [31:0] B_BASE        	= 32'h0003_0000;
	localparam logic [31:0] C_BASE		  	= 32'h0004_0000;
	localparam logic [31:0] REF_BASE      	= 32'h0005_0000;

	localparam logic [31:0] MEM_MODEL_DEPTH = 32'h0001_0000;
	localparam int MAX_INSTRS 	= 4096;

	// Temporary storage for loading data files before packing into mem_model
	logic [31:0] tempmem [0:4096]; // Change size if needed
	int idx;
	int mem_fd;
	int scan_rc;
	logic [31:0] scan_word;
	int unsigned word_count;
	int unsigned b_rows;

	logic [31:0] row_ptrs []; // row pointers for the sparse matrix, loaded from file

	logic clk_i;
	logic rst_ni;

	logic						mem_req;
	logic						mem_we;
	logic [BUS_WIDTH/8-1:0]		mem_be;
	logic [31:0]				mem_addr;
	logic [BUS_WIDTH-1:0]		mem_wdata;
	logic						mem_gnt;
	logic						mem_rvalid;
	logic [BUS_WIDTH-1:0]		mem_rdata;

	logic				x_compressed_valid;
	logic				x_compressed_ready;
	x_compressed_req_t	x_compressed_req;
	x_compressed_resp_t	x_compressed_resp;

	logic				x_issue_valid;
	logic				x_issue_ready;
	x_issue_req_t		x_issue_req;
	x_issue_resp_t		x_issue_resp;

	logic				x_commit_valid;
	x_commit_t			x_commit;

	logic				x_mem_valid;
	logic				x_mem_ready;
	x_mem_req_t			x_mem_req;
	x_mem_resp_t		x_mem_resp;

	logic				x_mem_result_valid;
	x_mem_result_t		x_mem_result;

	logic				x_result_valid;
	logic				x_result_ready;
	x_result_t			x_result;

	logic [127:0]		mem_model [0:MEM_MODEL_DEPTH-1];
	logic				read_pending_q;
	logic [31:0]		read_addr_q;

	int unsigned completed_results;
	int issued_cnt;
	logic [3:0] next_id;

	longint unsigned cycle_count = 0;

	typedef struct {
		longint unsigned issue_cycle;
		longint unsigned complete_cycle;
		string           name;
		logic [3:0]      xif_id;
	} instr_log_t;

	instr_log_t instr_log [0:MAX_INSTRS-1];
	int         log_issue_ptr             = 0;
	int         id_to_log_idx [0:15];


	// Clock generation and cycle counting
	initial begin
		clk_i = 1'b0;
		forever #(CLK_PERIOD_NS/2) clk_i = ~clk_i;
	end

	always @(posedge clk_i) begin
		cycle_count <= cycle_count + 1;
	end

	// Simple memory model: one-cycle read response, immediate write acceptance.
	assign mem_gnt = 1'b1;

	always_ff @(posedge clk_i or negedge rst_ni) begin
		if (!rst_ni) begin
			read_pending_q <= 1'b0;
			read_addr_q    <= '0;
			mem_rvalid     <= 1'b0;
			mem_rdata      <= '0;
		end else begin
			mem_rvalid <= 1'b0;

			if (read_pending_q) begin
				if (mem_row_idx(read_addr_q) >= MEM_MODEL_DEPTH) begin
					$fatal(1, "[TB] READ OOB: addr=0x%08x row=%0d depth=%0d", read_addr_q, mem_row_idx(read_addr_q), MEM_MODEL_DEPTH);
				end
				mem_rvalid <= 1'b1;
				mem_rdata  <= mem_model[read_addr_q[31:4]];
			end

			read_pending_q <= 1'b0;
			if (mem_req && mem_gnt && !mem_we) begin
				read_pending_q <= 1'b1;
				read_addr_q    <= mem_addr;
			end

			if (mem_req && mem_gnt && mem_we) begin
				if (mem_row_idx(mem_addr) >= MEM_MODEL_DEPTH) begin
					$fatal(1, "[TB] WRITE OOB: addr=0x%08x row=%0d depth=%0d", mem_addr, mem_row_idx(mem_addr), MEM_MODEL_DEPTH);
				end
				for (int b = 0; b < BUS_WIDTH/8; b++) begin
					if (mem_be[b]) begin
						mem_model[mem_addr[31:4]][8*b +: 8] <= mem_wdata[8*b +: 8];
					end
				end
			end
		end
	end

	always_ff @(posedge clk_i or negedge rst_ni) begin
		if (!rst_ni) begin
			completed_results <= 0;
		end else if (x_result_valid && x_result_ready) begin
			completed_results <= completed_results + 1;
			instr_log[id_to_log_idx[x_result.id]].complete_cycle = cycle_count;
			$display("[TB] COMPLETE %-10s id=%0d log=%0d (cycle %0d, latency=%0d)",
				instr_log[id_to_log_idx[x_result.id]].name,
				x_result.id,
				id_to_log_idx[x_result.id],
				cycle_count,
				cycle_count - instr_log[id_to_log_idx[x_result.id]].issue_cycle);
		end
	end

	always @(posedge clk_i) begin
		if (x_issue_valid && x_issue_ready) begin
			instr_log[log_issue_ptr].issue_cycle    = cycle_count;
			instr_log[log_issue_ptr].complete_cycle = '1;
			instr_log[log_issue_ptr].xif_id         = x_issue_req.id;
			id_to_log_idx[x_issue_req.id]           = log_issue_ptr;

			casez (x_issue_req.instr)
				quadrilatero_instr_pkg::SPLD_W  : instr_log[log_issue_ptr].name = "SPLD_W";
				quadrilatero_instr_pkg::DLD_W   : instr_log[log_issue_ptr].name = "DLD_W";
				quadrilatero_instr_pkg::MLD_W   : instr_log[log_issue_ptr].name = "MLD_W";
				quadrilatero_instr_pkg::SPMAC_W : instr_log[log_issue_ptr].name = "SPMAC_W";
				quadrilatero_instr_pkg::MMASA_W : instr_log[log_issue_ptr].name = "MMASA_W";
				quadrilatero_instr_pkg::MZERO   : instr_log[log_issue_ptr].name = "MZERO";
				quadrilatero_instr_pkg::MST_W   : instr_log[log_issue_ptr].name = "MST_W";
				quadrilatero_instr_pkg::MST_B   : instr_log[log_issue_ptr].name = "MST_B";
				quadrilatero_instr_pkg::MST_H   : instr_log[log_issue_ptr].name = "MST_H";
				default                         : instr_log[log_issue_ptr].name = "UNKNOWN";
			endcase

			$display("[TB] ISSUE    %-10s id=%0d log=%0d (cycle %0d)",
				instr_log[log_issue_ptr].name, x_issue_req.id, log_issue_ptr, cycle_count);

			log_issue_ptr = log_issue_ptr + 1;
		end
	end

	quadrilatero #(
		.FPU(0)
	) dut (
		.clk_i,
		.rst_ni,

		.mem_req_o    (mem_req),
		.mem_we_o     (mem_we),
		.mem_be_o     (mem_be),
		.mem_addr_o   (mem_addr),
		.mem_wdata_o  (mem_wdata),
		.mem_gnt_i    (mem_gnt),
		.mem_rvalid_i (mem_rvalid),
		.mem_rdata_i  (mem_rdata),

		.x_compressed_valid_i (x_compressed_valid),
		.x_compressed_ready_o (x_compressed_ready),
		.x_compressed_req_i   (x_compressed_req),
		.x_compressed_resp_o  (x_compressed_resp),

		.x_issue_valid_i (x_issue_valid),
		.x_issue_ready_o (x_issue_ready),
		.x_issue_req_i   (x_issue_req),
		.x_issue_resp_o  (x_issue_resp),

		.x_commit_valid_i (x_commit_valid),
		.x_commit_i       (x_commit),

		.x_mem_valid_o        (x_mem_valid),
		.x_mem_ready_i        (x_mem_ready),
		.x_mem_req_o          (x_mem_req),
		.x_mem_resp_i         (x_mem_resp),
		.x_mem_result_valid_i (x_mem_result_valid),
		.x_mem_result_i       (x_mem_result),

		.x_result_valid_o (x_result_valid),
		.x_result_ready_i (x_result_ready),
		.x_result_o       (x_result)
	);

	initial begin
		// ── local working variables ──────────────────────────────────
		logic signed [31:0] got_val, exp_val;
		int errors;
		int val_ptr;
		int nnz_to_load;
		int elem_idx;
		int chunk_limit;
		logic [2:0] acc_reg;

		// ── defaults ─────────────────────────────────────────────────
		rst_ni              = 1'b0;
		x_compressed_valid  = 1'b0;
		x_compressed_req    = '0;
		x_issue_valid       = 1'b0;
		x_issue_req         = '0;
		x_commit_valid      = 1'b0;
		x_commit            = '0;
		x_mem_ready         = 1'b1;
		x_mem_resp          = '0;
		x_mem_result_valid  = 1'b0;
		x_mem_result        = '0;
		x_result_ready      = 1'b1;
		acc_reg             = 3'd4;

		if (!$value$plusargs("data_file_prefix=%s", data_file_prefix)) begin
			$fatal(1, "data file prefix argument not provided");
		end
		if (!$value$plusargs("dim=%0d", dim)) begin
			$fatal(1, "dimension argument not provided");
		end
		if (dim <= 0) begin
			$fatal(1, "dimension must be positive, got %0d", dim);
		end
		if ((dim % 4) != 0) begin
			$fatal(1, "dimension must be divisible by 4, got %0d", dim);
		end

		N_ROWS = dim;
		N_COLS = dim;
		ROW_STRIDE = N_COLS * 4;
		row_ptrs = new[N_ROWS + 1];

		for (int i = 0; i < $size(mem_model); i++) mem_model[i] = '0;
		for (int i = 0; i < 16;  i++) id_to_log_idx[i] = 0;

		//===========================================================================
		// Load matricies from data files
		//===========================================================================

		// Sparse A column indices: with K=NNZ_PER_ROW every row is dense (cols 0..K-1)
		load_data_into_mem(VAL_BASE, {data_file_prefix, "_a_val.hex"});
		load_data_into_mem(COL_BASE, {data_file_prefix, "_a_col.hex"});
		load_row_ptr({data_file_prefix, "_a_row.hex"});

		// Dense matrix B, row-major.
		load_data_into_mem(B_BASE, {data_file_prefix, "_b.hex"});

		// result matrix for reference
		load_data_into_mem(REF_BASE, {data_file_prefix, "_ref.hex"});


		//===========================================================================
		// Reset
		//===========================================================================

		repeat (6) @(posedge clk_i);
		rst_ni = 1'b1;
		repeat (4) @(posedge clk_i);

		//===========================================================================
		// Instruction sequence
		//===========================================================================

		issued_cnt    = 0;
		next_id       = 32'd0;
		val_ptr       = 0;

		// For each row with in the row_ptr array
		for (int row_idx = 0; row_idx < $size(row_ptrs) - 1; row_idx++) begin
			// For each tile on this row in the dense matrix 
			for (int col_tiles = 0; col_tiles < N_COLS / 4; col_tiles++) begin
				// Reset the accumulator register for this output tile.
				issue_and_commit(enc_mzero(acc_reg), 32'd0, 32'd0, next_id); next_id++; issued_cnt++;

				// Rewind sparse pointer to the start of this row for each output tile.
				val_ptr = row_ptrs[row_idx];

				// for each non zero in that row 
				while (val_ptr < row_ptrs[row_idx+1]) begin
					nnz_to_load = row_ptrs[row_idx+1] - val_ptr;
					
					chunk_limit = 4 - (val_ptr & 2'b11);
					if (nnz_to_load > chunk_limit) nnz_to_load = chunk_limit;
					if (nnz_to_load > 4) nnz_to_load = 4;
					issue_and_commit(enc_spld_w(3'd0, 3'(nnz_to_load)), VAL_BASE + val_ptr * 4, COL_BASE + val_ptr * 4, next_id); next_id++; issued_cnt++;
					val_ptr = val_ptr + nnz_to_load;
					wait (completed_results >= issued_cnt); repeat (2) @(posedge clk_i);

					// load dense tile
					issue_and_commit(enc_dld_w(3'd1, 3'd0), B_BASE + 32'(col_tiles * 16), ROW_STRIDE, next_id); next_id++; issued_cnt++;
					//wait (completed_results >= issued_cnt); repeat (2) @(posedge clk_i);

					// do multiplication
					issue_and_commit(enc_spmac_w(3'd0, 3'd1, acc_reg), 32'd0, 32'd0, next_id); next_id++; issued_cnt++;
					wait (completed_results >= issued_cnt); repeat (2) @(posedge clk_i);
				
				end
				// write back the result
				issue_and_commit(enc_mst_w(acc_reg), C_BASE + 32'(row_idx * (N_COLS * 4) + col_tiles * 16), ROW_STRIDE, next_id);
				next_id++; issued_cnt++;
				//wait (completed_results >= issued_cnt); repeat (2) @(posedge clk_i);

			end
		end


		repeat (10) @(posedge clk_i);

		$display("\n[TIMING] %0d instructions", log_issue_ptr);
		$display("[TIMING] idx   name        xif_id  issue   complete  latency");
		for (int i = 0; i < log_issue_ptr; i++) begin
			$display("[TIMING] %4d  %-10s  %2d      %6d  %8d  %6d",
				i,
				instr_log[i].name,
				instr_log[i].xif_id,
				instr_log[i].issue_cycle,
				instr_log[i].complete_cycle,
				instr_log[i].complete_cycle - instr_log[i].issue_cycle);
		end

		//===========================================================================
		// Compare result matrix at C_BASE against reference matrix at REF_BASE
		//===========================================================================

		errors = 0;
		for (int i = 0; i < N_ROWS; i++) begin
			for (int j = 0; j < N_COLS; j++) begin
				elem_idx = i * N_COLS + j;
				got_val = $signed(mem_model[(C_BASE + elem_idx * 4) >> 4][(((C_BASE + elem_idx * 4) >> 2) & 2'b11) * 32 +: 32]);
				exp_val = $signed(mem_model[(REF_BASE + elem_idx * 4) >> 4][(((REF_BASE + elem_idx * 4) >> 2) & 2'b11) * 32 +: 32]);
				if ($isunknown(got_val) || $isunknown(exp_val)) begin
					$display("[ERROR] Unknown data at C[%0d][%0d] @0x%08x: GOT=%0h  REF=%0h",
						i, j, (C_BASE + elem_idx * 4), got_val, exp_val);
					errors++;
				end else if (got_val !== exp_val) begin
					$display("[ERROR] C[%0d][%0d] @0x%08x: GOT=%0d  REF=%0d",
						i, j, (C_BASE + elem_idx * 4), got_val, exp_val);
					errors++;
				end
			end
		end

		if (errors == 0) begin
			$display("\n[TB] PASS -- all %0d elements matched REF_BASE.", N_ROWS * N_COLS);
		end else begin
			$display("\n[TB] FAIL -- %0d mismatches.", errors);
		end

		print_matrix(C_BASE, N_ROWS, N_COLS);

		$finish;
	end

	initial begin
		#50000000ns;
		$fatal(1, "[TB] Timeout waiting for matrix multiplication flow.");
	end

endmodule
