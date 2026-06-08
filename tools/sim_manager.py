#!/usr/bin/env python3

# Copyright (c) 2025 Siliscale Consulting, LLC
# SPDX-License-Identifier: Apache-2.0


import argparse
import json
import sys
import os
from pathlib import Path
from typing import List, Optional

_REPO_ROOT = Path(__file__).resolve().parents[1]
if str(_REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(_REPO_ROOT))

from hw import HwConfig, default_hw_config_path, load_hw_config
from hw.rtl_config import write_hw_config_svh
from elftools.elf.elffile import ELFFile
import subprocess
import shutil
import concurrent.futures
import multiprocessing
import threading
import traceback
from tqdm import tqdm

_console_lock = threading.Lock()


def safe_write(msg: str) -> None:
    """Thread-safe console output that does not corrupt tqdm bars."""
    with _console_lock:
        tqdm.write(msg)

IMEM_DEPTH = 2 ** 18
DMEM_DEPTH = 2 ** 18


def _write_hw_config_artifact(test: str, hw_config: HwConfig) -> None:
    out_path = os.path.join("work", test, "hw_config.json")
    with open(out_path, "w", encoding="utf-8") as f:
        json.dump(hw_config.to_dict(), f, indent=2)


def _pyvedas_python() -> str:
    """Pick a Python interpreter that can run the PyVedas JIT."""
    candidates = [
        os.path.join("pyvedas", ".venv", "bin", "python3"),
        os.path.join("venv", "bin", "python3"),
        "python3",
    ]
    for candidate in candidates:
        if candidate == "python3" or os.path.isfile(candidate):
            return candidate
    return "python3"


def _compile_riscv_elf(test: str, sources: List[str], include_dirs: List[str]) -> int:
    """Link *sources* into work/<test>/test.elf. Returns the reset vector."""
    compile_log = os.path.join("work", test, "compile.log")
    inc_flags = " ".join(f"-I{inc}" for inc in include_dirs)
    source_list = " ".join(sources)
    cmd = (
        f"riscv64-unknown-elf-gcc -O0 {inc_flags} "
        f"-march=rv32im -mabi=ilp32 -nostdlib -o work/{test}/test.elf "
        f"-fno-builtin-printf -fno-common -falign-functions=4 "
        f"{source_list} -lgcc "
        f"-Wl,-Ttext=0x100000 -Wl,--defsym,_start=main "
        f"> {compile_log} 2>&1"
    )
    if os.system(cmd) != 0:
        raise RuntimeError(f"RISC-V compile failed for {test}; see {compile_log}")

    elf_path = os.path.join("work", test, "test.elf")
    with open(elf_path, "rb") as f:
        elf = ELFFile(f)
        symtab = elf.get_section_by_name('.symtab')
        if symtab is None:
            raise RuntimeError("No symbol table found in ELF file")
        for symbol in symtab.iter_symbols():
            if symbol.name == "_start":
                return symbol['st_value']
    raise RuntimeError("Could not find _start symbol in ELF file")


