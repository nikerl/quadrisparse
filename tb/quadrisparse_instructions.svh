// Copyright 2026
// Solderpad Hardware License, Version 2.1,see LICENSE.md for details.
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// Author: Nik Erlandsson
// Author: Oskar Swärd


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


function automatic logic [31:0] enc_spmac_w(input logic [2:0] a_reg, input logic [2:0] b_reg, input logic [2:0] acc_reg);
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


function automatic logic [31:0] enc_mmasa_w(input logic [2:0] weight_reg, input logic [2:0] data_reg, input logic [2:0] acc_reg);
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
