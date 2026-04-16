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

	localparam int CLK_PERIOD_NS 	= 10;
	localparam int N_ROWS     		= 16;  // rows of sparse A / rows of C
	localparam int N_COLS 	  		= 16;  // cols of dense B / cols of C
	localparam int ROW_STRIDE 		= N_COLS * 4;
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

	logic [31:0] row_ptrs [0:N_ROWS]; // row pointers for the sparse matrix, loaded from file

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

	function automatic int unsigned mem_row_idx(input logic [31:0] addr);
		return addr >> 4;
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

		b_rows = (word_count + 3) / 4;
		if ((mem_row_idx(addr) + b_rows) > MEM_MODEL_DEPTH) begin
			$fatal(1, "[TB] preload out of bounds for %s: addr=0x%08x rows=%0d depth=%0d", filename, addr, b_rows, MEM_MODEL_DEPTH);
		end

		for (idx = 0; idx < (word_count / 4); idx++) begin
			mem_model[(addr >> 4) + idx] = pack_row_lsb_first(
				tempmem[idx*4],
				tempmem[idx*4 + 1],
				tempmem[idx*4 + 2],
				tempmem[idx*4 + 3]
			);
		end
		
		if (word_count % 4) begin
			mem_model[(addr >> 4) + (word_count / 4)] = pack_row_lsb_first(
				(word_count > (word_count / 4)*4) ? tempmem[(word_count / 4)*4] : 32'd0,
				(word_count > (word_count / 4)*4 + 1) ? tempmem[(word_count / 4)*4 + 1] : 32'd0,
				(word_count > (word_count / 4)*4 + 2) ? tempmem[(word_count / 4)*4 + 2] : 32'd0,
				(word_count > (word_count / 4)*4 + 3) ? tempmem[(word_count / 4)*4 + 3] : 32'd0
			);
		end

		$display("[TB] Loaded %s at 0x%08x: %0d words (%0d rows)", filename, addr, word_count, b_rows);
	endfunction	

	function automatic void load_row_ptr(input string filename);
		// Load 32-bit words into a local array
		word_count = 0;
		mem_fd = $fopen(filename, "r");
		if (mem_fd == 0) begin
			$fatal(1, "[TB] Failed to open data file: %s", filename);
		end

		while (!$feof(mem_fd) && (word_count < $size(tempmem))) begin
			// Take in 32 bit hex words, use %d for decimal
			scan_rc = $fscanf(mem_fd, "%h\n", scan_word);
			if (scan_rc == 1) begin
				row_ptrs[word_count] = scan_word;
				word_count++;
			end else begin
				void'($fgetc(mem_fd));
			end
		end
		$fclose(mem_fd);

		if (word_count == 0) begin
			$fatal(1, "[TB] data file %s is empty", filename);
		end

	endfunction	

	function automatic void print_matrix(input logic [31:0] base_addr, input int rows, input int cols);
		logic signed [31:0] got_val;
		int elem_idx;
		$display("[TB] C at 0x%08x (%0d x %0d):", base_addr, rows, cols);
		for (int i = 0; i < rows; i++) begin
			for (int j = 0; j < cols; j++) begin
				elem_idx = i * cols + j;
				got_val = $signed(mem_model[(base_addr + elem_idx * 4) >> 4][(((base_addr + elem_idx * 4) >> 2) & 2'b11) * 32 +: 32]);
				$write(" %6d", got_val);
			end
			$display("");
		end
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

		for (int i = 0; i < $size(mem_model); i++) mem_model[i] = '0;
		for (int i = 0; i < 16;  i++) id_to_log_idx[i] = 0;

		//===========================================================================
		// Load matricies from data files
		//===========================================================================

		// Sparse A column indices: with K=NNZ_PER_ROW every row is dense (cols 0..K-1)
		load_data_into_mem(VAL_BASE, "mat_sp_val_16_0.8.hex");
		load_data_into_mem(COL_BASE, "mat_sp_col_16_0.8.hex");
		load_row_ptr("mat_sp_row_16_0.8.hex");
		
		// Dense matrix B, row-major.
		load_data_into_mem(B_BASE, "mat_d_16_0.8.hex");

		// result matrix for reference
		load_data_into_mem(REF_BASE, "mat_ref_16_0.8.hex");


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
		val_ptr       = 0;

		// For each row with in the row_ptr array
		for (int row_idx = 0; row_idx < $size(row_ptrs) - 1; row_idx++) begin
			// For each tile on this row in the dense matrix 
			for (int col_tiles = 0; col_tiles < N_COLS / 4; col_tiles++) begin
				// Reset the accumulator register for this output tile.
				issue_and_commit(enc_mzero(3'(4 + col_tiles)), 32'd0, 32'd0, next_id); next_id++; issued_cnt++;

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
					issue_and_commit(enc_spmac_w(3'd0, 3'd1, 3'(4 + col_tiles)), 32'd0, 32'd0, next_id); next_id++; issued_cnt++;
					wait (completed_results >= issued_cnt); repeat (2) @(posedge clk_i);
				
				end
				// write back the result
				issue_and_commit(enc_mst_w(3'(4 + col_tiles)), C_BASE + 32'(row_idx * (N_COLS * 4) + col_tiles * 16), ROW_STRIDE, next_id);
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
		#5000000000ns;
		$fatal(1, "[TB] Timeout waiting for matrix multiplication flow.");
	end

endmodule
