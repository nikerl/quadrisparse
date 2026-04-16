// Copyright 2026
// Solderpad Hardware License, Version 2.1,see LICENSE.md for details.
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// Author: Nik Erlandsson
// Author: Oskar Swärd


//===========================================================================
// 							  Utility functions
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