def run_gen(test: str, hw_config: HwConfig) -> int:
    """Run the generator for a test."""
    # Create the folder for the test
    os.makedirs(f"work/{test}", exist_ok=True)
    _write_hw_config_artifact(test, hw_config)
    test_path = test.split(".")
    extension = ""
    if test_path[0] == "c":
        extension = ".c"
    elif test_path[0] == "asm":
        extension = ".s"
    elif test_path[0] == "elf":
        extension = None
    elif test_path[0] == "pyvedas":
        extension = ".py"
    # Try and compile the test, if it fails, print the error and exit
    try:
        if extension == ".py":
            example_py = os.path.join("tests", "pyvedas", test_path[1] + ".py")
            if not os.path.exists(example_py):
                raise RuntimeError(f"PyVedas example not found: {example_py}")

            out_dir = os.path.join("work", test)
            jit_log = os.path.join(out_dir, "jit.log")
            pyvedas_python = _pyvedas_python()
            jit_cmd = (
                f"PYTHONPATH=pyvedas:{_REPO_ROOT} {pyvedas_python} -m jit "
                f"--model-spec {example_py} -o {out_dir} --target "
                f"--hw-config {hw_config.source_path} "
                f"> {jit_log} 2>&1"
            )
            if os.system(jit_cmd) != 0:
                raise RuntimeError(f"PyVedas JIT failed for {test}; see {jit_log}")

            manifest_path = os.path.join(out_dir, "manifest.json")
            with open(manifest_path, "r", encoding="utf-8") as f:
                manifest = json.load(f)

            eot_source = os.path.join("tests", "c", "asm_functions", "eot_sequence.s")
            sources = [manifest["generated_c"], eot_source, *manifest["sources"]]
            reset_vector = _compile_riscv_elf(test, sources, manifest["include_dirs"])
            os.system(
                f"riscv64-unknown-elf-objdump -D work/{test}/test.elf "
                f"> work/{test}/test.dump"
            )
            return reset_vector
        elif extension == ".s":
            os.system(f"riscv64-unknown-elf-gcc -O0 -I{os.path.join('tests', test_path[0])} -march=rv32im -mabi=ilp32 -o work/{test}/test.elf -nostdlib {os.path.join('tests', test_path[0], test_path[1] + extension)} -Wl,-Ttext=0x100000 > {os.path.join('work', test, 'compile.log')}")
        elif extension == ".c":
            c_source = os.path.join('tests', test_path[0], test_path[1] + extension)
            eot_source = os.path.join('tests', test_path[0], 'asm_functions', 'eot_sequence.s')
            printf_source = os.path.join('sw', 'vedas_printf', 'vedas_printf.c')
            sources = [c_source, eot_source]
            if test_path[1] == 'helloworld':
                sources.insert(1, printf_source)
            include_dirs = [os.path.join('tests', test_path[0])]
            reset_vector = _compile_riscv_elf(test, sources, include_dirs)
            return reset_vector
        else:
            os.system(f"cp {os.path.join('tests', test_path[0], test_path[1])} work/{test}/test.elf")

        os.system(f"riscv64-unknown-elf-objdump -D work/{test}/test.elf > work/{test}/test.dump")

        elf_path = os.path.join("work", test, "test.elf")
        with open(elf_path, "rb") as f:
            elf = ELFFile(f)
            symtab = elf.get_section_by_name('.symtab')
            if symtab is None:
                raise RuntimeError("No symbol table found in ELF file")
            for symbol in symtab.iter_symbols():
                if symbol.name == "_start":
                    return symbol['st_value']
            raise RuntimeError("Could not find _start symbol in ELF file")
    except Exception as e:
        print(f"Error compiling test {test}: {e}")
        sys.exit(1)

def run_iss(test: str, reset_vector: int) -> None:
    """Run the ISS for a test."""
    # Create the folder for the test
    elf_path = os.path.join("work", test, "test.elf")
    # Check if I have a memory initialization file for this test
    test_path = test.split(".")
    dmem_path = os.path.join("tests", test_path[0], test_path[1] + ".mem")
    has_dmem = os.path.exists(dmem_path)
    if has_dmem:
        # Copy the file in the work directory
        shutil.copy(dmem_path, os.path.join("work", test, "dmem.hex"))
    # try and run the ISS
    try:
        import subprocess
        cmd = ""
        if has_dmem:
            cmd = f"python3 ./tools/rv_iss.py {elf_path} {hex(reset_vector)} 0x7FFFF000 0x1000 -o {os.path.join('work', test, 'iss.log')} -m {os.path.join('work', test, 'dmem.hex')}"
        else:
            cmd = f"python3 ./tools/rv_iss.py {elf_path} {hex(reset_vector)} 0x7FFFF000 0x1000 -o {os.path.join('work', test, 'iss.log')}"
        result = subprocess.run(cmd, shell=True)
        if result.returncode != 0:
            print(f"ISS returned error code {result.returncode} for test {test}. See iss.log for details.")
            sys.exit(1)
    except Exception as e:
        print(f"Error running ISS for test {test}: {e}")
        sys.exit(1)

