///////////////////////////////////////////////////////////////////////////////
//     Copyright (c) 2025 Siliscale Consulting, LLC
// 
//    Licensed under the Apache License, Version 2.0 (the "License");
//    you may not use this file except in compliance with the License.
//    You may obtain a copy of the License at
// 
//        http://www.apache.org/licenses/LICENSE-2.0
// 
//    Unless required by applicable law or agreed to in writing, software
//    distributed under the License is distributed on an "AS IS" BASIS,
//    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//    See the License for the specific language governing permissions and
//    limitations under the License.
///////////////////////////////////////////////////////////////////////////////
//           _____          
//          /\    \         
//         /::\    \        
//        /::::\    \       
//       /::::::\    \      
//      /:::/\:::\    \     
//     /:::/__\:::\    \            Vendor      : Siliscale
//     \:::\   \:::\    \           Version     : 2025.1
//   ___\:::\   \:::\    \          Description : Tiny Vedas - Global Parameters
//  /\   \:::\   \:::\    \ 
// /::\   \:::\   \:::\____\
// \:::\   \:::\   \::/    /
//  \:::\   \:::\   \/____/ 
//   \:::\   \:::\    \     
//    \:::\   \:::\____\    
//     \:::\  /:::/    /    
//      \:::\/:::/    /     
//       \::::::/    /      
//        \::::/    /       
//         \::/    /        
//          \/____/         
///////////////////////////////////////////////////////////////////////////////

`ifndef GLOBAL_SVH
`define GLOBAL_SVH

localparam int XLEN = 32;
localparam int XLEN_BYTES = XLEN / 8;

localparam int RESET_VECTOR = 32'h00000000;

localparam int INSTR_LEN = 32;
localparam int INSTR_LEN_BYTES = INSTR_LEN / 8;

localparam int DATA_LEN = XLEN;
localparam int DATA_LEN_BYTES = DATA_LEN / 8;

localparam int INSTR_MEM_WIDTH = XLEN;
localparam int INSTR_MEM_DEPTH = 2 ** 18;
localparam int INSTR_MEM_ADDR_WIDTH = $clog2(INSTR_MEM_DEPTH * INSTR_MEM_WIDTH / 8);
localparam int INSTR_MEM_TAG_WIDTH = XLEN;

localparam int DATA_MEM_WIDTH = XLEN;
localparam int DATA_MEM_DEPTH = 2 ** 18;
localparam int DATA_MEM_ADDR_WIDTH = $clog2(DATA_MEM_DEPTH * DATA_MEM_WIDTH / 8);

localparam int REG_FILE_DEPTH = 32;
localparam int REG_FILE_ADDR_WIDTH = $clog2(REG_FILE_DEPTH);

`endif
