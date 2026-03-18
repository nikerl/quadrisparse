// Copyright 2024 EPFL
// Solderpad Hardware License, Version 2.1, see LICENSE.md for details.
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// Author: Oskar Swärd

module quadrilatero_spld #(
    parameter int N_REGS = 8,
    parameter int DATA_WIDTH = 32
)(
    input  logic                    clk_i,
    input  logic                    rst_ni,

    // Instruction inputs
    input  logic [xif_pkg::X_ID_WIDTH-1:0] instr_id_i,
    input  logic [xif_pkg::X_NUM_RS-1:0][xif_pkg::X_RFR_WIDTH-1:0] rs_i,
    input  logic [xif_pkg::X_NUM_RS-1:0] rs_valid_i,
    input  logic instr_valid_i,

    input  logic [$clog2(N_REGS)-1:0] dest_reg_i,       // destination matrix register
    input  logic [$clog2(N_REGS)-1:0] num_elements_i,   // number of non-zero elements in this row

    // LSU interface
    output logic                     lsu_start_o,
    output logic [31:0]              lsu_addr_o,
    input  logic                     lsu_busy_i,
    input  logic [DATA_WIDTH-1:0]    lsu_data_i,
    input  logic                     lsu_valid_i,

    // Outputs to dispatcher / RF
    output logic [N_REGS-1:0]        rf_push_o,
    output logic [DATA_WIDTH-1:0]    rf_data_o,
    output logic                     instr_done_o
);

    //------------------------------------------------------------------------------  
    // States
    typedef enum logic [1:0] {
        IDLE,
        REQUEST,
        LOAD_DATA,
        DONE
    } spld_state_e;

    spld_state_e state_q, state_d;

    // Internal counters
    logic [$clog2(N_REGS)-1:0] count_q, count_d;

    //------------------------------------------------------------------------------  
    // Next-state logic
    always_comb begin
        state_d = state_q;
        count_d = count_q;

        case(state_q)
            IDLE: begin
                if(instr_valid_i) begin
                    state_d = REQUEST;
                    count_d = 0;
                end
            end

            REQUEST: begin
                if(!lsu_busy_i) begin
                    state_d = LOAD_DATA;
                end
            end

            LOAD_DATA: begin
                if(lsu_valid_i) begin
                    if(count_q + 1 >= num_elements_i) begin
                        state_d = DONE;
                    end
                    count_d = count_q + 1;
                end
            end

            DONE: begin
                state_d = IDLE;
            end
        endcase
    end

    //------------------------------------------------------------------------------  
    // Output logic
    always_comb begin
        lsu_start_o = 0;
        lsu_addr_o  = 0;
        rf_push_o   = '0;
        rf_data_o   = '0;
        instr_done_o = 0;

        case(state_q)
            REQUEST: begin
                lsu_start_o = 1;
                lsu_addr_o  = 32'h0000_0000; // placeholder, to be calculated from base + offset
            end

            LOAD_DATA: begin
                if(lsu_valid_i) begin
                    rf_push_o[dest_reg_i] = 1'b1;
                    rf_data_o = lsu_data_i;
                end
            end

            DONE: begin
                instr_done_o = 1'b1;
            end
        endcase
    end

    //------------------------------------------------------------------------------  
    // Sequential logic
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if(!rst_ni) begin
            state_q <= IDLE;
            count_q <= 0;
        end else begin
            state_q <= state_d;
            count_q <= count_d;
        end
    end

endmodule