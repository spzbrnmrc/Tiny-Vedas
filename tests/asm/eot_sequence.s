    .include "soc_defines.inc"
    li x31, MMIO_EOT_ADDR
    li x30, EOT_MAGIC
    sw x30, 0(x31)
1:  j 1b
