// Copyright 2024 EPFL
// Solderpad Hardware License, Version 2.1, see LICENSE.md for details.
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// Author: Oskar Swärd

module mac_stage #(
    parameter int DATA_WIDTH = 32
) (
    input  logic                  clk_i     ,
    input  logic                  rst_ni    ,
    input  logic                  enable_i  ,
    input  logic                  clear_i   ,
    input  logic [DATA_WIDTH-1:0] data_i    ,
    input  logic [DATA_WIDTH-1:0] weight_i  ,
    input  logic [DATA_WIDTH-1:0] psum_in_i ,
    output logic [DATA_WIDTH-1:0] psum_out_o
);

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni || clear_i)
      psum_out_o <= '0;
    else if (enable_i)
      psum_out_o <= psum_in_i + data_i * weight_i;
  end

endmodule
