module exu_test_gen;
  generate
    if (1) begin
      alu alu_inst (.clk(1'b0), .rstn(1'b0), .alu_ctrl('0), .alu_wb_data(), .alu_wb_rd_addr(), .alu_wb_rd_wr_en(), .instr_tag_out(), .instr_out(), .pc_out(), .pc_load());
    end
  endgenerate
endmodule
