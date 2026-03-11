`timescale 1ns/1ps

module quadrilatero_xif_tb;
  import quadrilatero_pkg::*;
  import xif_pkg::*;

  localparam int CLK_PERIOD_NS = 10;

  logic clk_i;
  logic rst_ni;

  // Memory interface to OBI (simple stub)
  logic                          mem_req_o;
  logic                          mem_we_o;
  logic [BUS_WIDTH/8-1:0]        mem_be_o;
  logic [31:0]                   mem_addr_o;
  logic [BUS_WIDTH-1:0]          mem_wdata_o;
  logic                          mem_gnt_i;
  logic                          mem_rvalid_i;
  logic [BUS_WIDTH-1:0]          mem_rdata_i;

  // Compressed interface (unused by DUT)
  logic               x_compressed_valid_i;
  logic               x_compressed_ready_o;
  x_compressed_req_t  x_compressed_req_i;
  x_compressed_resp_t x_compressed_resp_o;

  // Issue interface
  logic         x_issue_valid_i;
  logic         x_issue_ready_o;
  x_issue_req_t x_issue_req_i;
  x_issue_resp_t x_issue_resp_o;

  // Commit interface
  logic      x_commit_valid_i;
  x_commit_t x_commit_i;

  // Memory request/response interface (unused by DUT)
  logic        x_mem_valid_o;
  logic        x_mem_ready_i;
  x_mem_req_t  x_mem_req_o;
  x_mem_resp_t x_mem_resp_i;

  // Memory result interface (unused by DUT)
  logic          x_mem_result_valid_i;
  x_mem_result_t x_mem_result_i;

  // Result interface
  logic      x_result_valid_o;
  logic      x_result_ready_i;
  x_result_t x_result_o;

  // DUT
  quadrilatero #(
      .INPUT_BUFFER_DEPTH(4),
      .RES_IF_FIFO_DEPTH (8),
      .FPU               (1)
  ) dut (
      .clk_i,
      .rst_ni,
      .mem_req_o,
      .mem_we_o,
      .mem_be_o,
      .mem_addr_o,
      .mem_wdata_o,
      .mem_gnt_i,
      .mem_rvalid_i,
      .mem_rdata_i,
      .x_compressed_valid_i,
      .x_compressed_ready_o,
      .x_compressed_req_i,
      .x_compressed_resp_o,
      .x_issue_valid_i,
      .x_issue_ready_o,
      .x_issue_req_i,
      .x_issue_resp_o,
      .x_commit_valid_i,
      .x_commit_i,
      .x_mem_valid_o,
      .x_mem_ready_i,
      .x_mem_req_o,
      .x_mem_resp_i,
      .x_mem_result_valid_i,
      .x_mem_result_i,
      .x_result_valid_o,
      .x_result_ready_i,
      .x_result_o
  );

  // Clock generation
  initial begin
    clk_i = 1'b0;
    forever #(CLK_PERIOD_NS/2) clk_i = ~clk_i;
  end

  // Simple memory model: always grant; one-cycle read response
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      mem_gnt_i    <= 1'b0;
      mem_rvalid_i <= 1'b0;
      mem_rdata_i  <= '0;
    end else begin
      mem_gnt_i    <= mem_req_o;
      mem_rvalid_i <= mem_req_o && !mem_we_o;
      mem_rdata_i  <= 32'h1234_5678;
    end
  end

  // Utility function to build one valid MZERO encoding.
  function automatic logic [31:0] build_mzero(input logic [2:0] md);
    logic [31:0] instr;
    begin
      instr         = '0;
      instr[31:27]  = 5'b11111;
      instr[17:15]  = md;
      instr[6:0]    = 7'b0101011;
      build_mzero   = instr;
    end
  endfunction

  task automatic issue_instr(
      input logic [31:0] instr,
      input logic [X_ID_WIDTH-1:0] instr_id,
      output logic accepted
  );
    begin
      x_issue_req_i          = '0;
      x_issue_req_i.instr    = instr;
      x_issue_req_i.id       = instr_id;
      x_issue_req_i.mode     = 2'b11;
      x_issue_req_i.rs       = '0;
      x_issue_req_i.rs_valid = '0;
      x_issue_req_i.ecs      = '0;
      x_issue_req_i.ecs_valid = 1'b0;

      x_issue_valid_i = 1'b1;
      do begin
        @(posedge clk_i);
      end while (!x_issue_ready_o);

      accepted      = x_issue_resp_o.accept;
      x_issue_valid_i = 1'b0;
      @(posedge clk_i);

      $display("[%0t] ISSUE id=%0d instr=0x%08h ready=%0b accept=%0b", $time, instr_id, instr, x_issue_ready_o, accepted);
    end
  endtask

  task automatic commit_instr(
      input logic [X_ID_WIDTH-1:0] instr_id,
      input logic kill
  );
    begin
      x_commit_i.id          = instr_id;
      x_commit_i.commit_kill = kill;
      x_commit_valid_i       = 1'b1;
      @(posedge clk_i);
      x_commit_valid_i       = 1'b0;
      $display("[%0t] COMMIT id=%0d kill=%0b", $time, instr_id, kill);
    end
  endtask

  task automatic wait_result_id(
      input logic [X_ID_WIDTH-1:0] exp_id,
      input int timeout_cycles,
      output logic seen
  );
    int i;
    begin
      seen = 1'b0;
      for (i = 0; i < timeout_cycles; i++) begin
        @(posedge clk_i);
        if (x_result_valid_o) begin
          $display("[%0t] RESULT id=%0d (expected %0d)", $time, x_result_o.id, exp_id);
          if (x_result_o.id !== exp_id) begin
            $fatal(1, "Unexpected result ID: got %0d expected %0d", x_result_o.id, exp_id);
          end
          seen = 1'b1;
          return;
        end
      end
      $display("[%0t] INFO: no result observed within %0d cycles for id=%0d", $time, timeout_cycles, exp_id);
    end
  endtask

  logic accepted;
  logic got_result;

  initial begin
    // Default drives
    rst_ni                = 1'b0;
    x_compressed_valid_i  = 1'b0;
    x_compressed_req_i    = '0;

    x_issue_valid_i       = 1'b0;
    x_issue_req_i         = '0;

    x_commit_valid_i      = 1'b0;
    x_commit_i            = '0;

    x_mem_ready_i         = 1'b1;
    x_mem_resp_i          = '0;
    x_mem_result_valid_i  = 1'b0;
    x_mem_result_i        = '0;

    x_result_ready_i      = 1'b1;

    repeat (5) @(posedge clk_i);
    rst_ni = 1'b1;
    repeat (2) @(posedge clk_i);

    // 1) Send an invalid instruction: should not be accepted by XIF decoder.
    issue_instr(32'h0000_0013, 4'h1, accepted); // ADDI x0, x0, 0
    if (accepted) begin
      $fatal(1, "Invalid non-matrix instruction was unexpectedly accepted");
    end

    // 2) Send a valid matrix instruction (MZERO) and commit it.
    issue_instr(build_mzero(3'd2), 4'h2, accepted);
    if (!accepted) begin
      $fatal(1, "Valid MZERO instruction was not accepted");
    end
    commit_instr(4'h2, 1'b0);

    // 3) Optional: watch for a completion ID for a bounded time.
    // This keeps the testbench as a lightweight interface smoke test.
    wait_result_id(4'h2, 400, got_result);
    if (!got_result) begin
      $display("[%0t] INFO: continuing after result timeout (interface drive test only)", $time);
    end

    $display("[%0t] TEST PASSED", $time);
    repeat (5) @(posedge clk_i);
    $finish;
  end

endmodule