def prepare_imem(test: str) -> None:
    """Prepare the IMEM for a test."""
    imem_path = os.path.join("work", test, "imem.hex")
    dmem_path = os.path.join("work", test, "dmem.hex")
    elf_path = os.path.join("work", test, "test.elf")

    test_path = test.split(".")
    
    # Read the ELF file using elftools
    with open(elf_path, 'rb') as f:
        elf = ELFFile(f)
        # Get the .text section
        text_section = elf.get_section_by_name('.text')
        if not text_section:
            print("Error: No .text section found in ELF file")
            sys.exit(1)
            
        # Read the instruction data
        imem_data = text_section.data()
        if len(imem_data) > IMEM_DEPTH:
            print(f"Warning: Instruction memory truncated to {IMEM_DEPTH} bytes")
            imem_data = imem_data[:IMEM_DEPTH]
        
        # Pad with zeros to fill IMEM_DEPTH
        if len(imem_data) < IMEM_DEPTH:
            imem_data = imem_data + b'\x00' * (IMEM_DEPTH - len(imem_data))
        
        # Build a single data memory image containing all relevant sections
        dmem_image = bytearray(b'\x00' * DMEM_DEPTH)

        # Helper to copy data from a section into dmem_image at correct offset
        def copy_section_to_dmem(section):
            if not section:
                return
            base_addr = section.header['sh_addr'] - 0x100000
            data = section.data()
            if base_addr < 0 or base_addr >= DMEM_DEPTH:
                print(f"Warning: Section {section.name} base address 0x{base_addr+0x100000:x} (offset {base_addr}) out of DMEM image range")
                return
            max_bytes = min(len(data), DMEM_DEPTH - base_addr)
            dmem_image[base_addr:base_addr+max_bytes] = data[:max_bytes]
            if len(data) > max_bytes:
                print(f"Warning: Section {section.name} truncated in DMEM file to {max_bytes} bytes")

        # Copy all relevant sections in any order; later sections may overwrite overlapping regions.
        for secname in ['.data', '.rodata', '.bss', '.sdata', ".init_array", ".fini_array"]:
            sec = elf.get_section_by_name(secname)
            copy_section_to_dmem(sec)

        # Write out the merged DMEM image, 4 bytes per line, little-endian words
        with open(dmem_path, "w") as f:
            dmem_path = os.path.join("tests", test_path[0], test_path[1] + ".mem")
            has_dmem = os.path.exists(dmem_path)
            if has_dmem:
                os.system(f"cp {dmem_path} work/{test}/dmem.hex") 
            else:
                for i in range(0, DMEM_DEPTH, 4):
                    word = dmem_image[i:i+4]
                    # If less than 4 bytes (should not happen), pad with zeros
                    if len(word) < 4:
                        word = word + b'\x00' * (4 - len(word))
                    hex_str = '{:08x}'.format(int.from_bytes(word, byteorder='little'))
                    f.write(f"{hex_str}  // {hex(i)}\n")

    # Write the instruction memory as hex, 4 bytes per line
    with open(imem_path, "w") as f:
        for i in range(0, IMEM_DEPTH, 4):
            # Get 4 bytes
            word = imem_data[i:i+4]
            # Convert to hex string, removing '0x' prefix and padding to 8 chars
            hex_str = '{:08x}'.format(int.from_bytes(word, byteorder='little'))
            f.write(f"{hex_str}\n")

def read_task_list(filename: str) -> List[str]:
    """Read and return list of tests from file."""
    try:
        with open(filename, 'r') as f:
            return [line.strip() for line in f if line.strip()]
    except Exception as e:
        print(f"Error reading task list file: {e}")
        return []

def run_verilator(test: str, reset_vector: int) -> None:
    """Execute Verilator simulation."""
    has_dmem = os.path.exists(os.path.join("work", test, "dmem.hex"))
    verilator_cmd = f"export PROJ=$(pwd) && cd {os.path.join('work', test)} && verilator --cc --trace --trace-structs --build --timing --top-module core_top_tb --exe $PROJ/dv/verilator/core_top_tb.cpp -I$PROJ/rtl/include -f $PROJ/rtl/core_top.flist -DICCM_INIT_FILE='\"imem.hex\"' -DRESET_VECTOR=32\\'h{hex(reset_vector).lstrip('0x')} -DSTACK_POINTER_INIT_VALUE=32\\'h80000000"
    if has_dmem:
        verilator_cmd += f" -DDCCM_INIT_FILE='\"dmem.hex\"'"
    else:
        verilator_cmd += f" -DDCCM_INIT_FILE='\"\"'"
    verilator_cmd += f" && make -j -C obj_dir -f Vcore_top_tb.mk Vcore_top_tb"
    verilator_cmd += f" && ./obj_dir/Vcore_top_tb"
    
    # Redirect both stdout and stderr to sim.log
    sim_log_path = os.path.join('work', test, 'sim.log')
    with open(sim_log_path, 'w') as sim_log:
        process = subprocess.Popen(verilator_cmd, shell=True, stdout=sim_log, stderr=subprocess.STDOUT)
        process.wait()
        # Get the exit code
        exit_code = process.returncode
        if exit_code != 0:
            print(f"Error: Verilator returned exit code {exit_code}")
            sim_log.close()
            sys.exit(1)
    
