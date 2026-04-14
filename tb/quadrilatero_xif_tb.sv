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
	localparam int N_ROWS     = 8;  // rows of sparse A
	localparam int N_COL_PAN  = 2;  // col panels of B (B_cols / 4)
	localparam int K_PANELS   = 1;  // non-zero panels per sparse row (NNZ_per_row / 4)
	localparam logic [31:0] B_BASE        = 32'h0000_0100;
	localparam logic [31:0] VAL_BASE      = 32'h0000_0300;
	localparam logic [31:0] COL_BASE      = 32'h0000_0400;
	localparam logic [31:0] C_LEFT_BASE   = 32'h0000_0800;
	localparam logic [31:0] C_RIGHT_BASE  = 32'h0000_0C00;
	localparam logic [31:0] ROW_STRIDE    = 32'd16;
	localparam logic [31:0] B_STRIDE      = 32'd32;

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

	// Cycle tracking for latency analysis
	longint unsigned cycle_count = 0;

	typedef struct {
		longint unsigned issue_cycle;
		longint unsigned complete_cycle;
	} instr_timing_t;

	instr_timing_t instr_timing [bit[$clog2($size(x_issue_req.id)*8)-1:0]];
	string instr_name [bit[$clog2($size(x_issue_req.id)*8)-1:0]];

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

	// Track completed coprocessor instructions.
	always_ff @(posedge clk_i or negedge rst_ni) begin
		if (!rst_ni) begin
			completed_results <= 0;
		end else if (x_result_valid && x_result_ready) begin
			completed_results <= completed_results + 1;
			instr_timing[x_result.id].complete_cycle = cycle_count;
			$display("[TB] completed instruction %s (cycle %0d, latency=%0d cycles)", 
				instr_name[x_result.id], cycle_count, 
				instr_timing[x_result.id].complete_cycle - instr_timing[x_result.id].issue_cycle);
		end
	end

	// Track issued instructions for latency
	always @(posedge clk_i) begin
		if (x_issue_valid && x_issue_ready) begin
			instr_timing[x_issue_req.id].issue_cycle = cycle_count;
			casez (x_issue_req.instr)
				quadrilatero_instr_pkg::SPLD_W  :  instr_name[x_issue_req.id] = "SPLD_W" 				;
				quadrilatero_instr_pkg::DLD_W   :  instr_name[x_issue_req.id] = "DLD_W" 				;
				quadrilatero_instr_pkg::MLD_W   :  instr_name[x_issue_req.id] = "MLD_W"  				;
				quadrilatero_instr_pkg::SPMAC_W :  instr_name[x_issue_req.id] = "SPMAC_W"				;
				quadrilatero_instr_pkg::MMASA_W :  instr_name[x_issue_req.id] = "MMASA_W"				;
				quadrilatero_instr_pkg::MZERO   :  instr_name[x_issue_req.id] = "MZERO"  				;
				quadrilatero_instr_pkg::MST_W   :  instr_name[x_issue_req.id] = "MST_W"  				;
				quadrilatero_instr_pkg::MST_B   :  instr_name[x_issue_req.id] = "MST_B"  				;
				quadrilatero_instr_pkg::MST_H   :  instr_name[x_issue_req.id] = "MSTH"   				;
				default					        :  instr_name[x_issue_req.id] = "UNKNOWN_INSTRUCTION" 	;
			endcase
			$display("[TB] issued %s id=%0d (cycle: %0d)", instr_name[x_issue_req.id], x_issue_req.id, cycle_count);
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

		for (int i = 0; i < 512; i++) begin
			mem_model[i] = '0;
		end

		//===========================================================================
		// 							Hardcoded Memory
		//===========================================================================
		// Sparse tile: 4 non-zero values and their column indices (one SPLD fetch each)
		/* load_data_into_mem(VAL_BASE, "mat_sp_val_8_0.5.hex");
		load_data_into_mem(COL_BASE, "mat_sp_col_8_0.5.hex");
		load_data_into_mem(ROW_BASE, "mat_sp_row_8_0.5.hex");
		// Dense matrix B, row-major.
		load_data_into_mem(B_BASE, "mat_d_8.hex"); */

		for (int i = 0; i < 8; i++) begin
			mem_model[(B_BASE >> 4) + i*2 + 0] = pack_row_lsb_first(i+1, i+1, i+1, i+1);
			mem_model[(B_BASE >> 4) + i*2 + 1] = pack_row_lsb_first(i+1, i+1, i+1, i+1);
		end

		begin
			automatic logic [31:0] val_flat [32] = '{
				1, 2, 3, 4,
				1, 2, 3, 4,
				1, 2, 3, 4,
				1, 2, 3, 4,
				1, 2, 3, 4,
				1, 2, 3, 4,
				1, 2, 3, 4,
				1, 2, 3, 4
			};
			automatic logic [31:0] col_flat [32] = '{
				0, 2, 4, 6,
				1, 3, 5, 7,
				0, 2, 4, 6,
				1, 3, 5, 7,
				0, 2, 4, 6,
				1, 3, 5, 7,
				0, 2, 4, 6,
				1, 3, 5, 7
			};
			for (int i = 0; i < 8; i++) begin
				mem_model[(VAL_BASE >> 4) + i] = pack_row_lsb_first(
					val_flat[i*4+0], val_flat[i*4+1], val_flat[i*4+2], val_flat[i*4+3]);
				mem_model[(COL_BASE >> 4) + i] = pack_row_lsb_first(
					col_flat[i*4+0], col_flat[i*4+1], col_flat[i*4+2], col_flat[i*4+3]);
			end
		end

		repeat (6) @(posedge clk_i);
		rst_ni = 1'b1;
		repeat (4) @(posedge clk_i);

		//===========================================================================
		// 							Instruction Issued
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
					// Gather B panel for row rp
					issue_and_commit(enc_dld_w(3'd1, 3'd0), B_BASE + 32'(cp * 16), B_STRIDE, next_id); next_id++; issued_cnt++;
					wait (completed_results >= issued_cnt); repeat (2) @(posedge clk_i);

					// SPMAC row rp — pipeline with DLD for row rp+1
					issue_and_commit(enc_spmac_w(3'd0, 3'd1, 3'(4 + cp)), 32'd0, 32'd0, next_id); next_id++; issued_cnt++;

					// Gather B panel for row rp+1 — overlaps with SPMAC above
					issue_and_commit(enc_dld_w(3'd3, 3'd2), B_BASE + 32'(cp * 16), B_STRIDE, next_id); next_id++; issued_cnt++;
					wait (completed_results >= issued_cnt); repeat (2) @(posedge clk_i);

					// SPMAC row rp+1
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

		//===========================================================================
		// 					Final prints of the Matrix registers
		//===========================================================================

		$display("\n[TB] Dense matrix B (8x8) @ 0x%08x:", B_BASE);
		for (r = 0; r < 8; r = r + 1) begin
			logic [127:0] lo, hi;
			lo = mem_model[(B_BASE >> 4) + r*2 + 0];
			hi = mem_model[(B_BASE >> 4) + r*2 + 1];
			$display("[TB]  %4d %4d %4d %4d | %4d %4d %4d %4d",
				$signed(lo[31:0]),  $signed(lo[63:32]),
				$signed(lo[95:64]), $signed(lo[127:96]),
				$signed(hi[31:0]),  $signed(hi[63:32]),
				$signed(hi[95:64]), $signed(hi[127:96])
			);
		end

		$display("\n[TB] Result C (8x8): cols 0-3 @ 0x%08x | cols 4-7 @ 0x%08x",
			C_LEFT_BASE, C_RIGHT_BASE);
		for (r = 0; r < 8; r = r + 1) begin
			logic [127:0] lo, hi;
			lo = mem_model[(C_LEFT_BASE  >> 4) + r];
			hi = mem_model[(C_RIGHT_BASE >> 4) + r];
			$display("[TB]  %4d %4d %4d %4d | %4d %4d %4d %4d",
				$signed(lo[31:0]),  $signed(lo[63:32]),
				$signed(lo[95:64]), $signed(lo[127:96]),
				$signed(hi[31:0]),  $signed(hi[63:32]),
				$signed(hi[95:64]), $signed(hi[127:96])
			);
		end

		$finish;
	end

	initial begin
		#50000ns;
		$fatal(1, "[TB] Timeout waiting for matrix multiplication flow.");
	end

endmodule