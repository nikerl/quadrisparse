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
	localparam logic [31:0] A_BASE = 32'h0000_0000;
	localparam logic [31:0] B_BASE = 32'h0000_0100;
	localparam logic [31:0] C_BASE = 32'h0000_0200;
	localparam logic [31:0] VAL_BASE = 32'h0000_0300;
	localparam logic [31:0] COL_BASE = 32'h0000_0400;
	localparam logic [31:0] ROW_STRIDE = 32'd16;

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

	logic [127:0]		mem_model [0:255];
	logic				read_pending_q;
	logic [31:0]		read_addr_q;

	int unsigned completed_results;
	integer r;

	// Cycle tracking for latency analysis
	longint unsigned cycle_count = 0;

	typedef struct {
		longint unsigned issue_cycle;
		longint unsigned complete_cycle;
	} instr_timing_t;

	instr_timing_t instr_timing [bit[$clog2($size(x_issue_req.id)*8)-1:0]];

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

	function automatic logic [31:0] enc_spld_w(input logic [2:0] md);
		logic [31:0] instr;
		begin
			instr         = '0;
			instr[31:25]  = 7'b0010000; // funct7
			instr[14:12]  = 3'b000;     // funct3
			instr[11:10]  = 2'b10;
			instr[9:7]    = md;         // destination reg
			instr[6:0]    = 7'b0101011; // opcode
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
			$display("[TB] completed instruction id=%0d (cycle %0d, latency=%0d cycles)", 
				x_result.id, cycle_count, 
				instr_timing[x_result.id].complete_cycle - instr_timing[x_result.id].issue_cycle);
		end
	end

	// Track issued instructions for latency
	always @(posedge clk_i) begin
		if (x_issue_valid && x_issue_ready) begin
			instr_timing[x_issue_req.id].issue_cycle = cycle_count;
			$display("[TB] issued instruction id=%0d (cycle %0d)", x_issue_req.id, cycle_count);
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

		for (int i = 0; i < 256; i++) begin
			mem_model[i] = '0;
		end


		// Dense matrix B, row-major.
		mem_model[(B_BASE >> 4) + 0] = pack_row_lsb_first(32'd1, 32'd7, 32'd5, 32'd9); //0
		mem_model[(B_BASE >> 4) + 1] = pack_row_lsb_first(32'd4, 32'd4, 32'd4, 32'd4); //1
		mem_model[(B_BASE >> 4) + 2] = pack_row_lsb_first(32'd5, 32'd5, 32'd5, 32'd5); //2
		mem_model[(B_BASE >> 4) + 3] = pack_row_lsb_first(32'd4, 32'd6, 32'd3, 32'd5); //3
		mem_model[(B_BASE >> 4) + 4] = pack_row_lsb_first(32'd7, 32'd2, 32'd6, 32'd4); //4
		mem_model[(B_BASE >> 4) + 5] = pack_row_lsb_first(32'd6, 32'd6, 32'd6, 32'd6); //5
		mem_model[(B_BASE >> 4) + 6] = pack_row_lsb_first(32'd3, 32'd1, 32'd7, 32'd9); //6

		// Sparse tile: 4 non-zero values and their column indices (one SPLD fetch each)
		mem_model[(VAL_BASE >> 4)] = pack_row_lsb_first(32'd1, 32'd4, 32'd6, 32'd9);
		mem_model[(COL_BASE >> 4)] = pack_row_lsb_first(32'd0, 32'd3, 32'd4, 32'd6);

		repeat (6) @(posedge clk_i);
		rst_ni = 1'b1;
		repeat (4) @(posedge clk_i);


		// ########### LOAD OPERAND MATRICIES ###########
		// mld.w m0, [A_BASE], stride=16
		
		issue_and_commit(enc_spld_w(3'd0), VAL_BASE, COL_BASE, 4'd1);

		wait (completed_results >= 1); // make sure SPLD is fully done
		repeat (10) @(posedge clk_i);   // optional small delay for safety

		// dld.w m1, [B_BASE], stride=16, index_reg=m0
		issue_and_commit(enc_dld_w(3'd1, 3'd0), B_BASE, ROW_STRIDE, 4'd2);

		wait (completed_results >= 2);
		repeat (10) @(posedge clk_i);  


		// ########### PERFORM MATMUL ###########
		// mzero m2
		issue_and_commit(enc_mzero(3'd2), 32'd0, 32'd0, 4'd3);

		// spmac.w m2 += m0 * m1
		issue_and_commit(enc_spmac_w(3'd0, 3'd1, 3'd2), 32'd0, 32'd0, 4'd4);


		// ########### STORE RESULTS ###########
		// mst.w m0, [BASE_ADDR], stride=16 
		issue_and_commit(enc_mst_w(3'd0), A_BASE, ROW_STRIDE, 4'd5);
		issue_and_commit(enc_mst_w(3'd1), B_BASE, ROW_STRIDE, 4'd6);
		issue_and_commit(enc_mst_w(3'd2), C_BASE, ROW_STRIDE, 4'd7);

		// IDs 3 and 4 are currently disabled (mzero/mmasa), so expect 4 completions.
		wait (completed_results >= 7);
		repeat (10) @(posedge clk_i);
		


		$display("\n[TB] Sparse matrix A (from memory @ 0x%08x):", A_BASE);
		for (r = 0; r < 4; r = r + 1) begin
			logic [127:0] rowA;
			rowA = mem_model[(A_BASE >> 4) + r];
			$display("[TB] %0d %0d %0d %0d",
				$signed(rowA[31:0]),
				$signed(rowA[63:32]),
				$signed(rowA[95:64]),
				$signed(rowA[127:96])
			);
		end

		$display("\n[TB] Dense matrix B (from memory @ 0x%08x):", B_BASE);
		for (r = 0; r < 4; r = r + 1) begin
			logic [127:0] rowB;
			rowB = mem_model[(B_BASE >> 4) + r];
			$display("[TB] %0d %0d %0d %0d",
				$signed(rowB[31:0]),
				$signed(rowB[63:32]),
				$signed(rowB[95:64]),
				$signed(rowB[127:96])
			);
		end

		$display("\n[TB] Result matrix C (from memory @ 0x%08x):", C_BASE);
		for (r = 0; r < 4; r = r + 1) begin
			logic [127:0] rowC;
			rowC = mem_model[(C_BASE >> 4) + r];
			$display("[TB] %0d %0d %0d %0d",
				$signed(rowC[31:0]),
				$signed(rowC[63:32]),
				$signed(rowC[95:64]),
				$signed(rowC[127:96])
			);
		end

		$finish;
	end

	initial begin
		#50000ns;
		$fatal(1, "[TB] Timeout waiting for matrix multiplication flow.");
	end

endmodule
