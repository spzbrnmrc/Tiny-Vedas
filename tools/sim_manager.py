#!/usr/bin/env python3

import argparse
import sys
import os
from typing import List, Optional
from elftools.elf.elffile import ELFFile
import subprocess
import shutil
import concurrent.futures
import multiprocessing
import traceback

IMEM_DEPTH = 1024
DMEM_DEPTH = 1024

def run_gen(test: str) -> None:
    """Run the generator for a test."""
    # Create the folder for the test
    os.makedirs(f"work/{test}", exist_ok=True)
    test_path = test.split(".")
    extension = ""
    if test_path[0] == "c":
        extension = ".c"
    else:
         extension = ".s"
    # Try and compile the test, if it fails, print the error and exit
    try:
        if extension == ".s":
            os.system(f"riscv64-unknown-elf-gcc -O0 -I{os.path.join('tests', test_path[0])} -march=rv32im -mabi=ilp32 -o work/{test}/test.elf -nostdlib {os.path.join('tests', test_path[0], test_path[1] + extension)} -Wl,-Ttext=0x100000 > {os.path.join('work', test, 'compile.log')}")
        elif extension == ".c":
            os.system(f"riscv64-unknown-elf-gcc -O0 -I{os.path.join('tests', test_path[0])} -march=rv32im -mabi=ilp32 -o work/{test}/test.elf -nostdlib -fno-builtin-printf -fno-common -falign-functions=4 {os.path.join('tests', test_path[0], test_path[1] + extension)} {os.path.join('tests', test_path[0], 'asm_functions', 'printf.s')} {os.path.join('tests', test_path[0], 'asm_functions', 'eot_sequence.s')} -Wl,-Ttext=0x100000 > {os.path.join('work', test, 'compile.log')}")

    # Get the reset vector from the elf file --> beginning of the _start function
    # Get the reset vector (address of _start) from the ELF file
        elf_path = os.path.join("work", test, "test.elf")
        with open(elf_path, "rb") as f:
            elf = ELFFile(f)
            symtab = elf.get_section_by_name('.symtab')
            if symtab is None:
                raise RuntimeError("No symbol table found in ELF file")
            reset_vector = None
            for symbol in symtab.iter_symbols():
                if symbol.name == "_start":
                    reset_vector = symbol['st_value']
                    return reset_vector
            if reset_vector is None:
                raise RuntimeError("Could not find _start symbol in ELF file")
            # You can now use reset_vector as needed (for debugging, logging, etc.)
            # print(f"Reset vector for {test}: 0x{reset_vector:X}")
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
        if has_dmem:
            os.system(f"python3 ./tools/rv_iss.py {elf_path} {hex(reset_vector)} 0x7FFFF000 0x1000 -o {os.path.join('work', test, 'iss.log')} -m {os.path.join('work', test, 'dmem.hex')}")
        else:
            os.system(f"python3 ./tools/rv_iss.py {elf_path} {hex(reset_vector)} 0x7FFFF000 0x1000 -o {os.path.join('work', test, 'iss.log')}")
    except Exception as e:
        print(f"Error running ISS for test {test}: {e}")
        sys.exit(1)

def prepare_imem(test: str) -> None:
    """Prepare the IMEM for a test."""
    imem_path = os.path.join("work", test, "imem.hex")
    dmem_path = os.path.join("work", test, "dmem.hex")
    elf_path = os.path.join("work", test, "test.elf")
    
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
        
        # Generate the data memory from the .rodata section
        rodata_section = elf.get_section_by_name('.rodata')
        # Get the address of the .rodata section
        if rodata_section:
            rodata_new = []
            rodata_address = rodata_section.header['sh_addr']
            rodata_base_address = rodata_address - 0x100000
            rodata_data = rodata_section.data()
            if len(rodata_data) > DMEM_DEPTH:
                print(f"Warning: Data memory truncated to {DMEM_DEPTH} bytes")
                rodata_data = rodata_data[:DMEM_DEPTH]
            if rodata_base_address > 0:
                # Fill with zeros
                for i in range(rodata_base_address):
                    rodata_new.append(0)
                for i in range(len(rodata_data)):
                    rodata_new.append(rodata_data[i])
                for i in range(DMEM_DEPTH - len(rodata_new)):
                    rodata_new.append(0)
            with open(dmem_path, "w") as f:
                for i in range(0, DMEM_DEPTH, 4):
                    word = rodata_new[i:i+4]
                    hex_str = '{:08x}'.format(int.from_bytes(word, byteorder='little'))
                    f.write(f"{hex_str}\n")
            
            
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
    verilator_cmd = f"export PROJ=$(pwd) && cd {os.path.join('work', test)} && verilator --cc --trace --trace-structs --build --timing --top-module core_top_tb --exe $PROJ/dv/verilator/core_top_tb.cpp -f $PROJ/rtl/core_top.flist -DICCM_INIT_FILE='\"imem.hex\"' -DRESET_VECTOR=32\\'h{hex(reset_vector).lstrip('0x')} -DSTACK_POINTER_INIT_VALUE=32\\'h80000000"
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
    xsim_cmd = f"export PROJ=$(pwd) && cd {os.path.join('work', test)} && xvlog -sv -f $PROJ/rtl/core_top.flist --define ICCM_INIT_FILE='\"imem.hex\"' --define RESET_VECTOR=32\\'h{hex(reset_vector).lstrip('0x')} --define STACK_POINTER_INIT_VALUE=32\\'h80000000"
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