def run_xsim(test: str, reset_vector: int) -> None:
    """Execute XSim simulation."""
    has_dmem = os.path.exists(os.path.join("work", test, "dmem.hex"))
    xsim_cmd = f"export PROJ=$(pwd) && cd {os.path.join('work', test)} && xvlog -sv -i $PROJ/rtl/include -f $PROJ/rtl/core_top.flist --define ICCM_INIT_FILE='\"imem.hex\"' --define RESET_VECTOR=32\\'h{hex(reset_vector).lstrip('0x')} --define STACK_POINTER_INIT_VALUE=32\\'h80000000"
    if has_dmem:
        xsim_cmd += f" --define DCCM_INIT_FILE='\"dmem.hex\"'"
    else:
        xsim_cmd += f" --define DCCM_INIT_FILE='\"\"'"
    xsim_cmd += f" && xelab -top core_top_tb -snapshot sim --debug wave && xsim sim --runall"
    
    # Redirect both stdout and stderr to sim.log
    sim_log_path = os.path.join('work', test, 'sim.log')
    with open(sim_log_path, 'w') as sim_log:
        process = subprocess.Popen(xsim_cmd, shell=True, stdout=sim_log, stderr=subprocess.STDOUT)
        process.wait()
        # Get the exit code
        exit_code = process.returncode
        if exit_code != 0:
            print(f"Error: XSim returned exit code {exit_code}")
            sim_log.close()
            sys.exit(1)

def read_iss_log(test: str):
    """Read and parse ISS log file."""
    with open(os.path.join("work", test, "iss.log"), "r") as f:
        iss_log = f.read()
    iss_exe = []
    for line in iss_log.split("\n"):
        if line != "":
            line = line.split(";") 
            iss_exe.append({
                'pc': line[0],
                'instr': line[1],
                'mnemonic': line[2],
                'touch': line[3:]
            })
    return iss_exe

def read_rtl_log(test: str):
    """Read and parse RTL log file."""
    with open(os.path.join("work", test, "rtl.log"), "r") as f:
        rtl_log = f.read()
    rtl_exe = []
    for line in rtl_log.split("\n"):
        if line != "":
            line = line.split(";")
            rtl_exe.append({
                'pc': line[1],
                'instr': line[2],
                'touch': line[3:]
            })
    return rtl_exe

def compare_results(test: str, show_progress: bool = True) -> None:
    # Read both log files in parallel using threads
    try:
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as executor:
            iss_future = executor.submit(read_iss_log, test)
            rtl_future = executor.submit(read_rtl_log, test)
            
            # Wait for both to complete
            iss_exe = iss_future.result()
            rtl_exe = rtl_future.result()

        # Compare the logs
        test_passed = True
        sim_log_path = os.path.join('work', test, 'sim.log')
        with open(sim_log_path, 'a') as sim_log:
            indices = range(len(iss_exe))
            pbar = tqdm(
                indices,
                desc=f"Comparing {test}",
                unit="instr",
                ncols=100,
                leave=False,
                disable=not show_progress,
            )
            for iss_idx in pbar:
                if str(iss_exe[iss_idx]['pc']).upper() != str(rtl_exe[iss_idx]['pc']).upper():
                    sim_log.write(f"Error: PC Mismatch at PC {iss_exe[iss_idx]['pc']}\n")
                    sim_log.write(f"ISS: {iss_exe[iss_idx]['pc']}\n")
                    sim_log.write(f"RTL: {rtl_exe[iss_idx]['pc']}\n")
                    test_passed = False
                elif str(iss_exe[iss_idx]['instr']).upper() != str(rtl_exe[iss_idx]['instr']).upper():
                    sim_log.write(f"Error: Instruction mismatch at PC {iss_exe[iss_idx]['pc']}\n")
                    sim_log.write(f"ISS: {iss_exe[iss_idx]['instr']}\n")
                    sim_log.write(f"RTL: {rtl_exe[iss_idx]['instr']}\n")
                    test_passed = False
                # Diffetent lenght of touch
                elif len(iss_exe[iss_idx]['touch']) != len(rtl_exe[iss_idx]['touch']):
                    sim_log.write(f"Error: Result mismatch at PC {iss_exe[iss_idx]['pc']} for instruction --> {iss_exe[iss_idx]['mnemonic']}\n")
                    sim_log.write(f"ISS: {iss_exe[iss_idx]['touch']}\n")
                    sim_log.write(f"RTL: {rtl_exe[iss_idx]['touch']}\n")
                    test_passed = False
                # Same length, check each element
                else:
                    for touch_idx in range(len(iss_exe[iss_idx]['touch'])):
                        # Remove comments after '//' from ISS value before comparison
                        iss_touch = str(iss_exe[iss_idx]['touch'][touch_idx])
                        iss_touch = iss_touch.split("//")[0].strip() if "//" in iss_touch else iss_touch
                        rtl_touch = str(rtl_exe[iss_idx]['touch'][touch_idx])
                        if iss_touch.upper() != rtl_touch.upper():
                            sim_log.write(f"Error: Result mismatch at PC {iss_exe[iss_idx]['pc']} for instruction --> {iss_exe[iss_idx]['mnemonic']}\n")
                            sim_log.write(f"ISS: {iss_exe[iss_idx]['touch'][touch_idx]}\n")
                            sim_log.write(f"RTL: {rtl_exe[iss_idx]['touch'][touch_idx]}\n")
                            test_passed = False
                if not test_passed:
                    break
    except:
        test_passed = False

    status = "\033[92mPASSED\033[0m" if test_passed else "\033[91mFAILED\033[0m"
    safe_write(f"{test} {'.' * (50 - len(test))}. {status}")

