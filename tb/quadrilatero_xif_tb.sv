// Copyright 2026
// Solderpad Hardware License, Version 2.1, see LICENSE.md for details.
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// Author: Nik Erlandsson
// Author: Oskar Swärd

`timescale 1ns/1ps

module quadrilatero_xif_tb;
	import quadrilatero_pkg::*;
	import xif_pkg::*;

	localparam int M = 8;   // rows of A  / rows of C
	localparam int N = 8;   // cols of B  / cols of C
	localparam int K = 4;   // inner dimension (cols of A = rows of B)

	localparam int M_PAD = ((M + 7) / 8) * 8;
	localparam int N_PAD = ((N + 7) / 8) * 8;
	localparam int K_PAD = ((K + 3) / 4) * 4;

	localparam logic [31:0] A_BASE   = 32'h0000_0000;
	localparam logic [31:0] B_BASE   = 32'h0000_1000;   // >= M_PAD*K_PAD*4 bytes
	localparam logic [31:0] C_BASE   = 32'h0000_2000;   // >= B_BASE + N_PAD*K_PAD*4 bytes
	localparam logic [31:0] A_STRIDE = K_PAD * 4;
	localparam logic [31:0] B_STRIDE = K_PAD * 4;
	localparam logic [31:0] C_STRIDE = N_PAD * 4;

	localparam int CLK_PERIOD_NS = 10;
	localparam int MEM_ENTRIES   = 4096;
	localparam int MAX_INSTRS    = 4096;

	localparam int N_INSTRS_EST = (M_PAD/8) * (N_PAD/8) * (4 + (K_PAD/4)*8 + 4);
	localparam int TIMEOUT_NS   = (N_INSTRS_EST * 300 + 1000) * CLK_PERIOD_NS;

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

	logic [127:0]		mem_model [0:MEM_ENTRIES-1];
	logic				read_pending_q;
	logic [31:0]		read_addr_q;

	int unsigned		completed_results;
	integer				issued_cnt;
	logic [3:0]			next_id;
	longint unsigned	cycle_count = 0;

	typedef struct {
		longint unsigned issue_cycle;
		longint unsigned complete_cycle;
		string           name;
		logic [3:0]      xif_id;
	} instr_log_t;

	instr_log_t instr_log  [0:MAX_INSTRS-1];
	int         log_issue_ptr             = 0;
	int         id_to_log_idx [0:15];

	function automatic logic [31:0] enc_mld_w(input logic [2:0] md);
		logic [31:0] instr;
		instr         = '0;
		instr[31:25]  = 7'b0000000;
		instr[14:12]  = 3'b000;
		instr[11:10]  = 2'b10;
		instr[9:7]    = md;
		instr[6:0]    = 7'b0101011;
		return instr;
	endfunction

	function automatic logic [31:0] enc_mst_w(input logic [2:0] ms1);
		logic [31:0] instr;
		instr         = '0;
		instr[31:25]  = 7'b0000110;
		instr[14:12]  = 3'b000;
		instr[11:10]  = 2'b10;
		instr[9:7]    = ms1;
		instr[6:0]    = 7'b0101011;
		return instr;
	endfunction

	function automatic logic [31:0] enc_mzero(input logic [2:0] md);
		logic [31:0] instr;
		instr         = '0;
		instr[31:18]  = 14'b11111000000000;
		instr[17:15]  = md;
		instr[14:12]  = 3'b000;
		instr[11:7]   = 5'b00000;
		instr[6:0]    = 7'b0101011;
		return instr;
	endfunction

	// Dense MAC: acc_reg += weight_reg x data_reg
	// Usage: enc_mmasa_w(A_tile, BT_tile, acc) for acc += A_tile x BT_tile
	function automatic logic [31:0] enc_mmasa_w(
		input logic [2:0] weight_reg,
		input logic [2:0] data_reg,
		input logic [2:0] acc_reg
	);
		logic [31:0] instr;
		instr         = '0;
		instr[31:24]  = 8'b11110000;
		instr[23:21]  = data_reg;
		instr[20:18]  = weight_reg;
		instr[17:15]  = acc_reg;
		instr[14:12]  = 3'b000;
		instr[11:7]   = 5'b10000;
		instr[6:0]    = 7'b0101011;
		return instr;
	endfunction

	function automatic logic [127:0] pack_row(input logic [31:0] e0, e1, e2, e3);
		return {e3, e2, e1, e0};
	endfunction

	//===========================================================================
	// issue_and_commit task
	//===========================================================================

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
			x_commit_valid <= 1'b0;
		end
	endtask

	//===========================================================================
	// Clock + cycle counter
	//===========================================================================

	initial clk_i = 1'b0;
	always  #(CLK_PERIOD_NS/2) clk_i = ~clk_i;

	always @(posedge clk_i) cycle_count <= cycle_count + 1;

	//===========================================================================
	// Simple memory model (1-cycle read latency, immediate write)
	//===========================================================================

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
					if (mem_be[b])
						mem_model[mem_addr[31:4]][8*b +: 8] <= mem_wdata[8*b +: 8];
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
				quadrilatero_instr_pkg::MLD_W   : instr_log[log_issue_ptr].name = "MLD_W";
				quadrilatero_instr_pkg::MMASA_W : instr_log[log_issue_ptr].name = "MMASA_W";
				quadrilatero_instr_pkg::MZERO   : instr_log[log_issue_ptr].name = "MZERO";
				quadrilatero_instr_pkg::MST_W   : instr_log[log_issue_ptr].name = "MST_W";
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

	//===========================================================================
	// Main stimulus
	//===========================================================================

	initial begin
		// ── local working variables ────────────────────────────────────
		logic signed [31:0] ref_A  [0:M_PAD-1][0:K_PAD-1]; // A  (M×K, padded)
		logic signed [31:0] ref_BT [0:N_PAD-1][0:K_PAD-1]; // B^T(N×K, padded)
		logic signed [31:0] ref_C  [0:M_PAD-1][0:N_PAD-1]; // reference C = A×B
		logic signed [31:0] dut_C  [0:M_PAD-1][0:N_PAD-1]; // C read back
		logic [31:0] a0, a4, b0, b4;                        // tile base addresses
		logic [31:0] c00, c01, c10, c11;                    // C store addresses
		int errors, mem_idx;

		// ── defaults ────────────────────────────────────────────────────
		rst_ni             = 1'b0;
		x_compressed_valid = 1'b0;
		x_compressed_req   = '0;
		x_issue_valid      = 1'b0;
		x_issue_req        = '0;
		x_commit_valid     = 1'b0;
		x_commit           = '0;
		x_mem_ready        = 1'b1;
		x_mem_resp         = '0;
		x_mem_result_valid = 1'b0;
		x_mem_result       = '0;
		x_result_ready     = 1'b1;
		issued_cnt         = 0;
		next_id            = 4'd0;

		for (int i = 0; i < MEM_ENTRIES; i++) mem_model[i] = '0;
		for (int i = 0; i < 16;          i++) id_to_log_idx[i] = 0;

		//===========================================================
		// Build reference matrices with small integers (pad = 0)
		//===========================================================

		for (int i = 0; i < M_PAD; i++)
			for (int k = 0; k < K_PAD; k++)
				ref_A[i][k] = ($urandom_range(0,9) < 7) ? 0 : (i + k + 1);

		for (int j = 0; j < N_PAD; j++)
			for (int k = 0; k < K_PAD; k++)
				ref_BT[j][k] = (j < N && k < K) ? 32'(j - k + 5) : '0;

		// ref_C = A x B, using B[k][j] = ref_BT[j][k]
		for (int i = 0; i < M_PAD; i++)
			for (int j = 0; j < N_PAD; j++) begin
				ref_C[i][j] = 0;
				for (int k = 0; k < K_PAD; k++)
					ref_C[i][j] += ref_A[i][k] * ref_BT[j][k];
			end

		//===========================================================
		// Write A and B^T into mem_model
		//===========================================================

		for (int i = 0; i < M_PAD; i++)
			for (int k = 0; k < K_PAD; k += 4) begin
				mem_idx = (A_BASE >> 4) + i * (K_PAD / 4) + k / 4;
				mem_model[mem_idx] = pack_row(
					32'(ref_A[i][k+0]), 32'(ref_A[i][k+1]),
					32'(ref_A[i][k+2]), 32'(ref_A[i][k+3]));
			end
		
		
		$display("=== A MATRIX ===");

		for (int i = 0; i < M_PAD; i++) begin
			for (int k = 0; k < K_PAD; k++) begin
			$write("%6d ", ref_A[i][k]);
			end
			$write("\n");
		end

  		$display("================");

		for (int j = 0; j < N_PAD; j++)
			for (int k = 0; k < K_PAD; k += 4) begin
				mem_idx = (B_BASE >> 4) + j * (K_PAD / 4) + k / 4;
				mem_model[mem_idx] = pack_row(
					32'(ref_BT[j][k+0]), 32'(ref_BT[j][k+1]),
					32'(ref_BT[j][k+2]), 32'(ref_BT[j][k+3]));
			end

		$display("=== B MATRIX ===");
		for (int i = 0; i < M_PAD; i++) begin
			for (int k = 0; k < K_PAD; k ++) begin
				$write("%6d ", ref_BT[i][k]);
			end
			$write("\n");
		end
		$display("================");

		$display("[TB] A (%0d x %0d) at 0x%08x  B^T (%0d x %0d) at 0x%08x",
			M, K, A_BASE, N, K, B_BASE);
		$display("[TB] C (%0d x %0d) at 0x%08x  strides A/B=%0d  C=%0d bytes",
			M, N, C_BASE, A_STRIDE, C_STRIDE);

		//===========================================================
		// Reset
		//===========================================================

		repeat (6) @(posedge clk_i);
		rst_ni = 1'b1;
		repeat (4) @(posedge clk_i);

		//===========================================================
		// Gustavson tiled dense MatMul
		//
		//  for m in 0..M_PAD  step 8
		//    for n in 0..N_PAD  step 8
		//      mzero m4..m7
		//      for k in 0..K_PAD  step 4
		//        m0 = A [m:m+4,   k:k+4]  MLD_W
		//        m1 = BT[n:n+4,   k:k+4]  MLD_W
		//        m4 += m0 x m1             MMASA_W -> C[m:m+4,   n:n+4  ]
		//        m2 = A [m+4:m+8, k:k+4]  MLD_W
		//        m6 += m2 x m1             MMASA_W -> C[m+4:m+8, n:n+4  ]
		//        m3 = BT[n+4:n+8, k:k+4]  MLD_W
		//        m5 += m0 x m3             MMASA_W -> C[m:m+4,   n+4:n+8]
		//        m7 += m2 x m3             MMASA_W -> C[m+4:m+8, n+4:n+8]
		//      mst.w m4..m7 -> C
		//===========================================================

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
					b0 = B_BASE + (n       * K_PAD + k) * 4;
					b4 = B_BASE + ((n + 4) * K_PAD + k) * 4;

					issue_and_commit(enc_mld_w(3'd0), a0, A_STRIDE, next_id);
					next_id++; issued_cnt++;

					issue_and_commit(enc_mld_w(3'd1), b0, B_STRIDE, next_id);
					next_id++; issued_cnt++;
					wait (completed_results >= issued_cnt); repeat (2) @(posedge clk_i);

					issue_and_commit(enc_mmasa_w(3'd0, 3'd1, 3'd4), '0, '0, next_id);
					next_id++; issued_cnt++;

					issue_and_commit(enc_mld_w(3'd2), a4, A_STRIDE, next_id);
					next_id++; issued_cnt++;

					issue_and_commit(enc_mmasa_w(3'd2, 3'd1, 3'd6), '0, '0, next_id);
					next_id++; issued_cnt++;

					issue_and_commit(enc_mld_w(3'd3), b4, B_STRIDE, next_id);
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

				issue_and_commit(enc_mst_w(3'd4), c00, C_STRIDE, next_id);
				next_id++; issued_cnt++;

				issue_and_commit(enc_mst_w(3'd5), c01, C_STRIDE, next_id);
				next_id++; issued_cnt++;

				issue_and_commit(enc_mst_w(3'd6), c10, C_STRIDE, next_id);
				next_id++; issued_cnt++;

				issue_and_commit(enc_mst_w(3'd7), c11, C_STRIDE, next_id);
				next_id++; issued_cnt++;
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

		for (int i = 0; i < M_PAD; i++)
			for (int j = 0; j < N_PAD; j += 4) begin
				mem_idx = (C_BASE >> 4) + i * (N_PAD / 4) + j / 4;
				dut_C[i][j+0] = $signed(mem_model[mem_idx][ 31: 0]);
				dut_C[i][j+1] = $signed(mem_model[mem_idx][ 63:32]);
				dut_C[i][j+2] = $signed(mem_model[mem_idx][ 95:64]);
				dut_C[i][j+3] = $signed(mem_model[mem_idx][127:96]);
			end

		$display("\n[TB] C (%0d x %0d)  DUT | REF", M, N);
		for (int i = 0; i < M; i++) begin
			for (int j = 0; j < N; j++) $write(" %6d", $signed(dut_C[i][j]));
			$write("  |");
			for (int j = 0; j < N; j++) $write(" %6d", $signed(ref_C[i][j]));
			$display("");
		end

		errors = 0;
		for (int i = 0; i < M; i++)
			for (int j = 0; j < N; j++)
				if (dut_C[i][j] !== ref_C[i][j]) begin
					$display("[ERROR] C[%0d][%0d]: DUT=%0d  REF=%0d",
						i, j, $signed(dut_C[i][j]), $signed(ref_C[i][j]));
					errors++;
				end

		if (errors == 0)
			$display("\n[TB] PASS -- all %0d elements correct.", M*N);
		else
			$display("\n[TB] FAIL -- %0d mismatches.", errors);

		$finish;
	end

	initial begin
		#(TIMEOUT_NS * 1ns);
		$fatal(1, "[TB] Timeout after %0d ns.", TIMEOUT_NS);
	end

endmodule