def compare_results(test: str) -> None:
    # Open the ISS log file
    try:
        with open(os.path.join("work", test, "iss.log"), "r") as f:
            iss_log = f.read()
        # Open the XSim log file
        with open(os.path.join("work", test, "rtl.log"), "r") as f:
            rtl_log = f.read()
        iss_exe = []
        rtl_exe = []
        for line in iss_log.split("\n"):
            if line != "":
                line = line.split(";") 
                iss_exe.append({
                'pc': line[0],
                'instr': line[1],
                'mnemonic': line[2],
                'touch': line[3:]
            })
        for line in rtl_log.split("\n"):
            if line != "":
                line = line.split(";")
                rtl_exe.append({
                    'pc': line[1],
                    'instr': line[2],
                    'touch': line[3:]
                })

        # Compare the logs
        test_passed = True
        sim_log_path = os.path.join('work', test, 'sim.log')
        with open(sim_log_path, 'a') as sim_log:
            for iss_idx in range(len(iss_exe)):
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
                        if str(iss_exe[iss_idx]['touch'][touch_idx]).upper() != str(rtl_exe[iss_idx]['touch'][touch_idx]).upper():
                            sim_log.write(f"Error: Result mismatch at PC {iss_exe[iss_idx]['pc']} for instruction --> {iss_exe[iss_idx]['mnemonic']}\n")
                            sim_log.write(f"ISS: {iss_exe[iss_idx]['touch'][touch_idx]}\n")
                            sim_log.write(f"RTL: {rtl_exe[iss_idx]['touch'][touch_idx]}\n")
                            test_passed = False
                if not test_passed:
                    break
    except:
        test_passed = False

    if test_passed:
        print(f"{test} {'.' * (50 - len(test))}. \033[92mPASSED\033[0m")
    else:
        print(f"{test} {'.' * (50 - len(test))}. \033[91mFAILED\033[0m")

def process_rtl_log(test: str):
    """Process the RTL log file."""
    with open(os.path.join("work", test, "rtl.log"), "r") as f:
        rtl_log = f.read()
    line_idx = 0
    while line_idx < len(rtl_log.split("\n"))-2:
        line = rtl_log.split("\n")[line_idx].split(";")
        nxt_line = rtl_log.split("\n")[line_idx + 1].split(";")
        if line not in ["", " "] and nxt_line not in ["", " "] and line[1] == nxt_line[1] and line[2] == nxt_line[2] and "Nothing": # Merge them
            effect = line[3]
            nxt_effect = nxt_line[3]
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
            lower_bytes = effect.split("=")[1].lstrip("0x")[8-alignment*2:]
            higher_bytes = nxt_effect.split("=")[1].lstrip("0x")[:8-alignment*2]
            # Combine them to get the full value
            merged_value = higher_bytes + lower_bytes
            # Remove nxt line from rtl_log
            rtl_log = rtl_log.replace(rtl_log.split("\n")[line_idx + 1], "")
            # Replace the line with the merged value
            rtl_log = rtl_log.replace(rtl_log.split("\n")[line_idx], f"{line[0]};{line[1]};{line[2]};mem[{mem_addr}]=0x{merged_value}")
            line_idx += 1
        line_idx += 1
    # Write the updated rtl_log
    with open(os.path.join("work", test, "rtl.log"), "w") as f:
        f.write(rtl_log)

def run_e2e(test: str, simulator: str):
    """Run a test through the entire pipeline."""
    try:
        reset_vector = run_gen(test)
        run_iss(test, reset_vector)
        prepare_imem(test)
        if simulator == "verilator":
            run_verilator(test, reset_vector)
        else:
            run_xsim(test, reset_vector)
        process_rtl_log(test)
        compare_results(test)
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
    
    args = parser.parse_args()
    
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
    
    # Run tests in parallel using thread pool
    with concurrent.futures.ThreadPoolExecutor(max_workers=num_cores) as executor:
        # Submit all tasks to the thread pool
        future_to_test = {executor.submit(run_e2e, test, args.simulator): test for test in tests}
        
        # Process completed tasks
        for future in concurrent.futures.as_completed(future_to_test):
            test = future_to_test[future]
            try:
                future.result()  # This will raise any exceptions that occurred
                # Print a detailed tracebacki on exception
            except Exception as e:
                print(f"Error running test {test}: {e}")
                continue

if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        print(f"Fatal error: {e}")
        sys.exit(1)