def process_rtl_log(test: str, show_progress: bool = True):
    """Process the RTL log file."""
    with open(os.path.join("work", test, "rtl.log"), "r") as f:
        rtl_lines = f.readlines()
    
    # Remove newlines and filter empty lines
    rtl_lines = [line.rstrip('\n') for line in rtl_lines if line.strip()]
    total_lines = len(rtl_lines) - 1
    line_idx = 0
    pbar = tqdm(
        total=total_lines,
        desc=f"Processing RTL log {test}",
        unit="line",
        leave=False,
        ncols=100,
        disable=not show_progress,
    )

    while line_idx < total_lines:
        if line_idx + 1 >= len(rtl_lines):
            break
            
        line_parts = rtl_lines[line_idx].split(";")
        nxt_line_parts = rtl_lines[line_idx + 1].split(";")
        
        # Check if we need to merge (same PC and instruction, both have memory effects)
        if (len(line_parts) > 3 and len(nxt_line_parts) > 3 and 
            line_parts[1] == nxt_line_parts[1] and 
            line_parts[2] == nxt_line_parts[2] and
            "mem[" in line_parts[3] and "mem[" in nxt_line_parts[3]):
            
            effect = line_parts[3]
            nxt_effect = nxt_line_parts[3]
            
            # Get the memory address
            mem_addr = effect.split("[")[1].split("]")[0]
            alignment = int(mem_addr, 16) % 4
            
            # For unaligned stores, we need to merge the two parts
            # First part is the lower bytes (at higher address)
            # Second part is the higher bytes (at lower address)
            # For example, storing 0xCAFEBABE at 0xE:
            # First store: mem[0xE]=0xBABE (lower 2 bytes)
            # Second store: mem[0x10]=0xCAFE (higher 2 bytes)
            # We need to merge them to get: mem[0xE]=0xCAFEBABE
            lower_bytes = effect.split("=")[1].lstrip("0x")[:8-alignment*2]
            higher_bytes = nxt_effect.split("=")[1].lstrip("0x")[:8-alignment*2]
            
            # Combine them to get the full value
            merged_value = higher_bytes + lower_bytes
            
            # Update the current line with merged value
            rtl_lines[line_idx] = f"{line_parts[0]};{line_parts[1]};{line_parts[2]};mem[{mem_addr}]=0x{merged_value}"
            
            # Remove the next line
            del rtl_lines[line_idx + 1]
            total_lines -= 1
            line_idx += 1
        else:
            line_idx += 1
        
        if show_progress:
            pbar.update(1)

    # Write the updated rtl_log
    with open(os.path.join("work", test, "rtl.log"), "w") as f:
        f.write("\n".join(rtl_lines))

