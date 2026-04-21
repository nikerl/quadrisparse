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
	int size;

	int N_ROWS;
	int N_COLS;
	int ROW_STRIDE;
	// 2MB slots per buffer avoid overlap for SIZE=512 (1MB matrices) and sparse tail writes.
	localparam logic [31:0] VAL_BASE      	= 32'h0000_0000;
	localparam logic [31:0] COL_BASE      	= 32'h0020_0000;
	localparam logic [31:0] A_BASE        	= 32'h0040_0000;
	localparam logic [31:0] B_BASE        	= 32'h0060_0000;
	localparam logic [31:0] C_BASE		  	= 32'h0080_0000;
	localparam logic [31:0] REF_BASE      	= 32'h00A0_0000;
	localparam logic [31:0] BT_BASE       	= 32'h00C0_0000;

	localparam logic [31:0] MEM_MODEL_DEPTH = 32'h0010_0000;
	localparam int MAX_INSTRS 	= MEM_MODEL_DEPTH;

	int M_PAD;
	int N_PAD;
	int K_PAD;

	// Temporary storage for loading data files before packing into mem_model
	logic [31:0] tempmem [0:MEM_MODEL_DEPTH-1]; // Change size if needed
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
			// Print completed instructions
			/* $display("[TB] COMPLETE %-10s id=%0d log=%0d (cycle %0d, latency=%0d)",
				instr_log[id_to_log_idx[x_result.id]].name,
				x_result.id,
				id_to_log_idx[x_result.id],
				cycle_count,
				cycle_count - instr_log[id_to_log_idx[x_result.id]].issue_cycle); */
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

			// Print issued instructions
			/* $display("[TB] ISSUE    %-10s id=%0d log=%0d (cycle %0d)",
				instr_log[log_issue_ptr].name, x_issue_req.id, log_issue_ptr, cycle_count); */

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
		string mode;
		bit run_sparse;
		bit run_dense;
		int nnz_to_load;
		int elem_idx;
		int chunk_limit;
		int col_tile_start;
		int tiles_in_group;
		int tile;
		int col_tile_idx;
		logic [2:0] acc_regs [0:3];
		logic [2:0] dense_regs [0:1];
		logic [3:0] dld_ids [0:3];
		logic [3:0] spmac_ids [0:3];

		logic [31:0] a0, a4, b0, b4;                        // tile base addresses
		logic [31:0] c00, c01, c10, c11;                    // C store addresses

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
		acc_regs[0]         = 3'd4;
		acc_regs[1]         = 3'd5;
		acc_regs[2]         = 3'd6;
		acc_regs[3]         = 3'd7;
		dense_regs[0]    = 3'd1;
		dense_regs[1]    = 3'd2;

		if (!$value$plusargs("data_file_prefix=%s", data_file_prefix)) begin
			$fatal(1, "data file prefix argument not provided");
		end
		if (!$value$plusargs("size=%0d", size)) begin
			$fatal(1, "size argument not provided");
		end
		if (size <= 0) begin
			$fatal(1, "size must be positive, got %0d", size);
		end
		if ((size % 4) != 0) begin
			$fatal(1, "size must be divisible by 4, got %0d", size);
		end

		if (!$value$plusargs("mode=%s", mode)) begin
			mode = "sparse";
		end
		run_sparse = (mode == "sparse") || (mode == "both");
		run_dense  = (mode == "dense")  || (mode == "both");
		if (!run_sparse && !run_dense) begin
			$fatal(1, "Unsupported mode='%s' (use dense|sparse|both)", mode);
		end

		N_ROWS = size;
		N_COLS = size;
		ROW_STRIDE = N_COLS * 4;
		row_ptrs = new[N_ROWS + 1];

		M_PAD = ((size + 7) / 8) * 8;
		N_PAD = ((size + 7) / 8) * 8;
		K_PAD = ((size + 3) / 4) * 4;

		for (int i = 0; i < $size(mem_model); i++) mem_model[i] = '0;
		for (int i = 0; i < 16;  i++) id_to_log_idx[i] = 0;

		//===========================================================================
		// Load matricies from data files
		//===========================================================================

		// Sparse A column indices: with K=NNZ_PER_ROW every row is dense (cols 0..K-1)
		load_data_into_mem(A_BASE, {data_file_prefix, "_a.hex"});
		load_data_into_mem(VAL_BASE, {data_file_prefix, "_a_val.hex"});
		load_data_into_mem(COL_BASE, {data_file_prefix, "_a_col.hex"});
		load_row_ptr({data_file_prefix, "_a_row.hex"});

		// Dense matrix B, row-major.
		load_data_into_mem(B_BASE, {data_file_prefix, "_b.hex"});

		// MMASA dense path expects B tiles in transposed layout at BT_BASE.
		for (int i = 0; i < N_ROWS; i++) begin
			for (int j = 0; j < N_COLS; j++) begin
				logic [31:0] src_addr;
				logic [31:0] dst_addr;
				src_addr = B_BASE + ((i * N_COLS + j) * 4);
				dst_addr = BT_BASE + ((j * N_ROWS + i) * 4);
				mem_model[dst_addr >> 4][(((dst_addr >> 2) & 2'b11) * 32) +: 32] =
					mem_model[src_addr >> 4][(((src_addr >> 2) & 2'b11) * 32) +: 32];
			end
		end

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

		// Gustavson-style schedule (tile-stationary over a small tile group):
		// row -> tile-group -> sparse chunks, reusing each sparse chunk across 4 output tiles.
		if (run_sparse) begin
		for (int row_idx = 0; row_idx < $size(row_ptrs) - 1; row_idx++) begin
			// Skip enptry rows
			if (row_ptrs[row_idx] == row_ptrs[row_idx + 1]) begin
				continue;
			end

			for (col_tile_start = 0; col_tile_start < N_COLS/4; col_tile_start += 4) begin
				tiles_in_group = N_COLS/4 - col_tile_start;
				if (tiles_in_group > 4) tiles_in_group = 4;

				// Zero all accumulator tiles in this group.
				for (tile = 0; tile < tiles_in_group; tile++) begin
					issue_and_commit(enc_mzero(acc_regs[tile]), 32'd0, 32'd0, next_id);
					next_id++; issued_cnt++;
				end

				// Walk the sparse row once per tile group and reuse each sparse chunk.
				for (val_ptr = row_ptrs[row_idx]; val_ptr < row_ptrs[row_idx + 1];) begin
					nnz_to_load = row_ptrs[row_idx + 1] - val_ptr;

					chunk_limit = 4 - (val_ptr & 2'b11);
					if (nnz_to_load > chunk_limit) nnz_to_load = chunk_limit;
					if (nnz_to_load > 4) nnz_to_load = 4;

					issue_and_commit(enc_spld_w(3'd0, 3'(nnz_to_load)), VAL_BASE + val_ptr * 4, COL_BASE + val_ptr * 4, next_id); 
					next_id++; issued_cnt++;
					val_ptr = val_ptr + nnz_to_load;
					wait (completed_results >= issued_cnt); repeat (1) @(posedge clk_i);

					for (tile = 0; tile <= tiles_in_group; tile++) begin
						if (tile < tiles_in_group) begin
							col_tile_idx = col_tile_start + tile;
							dld_ids[tile] = next_id;
							issue_and_commit(enc_dld_w(dense_regs[tile % 2], 3'd0), B_BASE + 32'(col_tile_idx * 16), ROW_STRIDE, next_id); 
							next_id++; issued_cnt++;
						end

						if (tile > 0) begin
							wait (instr_log[id_to_log_idx[dld_ids[tile-1]]].complete_cycle != '1);
							spmac_ids[tile-1] = next_id;
							issue_and_commit(enc_spmac_w(3'd0, dense_regs[(tile-1) % 2], acc_regs[tile-1]), 32'd0, 32'd0, next_id); 
							next_id++; issued_cnt++;
						end
					end
				end

				// Store the completed output tile group.
				for (tile = 0; tile < tiles_in_group; tile++) begin
					col_tile_idx = col_tile_start + tile;
					issue_and_commit(enc_mst_w(acc_regs[tile]), C_BASE + 32'(row_idx * (N_COLS * 4) + col_tile_idx * 16), ROW_STRIDE, next_id);
					next_id++; issued_cnt++;
				end
			end
		end
		end


		if (run_dense) begin
		for (int m = 0; m < M_PAD; m += 8) begin
			for (int n = 0; n < N_PAD; n += 8) begin

				// (m4..m7)
				for (int acc = 4; acc < 8; acc++) begin
					issue_and_commit(enc_mzero(3'(acc)), '0, '0, next_id);
					next_id++; issued_cnt++;
				end
				wait (completed_results >= issued_cnt);
				repeat (2) @(posedge clk_i);

				for (int k = 0; k < K_PAD; k += 4) begin
					a0 = A_BASE + (m       * K_PAD + k) * 4;
					a4 = A_BASE + ((m + 4) * K_PAD + k) * 4;
					b0 = BT_BASE + (n       * K_PAD + k) * 4;
					b4 = BT_BASE + ((n + 4) * K_PAD + k) * 4;

					issue_and_commit(enc_mld_w(3'd0), a0, ROW_STRIDE, next_id);
					next_id++; issued_cnt++;

					issue_and_commit(enc_mld_w(3'd1), b0, ROW_STRIDE, next_id);
					next_id++; issued_cnt++;
					wait (completed_results >= issued_cnt); repeat (2) @(posedge clk_i);

					issue_and_commit(enc_mmasa_w(3'd0, 3'd1, 3'd4), '0, '0, next_id);
					next_id++; issued_cnt++;

					issue_and_commit(enc_mld_w(3'd2), a4, ROW_STRIDE, next_id);
					next_id++; issued_cnt++;

					issue_and_commit(enc_mmasa_w(3'd2, 3'd1, 3'd6), '0, '0, next_id);
					next_id++; issued_cnt++;

					issue_and_commit(enc_mld_w(3'd3), b4, ROW_STRIDE, next_id);
					next_id++; issued_cnt++;

					issue_and_commit(enc_mmasa_w(3'd0, 3'd3, 3'd5), '0, '0, next_id);
					next_id++; issued_cnt++;

					issue_and_commit(enc_mmasa_w(3'd2, 3'd3, 3'd7), '0, '0, next_id);
					next_id++; issued_cnt++;
				end

				c00 = C_BASE + (m       * N_PAD + n)     * 4;
				c01 = C_BASE + (m       * N_PAD + n + 4) * 4;
				c10 = C_BASE + ((m + 4) * N_PAD + n)     * 4;
				c11 = C_BASE + ((m + 4) * N_PAD + n + 4) * 4;

				issue_and_commit(enc_mst_w(3'd4), c00, ROW_STRIDE, next_id);
				next_id++; issued_cnt++;

				issue_and_commit(enc_mst_w(3'd5), c01, ROW_STRIDE, next_id);
				next_id++; issued_cnt++;

				issue_and_commit(enc_mst_w(3'd6), c10, ROW_STRIDE, next_id);
				next_id++; issued_cnt++;

				issue_and_commit(enc_mst_w(3'd7), c11, ROW_STRIDE, next_id);
				next_id++; issued_cnt++;
				wait (completed_results >= issued_cnt); repeat (2) @(posedge clk_i);
			end
		end
		end


		repeat (10) @(posedge clk_i);

		$display("\n[TB] Cycles: %0d, Instructions: %0d", cycle_count, log_issue_ptr);
		/* $display("\n[TIMING] %0d instructions", log_issue_ptr);
		$display("[TIMING] idx   name        xif_id  issue   complete  latency");
		for (int i = 0; i < log_issue_ptr; i++) begin
			$display("[TIMING] %4d  %-10s  %2d      %6d  %8d  %6d",
				i,
				instr_log[i].name,
				instr_log[i].xif_id,
				instr_log[i].issue_cycle,
				instr_log[i].complete_cycle,
				instr_log[i].complete_cycle - instr_log[i].issue_cycle);
		end */

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

		//print_matrix(C_BASE, N_ROWS, N_COLS);

		$finish;
	end

	initial begin
		#5000ms;
		$fatal(1, "[TB] Timeout waiting for matrix multiplication flow.");
	end

endmodule
