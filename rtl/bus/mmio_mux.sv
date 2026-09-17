///////////////////////////////////////////////////////////////////////////////
//     Copyright (c) 2025 Siliscale Consulting, LLC
//     Licensed under the Apache License, Version 2.0 (the "License");
///////////////////////////////////////////////////////////////////////////////
// MMIO device mux: range-decode LSU stores against the generated SoC map
// (`mmio_map.svh` from hw/soc/*.yaml). Hits are steered off DCCM; per-device
// write strobes are exported for UART/EOT/accelerators.

`ifndef GLOBAL_SVH
`include "global.svh"
`endif

`ifndef MMIO_MAP_SVH
`include "mmio_map.svh"
`endif

module mmio_mux #(
    parameter int NPORTS = LSU_DCCM_PORT_COUNT,
    parameter int NDEVS  = MMIO_DEV_COUNT
) (
    input  logic [XLEN-1:0] addr     [NPORTS-1:0],
    input  logic            wen      [NPORTS-1:0],
    input  logic [XLEN-1:0] wdata    [NPORTS-1:0],

    /* DCCM write enables with MMIO ranges stripped */
    output logic            mem_wen  [NPORTS-1:0],

    /* One write port per mapped device (OR of LSU ports; last hit wins data) */
    output logic            dev_we    [NDEVS-1:0],
    output logic [XLEN-1:0] dev_addr  [NDEVS-1:0],
    output logic [XLEN-1:0] dev_wdata [NDEVS-1:0]
);

  function automatic logic mmio_addr_hit(
      input logic [31:0] a,
      input int unsigned idx
  );
    return (a >= MMIO_DEV_BASE[idx]) && (a < (MMIO_DEV_BASE[idx] + MMIO_DEV_SIZE[idx]));
  endfunction

  function automatic logic mmio_any_hit(input logic [31:0] a);
    mmio_any_hit = 1'b0;
    for (int unsigned i = 0; i < NDEVS; i++) begin
      if (mmio_addr_hit(a, i)) begin
        mmio_any_hit = 1'b1;
      end
    end
  endfunction

  int unsigned p, d;

  always_comb begin
    for (p = 0; p < NPORTS; p++) begin
      mem_wen[p] = wen[p] & ~mmio_any_hit(addr[p]);
    end
    for (d = 0; d < NDEVS; d++) begin
      dev_we[d]    = 1'b0;
      dev_addr[d]  = '0;
      dev_wdata[d] = '0;
      for (p = 0; p < NPORTS; p++) begin
        if (wen[p] && mmio_addr_hit(addr[p], d)) begin
          dev_we[d]    = 1'b1;
          dev_addr[d]  = addr[p];
          dev_wdata[d] = wdata[p];
        end
      end
    end
  end

endmodule