def calculate_perf_stats(test: str):
    # Open the rtl log file for this test
    rtl_log_path = os.path.join("work", test, "rtl.log")
    with open(rtl_log_path, "r") as f:
        rtl_lines = f.readlines()
    # Get the first line of the rtl log
    first_line = rtl_lines[0].split(";")
    # Get The last line of the rtl log
    last_line = rtl_lines[-1].split(";")
    # The number of instructions is how many lines in the RTL log we have
    num_instructions = len(rtl_lines)
    # The number of cycles is the difference between the last line and the first line
    num_cycles = int(last_line[0]) - int(first_line[0])
    # The number of cycles per instruction is the number of cycles divided by the number of instructions
    cycles_per_instruction = num_cycles / num_instructions
    # The number of instructions per cycle is the number of instructions divided by the number of cycles
    instructions_per_cycle = num_instructions / num_cycles

    # Prepare the performance stats as a pretty table
    headers = ["Metric", "Value"]
    rows = [
        ["Number of instructions", num_instructions],
        ["Number of cycles", num_cycles],
        ["Cycles per instruction", f"{cycles_per_instruction:.4f}"],
        ["Instructions per cycle", f"{instructions_per_cycle:.4f}"]
    ]

    col_width_0 = max(len(headers[0]), max(len(str(row[0])) for row in rows))
    col_width_1 = max(len(headers[1]), max(len(str(row[1])) for row in rows))

    table_lines = []
    table_lines.append(f"{headers[0]:<{col_width_0}} | {headers[1]:<{col_width_1}}")
    table_lines.append(f"{'-'*col_width_0}-+-{'-'*col_width_1}")
    for row in rows:
        table_lines.append(f"{row[0]:<{col_width_0}} | {row[1]:<{col_width_1}}")
    table_str = "\n".join(table_lines)

    # Write the table to 'stats.txt' in the test's folder
    stats_path = os.path.join("work", test, "stats.txt")
    with open(stats_path, "w") as stats_file:
        stats_file.write(table_str)

def run_e2e(
    test: str,
    simulator: str,
    hw_config: HwConfig,
    show_progress: bool = True,
):
    """Run a test through the entire pipeline."""
    try:
        reset_vector = run_gen(test, hw_config)
        run_iss(test, reset_vector)
        prepare_imem(test)
        if simulator == "verilator":
            run_verilator(test, reset_vector)
        else:
            run_xsim(test, reset_vector)
        process_rtl_log(test, show_progress=show_progress)
        compare_results(test, show_progress=show_progress)
        calculate_perf_stats(test)
    except Exception as e:
        print(f"Error running test {test}: {e}")
        print(traceback.format_exc())
        sys.exit(1)

def main():
    # Parse arguments
    parser = argparse.ArgumentParser(
        description="Simulation Manager for running tests with different simulators"
    )
    
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("-t", "--task-list", help="Path to the task list file")
    group.add_argument("-n", "--test-name", help="Name of the test to run")
    
    parser.add_argument(
        "-s", "--simulator",
        required=True,
        choices=["verilator", "xsim"],
        help="Name of the simulator to use"
    )
    parser.add_argument(
        "--hw-config",
        default=str(default_hw_config_path()),
        help="Hardware preset YAML (cpu/vector/memory/software contract)",
    )

    args = parser.parse_args()
    hw_config = load_hw_config(args.hw_config)
    write_hw_config_svh(_REPO_ROOT / "rtl" / "include" / "hw_config.svh", hw_config)
    safe_write(f"Hardware preset: {hw_config.name} ({hw_config.cpu.kind.value})")
    
    # Create work directory
    os.makedirs("work", exist_ok=True)
    
    # Get list of tests to run
    tests = []
    if args.task_list:
        if not os.path.exists(args.task_list):
            print(f"Error: Task list file '{args.task_list}' not found")
            sys.exit(1)
        tests = read_task_list(args.task_list)
        if not tests:
            print("Error: No valid tests found in task list")
            sys.exit(1)
    else:
        tests = [args.test_name]
    
    # Get number of CPU cores
    num_cores = multiprocessing.cpu_count()
    parallel = len(tests) > 1
    show_progress = not parallel

    # Run tests in parallel using thread pool
    with concurrent.futures.ThreadPoolExecutor(max_workers=num_cores) as executor:
        future_to_test = {
            executor.submit(run_e2e, test, args.simulator, hw_config, show_progress): test
            for test in tests
        }

        desc = os.path.basename(args.task_list) if args.task_list else "tests"
        suite_pbar = tqdm(
            total=len(tests),
            desc=f"Running {desc}",
            unit="test",
            ncols=100,
            disable=not parallel,
        )

        failed = []
        for future in concurrent.futures.as_completed(future_to_test):
            test = future_to_test[future]
            try:
                future.result()
            except Exception as e:
                failed.append(test)
                safe_write(f"Error running test {test}: {e}")
            if parallel:
                suite_pbar.update(1)

        if parallel:
            suite_pbar.close()

        if failed:
            safe_write(f"\n{len(failed)} test(s) failed: {', '.join(failed)}")
            sys.exit(1)

if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        print(f"Fatal error: {e}")
        sys.exit(1)
