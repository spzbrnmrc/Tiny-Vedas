# Third-party software

Tiny-Vedas **ships** Apache 2.0 RTL, decode tables, runtime libraries, and
PyVedas tooling. The items below are used **only during development,
simulation, or host-side compilation** unless you explicitly redistribute them.

## Shipped / forked into your product

| Component | Location | License | Notes |
|-----------|----------|---------|--------|
| Tiny-Vedas RTL | `rtl/` | Apache-2.0 | Siliscale |
| SVLib | `SVLib/` (submodule) | Apache-2.0 | Siliscale |
| open-decode-tables | `open-decode-tables/` (submodule) | Apache-2.0 | Generated decode in `rtl/idu/` |
| PyVedas runtime | `pyvedas/runtime/` | Apache-2.0 | Linked into target ELFs |
| vedas_printf | `sw/vedas_printf/` | Apache-2.0 | Optional bare-metal printf |

Attribution requirements for Apache 2.0 are summarized in [NOTICE](NOTICE) and
[LICENSE](LICENSE).

## Development and simulation only

| Tool | Used for | Typical license | Shipped? |
|------|----------|-----------------|----------|
| [Verilator](https://www.veripool.org/verilator/) | RTL simulation | GPL-3.0 | No |
| [riscv-gnu-toolchain](https://github.com/riscv-collab/riscv-gnu-toolchain) | Cross-compile test ELFs | GPL (compiler runtime via `-lgcc`) | No (toolchain); yes for libgcc linked into ELFs — standard bare-metal practice |
| [Python](https://www.python.org/) | ISS, sim_manager, PyVedas JIT | PSF | No |
| [PyTorch](https://pytorch.org/) | PyVedas graph import (host) | BSD-style | No |
| [pyelftools](https://github.com/eliben/pyelftools) | ELF parsing in sim_manager | Public domain / MIT-like | No |
| [tqdm](https://github.com/tqdm/tqdm) | sim_manager progress | MPL-2.0 / MIT | No |
| [PyYAML](https://pyyaml.org/) | ops.yaml, hw presets | MIT | No |
| [XSim](https://www.xilinx.com/) (optional) | RTL simulation | Proprietary Xilinx | No |

Prebuilt RISC-V toolchains from [riscv-collab releases](https://github.com/riscv-collab/riscv-gnu-toolchain/releases)
are installed by `make deps` into `.local/riscv/`.

## Generated artifacts

| Artifact | Produced by | License follows |
|----------|-------------|-----------------|
| `rtl/idu/rv32im_decoder.sv` | open-decode-tables | Apache-2.0 (source generator + tables) |
| `work/*/generated.c` | PyVedas JIT | Apache-2.0 (generator + runtime ops) |
| `work/*/test.elf` | riscv-gcc + test sources | Apache-2.0 test/runtime sources |

## Submodule updates

When updating git submodules, verify their `LICENSE` files have not changed in a
way that conflicts with your product policy. Both current submodules use
Apache 2.0.
