// Copyright 2026
// Solderpad Hardware License, Version 2.1,see LICENSE.md for details.
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// Author: Nik Erlandsson
// Author: Oskar Swärd

`timescale 1ns/1ps

module quadrilatero_xif_tb;
	import quadrilatero_pkg::*;
	import xif_pkg::*;

	localparam int CLK_PERIOD_NS = 10;
	localparam int N_ROWS     = 8;  // rows of sparse A / rows of C
	localparam int N_COL_PAN  = 2;  // col panels of B (B_cols / 4)
	localparam int K_PANELS   = 1;  // non-zero panels per sparse row (NNZ_per_row / 4)
	localparam int K          = 4;  // inner dimension (cols of sparse A = rows of B)
	localparam int N_COLS     = N_COL_PAN * 4; // output columns
	localparam int NNZ_PER_ROW = K_PANELS * 4; // non-zeros per sparse row
	localparam logic [31:0] B_BASE        = 32'h0000_0100;
	localparam logic [31:0] VAL_BASE      = 32'h0000_0300;
	localparam logic [31:0] COL_BASE      = 32'h0000_0400;
	localparam logic [31:0] C_LEFT_BASE   = 32'h0000_0800;
	localparam logic [31:0] C_RIGHT_BASE  = 32'h0000_0C00;
	localparam logic [31:0] ROW_STRIDE    = 32'd16;
	localparam logic [31:0] B_STRIDE      = 32'(N_COLS * 4); // stride between rows of B (N_COLS elements × 4 bytes)
	localparam int MAX_INSTRS = 4096;

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

	logic [127:0]		mem_model [0:511];
	logic				read_pending_q;
	logic [31:0]		read_addr_q;

	logic [31:0] tempmem [0:4096]; // Change size if needed
	int idx;
	int mem_fd;
	int scan_rc;
	logic [31:0] scan_word;
	int unsigned word_count;
	int unsigned b_rows;

	int unsigned completed_results;
	integer r, rp, cp, k, issued_cnt;
	logic [3:0] next_id;
	logic [31:0] C_col_base [2];

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

	//===========================================================================
	// 							Instruction encodings
	//===========================================================================

	function automatic logic [31:0] enc_mld_w(input logic [2:0] md);
		logic [31:0] instr;
		begin
			instr         = '0;
			instr[31:25]  = 7'b0000000;
			instr[14:12]  = 3'b000;
			instr[11:10]  = 2'b10;
			instr[9:7]    = md;
			instr[6:0]    = 7'b0101011;
			return instr;
		end
	endfunction

	// md: destination matrix register
	// msp: the sparse matrix register containing the row incidices to load
	function automatic logic [31:0] enc_dld_w(input logic [2:0] md, input logic [2:0] msp);
		logic [31:0] instr;
		begin
			instr         = '0;
			instr[31:25]  = 7'b0001000;
			instr[17:15]  = msp;
			instr[14:12]  = 3'b000;
			instr[11:10]  = 2'b10;
			instr[9:7]    = md;
			instr[6:0]    = 7'b0101011;
			return instr;
		end
	endfunction

	function automatic logic [31:0] enc_mst_w(input logic [2:0] ms1);
		logic [31:0] instr;
		begin
			instr         = '0;
			instr[31:25]  = 7'b0000110;
			instr[14:12]  = 3'b000;
			instr[11:10]  = 2'b10;
			instr[9:7]    = ms1;
			instr[6:0]    = 7'b0101011;
			return instr;
		end
	endfunction

	function automatic logic [31:0] enc_mzero(input logic [2:0] md);
		logic [31:0] instr;
		begin
			instr         = '0;
			instr[31:18]  = 14'b11111000000000;
			instr[17:15]  = md;
			instr[14:12]  = 3'b000;
			instr[11:7]   = 5'b00000;
			instr[6:0]    = 7'b0101011;
			return instr;
		end
	endfunction

	function automatic logic [31:0] enc_spld_w(input logic [2:0] md, input logic [2:0] nnz_to_load);
		logic [31:0] instr;
		begin
			instr         = '0;
			instr[31:25]  = 7'b0010000; // funct7
			instr[17:15]  = nnz_to_load;     
			instr[14:12]  = 3'b000;     // funct3
			instr[11:10]  = 2'b10;
			instr[9:7]    = md;         // destination reg
			instr[6:0]    = 7'b0101011; // opcode
			return instr;
		end
	endfunction

	function automatic logic [31:0] enc_spmac_w(
		input logic [2:0] a_reg,
		input logic [2:0] b_reg,
		input logic [2:0] acc_reg
	);
		logic [31:0] instr;
		begin
			instr         = '0;
			instr[31:24]  = 8'b01000000;
			instr[23:21]  = b_reg;
			instr[20:18]  = a_reg;
			instr[17:15]  = acc_reg;
			instr[14:12]  = 3'b000;
			instr[11:7]   = 5'b10000;
			instr[6:0]    = 7'b0101011;
			return instr;
		end
	endfunction

	function automatic logic [31:0] enc_mmasa_w(
		input logic [2:0] weight_reg,
		input logic [2:0] data_reg,
		input logic [2:0] acc_reg
	);
		logic [31:0] instr;
		begin
			instr         = '0;
			instr[31:24]  = 8'b11110000;
			instr[23:21]  = data_reg;
			instr[20:18]  = weight_reg;
			instr[17:15]  = acc_reg;
			instr[14:12]  = 3'b000;
			instr[11:7]   = 5'b10000;
			instr[6:0]    = 7'b0101011;
			return instr;
		end
	endfunction

	task automatic issue_and_commit(
		input logic [31:0] instr,
		input logic [31:0] rs0,
		input logic [31:0] rs1,
		input logic [3:0]  id
	);
		begin
			@(posedge clk_i);
			x_issue_req.instr    <= instr;
			x_issue_req.id       <= id;
			x_issue_req.mode     <= 2'b11;
			x_issue_req.rs[0]    <= rs0;
			x_issue_req.rs[1]    <= rs1;
			x_issue_req.rs_valid <= 2'b11;
			x_issue_req.ecs      <= '0;
			x_issue_req.ecs_valid <= 1'b0;
			x_issue_valid        <= 1'b1;

			do begin
				@(posedge clk_i);
			end while (!x_issue_ready);

			x_issue_valid <= 1'b0;

			x_commit.id          <= id;
			x_commit.commit_kill <= 1'b0;
			x_commit_valid       <= 1'b1;
			@(posedge clk_i);
			x_commit_valid       <= 1'b0;
		end
	endtask

	function automatic logic [127:0] pack_row_lsb_first(input logic [31:0] e0, e1, e2, e3);
	  return {e3, e2, e1, e0};
	endfunction

	function automatic void load_data_into_mem(input logic [31:0] addr, input string filename);
		// Load 32-bit words and pack them into 128-bit memory rows at addr.
		word_count = 0;
		mem_fd = $fopen(filename, "r");
		if (mem_fd == 0) begin
			$fatal(1, "[TB] Failed to open data file: %s", filename);
		end

		while (!$feof(mem_fd) && (word_count < $size(tempmem))) begin
			// Take in 32 bit hex words, use %d for decimal
			scan_rc = $fscanf(mem_fd, "%h\n", scan_word);
			if (scan_rc == 1) begin
				tempmem[word_count] = scan_word;
				word_count++;
			end else begin
				void'($fgetc(mem_fd));
			end
		end
		$fclose(mem_fd);

		if (word_count == 0) begin
			$fatal(1, "[TB] data file %s is empty", filename);
		end

		b_rows = word_count / 4;
		if (((addr >> 4) + b_rows) > 256) begin
			$fatal(1, "[TB] preload out of bounds for %s: addr=0x%08x rows=%0d", filename, addr, b_rows);
		end

		for (idx = 0; idx < b_rows; idx++) begin
			mem_model[(addr >> 4) + idx] = pack_row_lsb_first(
				tempmem[idx*4],
				tempmem[idx*4 + 1],
				tempmem[idx*4 + 2],
				tempmem[idx*4 + 3]
			);
		end
		
		if (word_count % 4) begin
			mem_model[(addr >> 4) + b_rows] = pack_row_lsb_first(
				(word_count > b_rows*4) ? tempmem[b_rows*4] : 32'd0,
				(word_count > b_rows*4 + 1) ? tempmem[b_rows*4 + 1] : 32'd0,
				(word_count > b_rows*4 + 2) ? tempmem[b_rows*4 + 2] : 32'd0,
				(word_count > b_rows*4 + 3) ? tempmem[b_rows*4 + 3] : 32'd0
			);
		end

		$display("[TB] Loaded %s at 0x%08x: %0d words (%0d rows)", filename, addr, word_count, b_rows);
	endfunction	
	

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
				mem_rvalid <= 1'b1;
				mem_rdata  <= mem_model[read_addr_q[31:4]];
			end

			read_pending_q <= 1'b0;
			if (mem_req && mem_gnt && !mem_we) begin
				read_pending_q <= 1'b1;
				read_addr_q    <= mem_addr;
			end

			if (mem_req && mem_gnt && mem_we) begin
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
		logic signed [31:0] ref_A    [0:N_ROWS-1][0:K-1];          // dense rep of sparse A
		logic signed [31:0] ref_B    [0:K-1][0:N_COLS-1];          // dense B
		logic signed [31:0] ref_C    [0:N_ROWS-1][0:N_COLS-1];     // reference C = A*B
		logic signed [31:0] dut_C    [0:N_ROWS-1][0:N_COLS-1];     // C read back from mem
		logic [31:0]         val_data [0:N_ROWS-1][0:NNZ_PER_ROW-1]; // sparse A values
		logic [31:0]         col_data [0:N_ROWS-1][0:NNZ_PER_ROW-1]; // sparse A col indices
		int errors, mem_idx;

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

		for (int i = 0; i < 512; i++) mem_model[i] = '0;
		for (int i = 0; i < 16;  i++) id_to_log_idx[i] = 0;

		//===========================================================================
		// Build reference matrices (pad = 0)
		//===========================================================================
		// Sparse tile: 4 non-zero values and their column indices (one SPLD fetch each)
		/* load_data_into_mem(VAL_BASE, "mat_sp_val_8_0.5.hex");
		load_data_into_mem(COL_BASE, "mat_sp_col_8_0.5.hex");
		load_data_into_mem(ROW_BASE, "mat_sp_row_8_0.5.hex");
		// Dense matrix B, row-major.
		load_data_into_mem(B_BASE, "mat_d_8.hex"); */

		// Sparse A column indices: with K=NNZ_PER_ROW every row is dense (cols 0..K-1)
		for (int i = 0; i < N_ROWS; i++)
			for (int kk = 0; kk < NNZ_PER_ROW; kk++)
				col_data[i][kk] = kk;

		// Sparse A values: randomly sparse (~70% zeros), non-zeros use formula
		for (int i = 0; i < N_ROWS; i++)
			for (int kk = 0; kk < NNZ_PER_ROW; kk++)
				val_data[i][kk] = ($urandom_range(0,9) < 7) ? 0 : (i + col_data[i][kk] + 1);

		// Dense ref_A from CSR (for reference computation)
		for (int i = 0; i < N_ROWS; i++) begin
			for (int j = 0; j < K; j++) ref_A[i][j] = '0;
			for (int kk = 0; kk < NNZ_PER_ROW; kk++)
				ref_A[i][col_data[i][kk]] = val_data[i][kk];
		end

		// Dense B: same formula as original (B^T[j][k] = j-k+5  =>  B[k][j] = j-k+5)
		for (int k2 = 0; k2 < K; k2++)
			for (int j = 0; j < N_COLS; j++)
				ref_B[k2][j] = 32'(j - k2 + 5);

		// ref_C = ref_A * ref_B
		for (int i = 0; i < N_ROWS; i++)
			for (int j = 0; j < N_COLS; j++) begin
				ref_C[i][j] = 0;
				for (int k2 = 0; k2 < K; k2++)
					ref_C[i][j] += ref_A[i][k2] * ref_B[k2][j];
			end

		$display("=== SPARSE A MATRIX ===");
		for (int i = 0; i < N_ROWS; i++) begin
			for (int j = 0; j < K; j++)
				$write("%6d ", ref_A[i][j]);
			$write("\n");
		end
		$display("=======================");

		$display("=== B MATRIX (stored as B^T: %0d x %0d) ===", N_COLS, K);
		for (int j = 0; j < N_COLS; j++) begin
			for (int k2 = 0; k2 < K; k2++)
				$write("%6d ", ref_B[k2][j]);  // B^T[j][k2] = B[k2][j]
			$write("\n");
		end
		$display("================");

		//===========================================================================
		// Write reference matrices into mem_model
		//===========================================================================

		// B at B_BASE: K rows × N_COLS cols (4×8), 2 mem-lines per row (cols 0-3, cols 4-7)
		for (int k2 = 0; k2 < K; k2++) begin
			mem_model[(B_BASE >> 4) + k2*2 + 0] = pack_row_lsb_first(
				32'(ref_B[k2][0]), 32'(ref_B[k2][1]),
				32'(ref_B[k2][2]), 32'(ref_B[k2][3]));
			mem_model[(B_BASE >> 4) + k2*2 + 1] = pack_row_lsb_first(
				32'(ref_B[k2][4]), 32'(ref_B[k2][5]),
				32'(ref_B[k2][6]), 32'(ref_B[k2][7]));
		end

		// Sparse A values and column indices at VAL_BASE / COL_BASE
		for (int i = 0; i < N_ROWS; i++) begin
			mem_model[(VAL_BASE >> 4) + i] = pack_row_lsb_first(
				val_data[i][0], val_data[i][1], val_data[i][2], val_data[i][3]);
			mem_model[(COL_BASE >> 4) + i] = pack_row_lsb_first(
				col_data[i][0], col_data[i][1], col_data[i][2], col_data[i][3]);
		end

		$display("[TB] A (%0d x %0d sparse, %0d NNZ/row) at VAL=0x%08x COL=0x%08x",
			N_ROWS, K, NNZ_PER_ROW, VAL_BASE, COL_BASE);
		$display("[TB] B (%0d x %0d dense) at 0x%08x  stride=%0d bytes",
			K, N_COLS, B_BASE, B_STRIDE);
		$display("[TB] C (%0d x %0d) at LEFT=0x%08x RIGHT=0x%08x  row_stride=%0d bytes",
			N_ROWS, N_COLS, C_LEFT_BASE, C_RIGHT_BASE, ROW_STRIDE);

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
		next_id       = 4'd0;
		C_col_base[0] = C_LEFT_BASE;
		C_col_base[1] = C_RIGHT_BASE;

		for (rp = 0; rp < N_ROWS; rp += 2) begin

			for (int acc = 0; acc < 2*N_COL_PAN; acc++) begin
				issue_and_commit(enc_mzero(3'(4 + acc)), 32'd0, 32'd0, next_id); next_id++; issued_cnt++;
			end

			for (k = 0; k < K_PANELS; k++) begin
				issue_and_commit(enc_spld_w(3'd0, 3'd4),
					VAL_BASE + 32'((rp     * K_PANELS + k) * 16),
					COL_BASE + 32'((rp     * K_PANELS + k) * 16),
					next_id); next_id++; issued_cnt++;
				wait (completed_results >= issued_cnt);
				repeat (2) @(posedge clk_i);

				issue_and_commit(enc_spld_w(3'd2, 3'd4),
					VAL_BASE + 32'(((rp+1) * K_PANELS + k) * 16),
					COL_BASE + 32'(((rp+1) * K_PANELS + k) * 16),
					next_id); next_id++; issued_cnt++;
				wait (completed_results >= issued_cnt);
				repeat (2) @(posedge clk_i);

				for (cp = 0; cp < N_COL_PAN; cp++) begin
					issue_and_commit(enc_dld_w(3'd1, 3'd0), B_BASE + 32'(cp * 16), B_STRIDE, next_id); next_id++; issued_cnt++;
					wait (completed_results >= issued_cnt); repeat (2) @(posedge clk_i);

					issue_and_commit(enc_spmac_w(3'd0, 3'd1, 3'(4 + cp)), 32'd0, 32'd0, next_id); next_id++; issued_cnt++;

					issue_and_commit(enc_dld_w(3'd3, 3'd2), B_BASE + 32'(cp * 16), B_STRIDE, next_id); next_id++; issued_cnt++;
					wait (completed_results >= issued_cnt); repeat (2) @(posedge clk_i);

					issue_and_commit(enc_spmac_w(3'd2, 3'd3, 3'(4 + N_COL_PAN + cp)), 32'd0, 32'd0, next_id); next_id++; issued_cnt++;
					wait (completed_results >= issued_cnt); repeat (2) @(posedge clk_i);
				end
			end

			for (cp = 0; cp < N_COL_PAN; cp++) begin
				issue_and_commit(enc_mst_w(3'(4 + cp)),             C_col_base[cp] + 32'(rp       * 16), ROW_STRIDE, next_id); next_id++; issued_cnt++;
				wait (completed_results >= issued_cnt); repeat (2) @(posedge clk_i);
				issue_and_commit(enc_mst_w(3'(4 + N_COL_PAN + cp)), C_col_base[cp] + 32'((rp + 1) * 16), ROW_STRIDE, next_id); next_id++; issued_cnt++;
				wait (completed_results >= issued_cnt); repeat (2) @(posedge clk_i);
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
		// Read back dut_C and verify against ref_C
		//===========================================================================

		for (int i = 0; i < N_ROWS; i++) begin
			mem_idx = (C_LEFT_BASE >> 4) + i;
			dut_C[i][0] = $signed(mem_model[mem_idx][ 31: 0]);
			dut_C[i][1] = $signed(mem_model[mem_idx][ 63:32]);
			dut_C[i][2] = $signed(mem_model[mem_idx][ 95:64]);
			dut_C[i][3] = $signed(mem_model[mem_idx][127:96]);
			mem_idx = (C_RIGHT_BASE >> 4) + i;
			dut_C[i][4] = $signed(mem_model[mem_idx][ 31: 0]);
			dut_C[i][5] = $signed(mem_model[mem_idx][ 63:32]);
			dut_C[i][6] = $signed(mem_model[mem_idx][ 95:64]);
			dut_C[i][7] = $signed(mem_model[mem_idx][127:96]);
		end

		$display("\n[TB] C (%0d x %0d)  DUT | REF", N_ROWS, N_COLS);
		for (int i = 0; i < N_ROWS; i++) begin
			for (int j = 0; j < N_COLS; j++) $write(" %6d", $signed(dut_C[i][j]));
			$write("  |");
			for (int j = 0; j < N_COLS; j++) $write(" %6d", $signed(ref_C[i][j]));
			$display("");
		end

		errors = 0;
		for (int i = 0; i < N_ROWS; i++)
			for (int j = 0; j < N_COLS; j++)
				if (dut_C[i][j] !== ref_C[i][j]) begin
					$display("[ERROR] C[%0d][%0d]: DUT=%0d  REF=%0d",
						i, j, $signed(dut_C[i][j]), $signed(ref_C[i][j]));
					errors++;
				end

		if (errors == 0)
			$display("\n[TB] PASS -- all %0d elements correct.", N_ROWS*N_COLS);
		else
			$display("\n[TB] FAIL -- %0d mismatches.", errors);

		$finish;
	end

	initial begin
		#50000ns;
		$fatal(1, "[TB] Timeout waiting for matrix multiplication flow.");
	end

endmodule