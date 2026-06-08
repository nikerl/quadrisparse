// Copyright 2024 EPFL
// Solderpad Hardware License, Version 2.1, see LICENSE.md for details.
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// Author: Oskar Swärd

module spmac_grid_4x4_pipeline #(
    parameter  int MESH_WIDTH = 4,
    parameter  int DATA_WIDTH = 32,
    localparam int RLEN       = MESH_WIDTH * DATA_WIDTH
) (
    input  logic                                                    clk_i    ,
    input  logic                                                    rst_ni   ,
    input  logic                                                    enable_i ,
    input  logic                                                    clear_i  ,
    input  logic [MESH_WIDTH-1:0][DATA_WIDTH-1:0]                  data_i   ,
    input  logic [MESH_WIDTH-1:0][MESH_WIDTH-1:0][DATA_WIDTH-1:0]  weight_i ,
    input  logic [RLEN-1:0]                                         acc_i    ,
    output logic [RLEN-1:0]                                         result_o
);

  logic [MESH_WIDTH-1:0][MESH_WIDTH-1:0][DATA_WIDTH-1:0] psum;

  generate
    for (genvar row = 0; row < MESH_WIDTH; row++) begin : gen_row
      for (genvar col = 0; col < MESH_WIDTH; col++) begin : gen_col

        if (row == 0) begin : gen_row0
          mac_stage #(.DATA_WIDTH(DATA_WIDTH)) u_mac (
            .clk_i,
            .rst_ni,
            .enable_i,
            .clear_i,
            .data_i    (data_i[row]      ),
            .weight_i  (weight_i[row][col]),
            .psum_in_i ('0               ),
            .psum_out_o(psum[row][col]   )
          );
        end else begin : gen_rown
          mac_stage #(.DATA_WIDTH(DATA_WIDTH)) u_mac (
            .clk_i,
            .rst_ni,
            .enable_i,
            .clear_i,
            .data_i    (data_i[row]       ),
            .weight_i  (weight_i[row][col] ),
            .psum_in_i (psum[row-1][col]  ),
            .psum_out_o(psum[row][col]    )
          );
        end

      end
    end
  endgenerate

  assign result_o = psum[MESH_WIDTH-1] + acc_i;

endmodule
