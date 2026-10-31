`timescale 1ns/1ps

package ares_pkg;
  localparam int unsigned XLEN = 32;
  localparam int unsigned RESET_PC_DEFAULT = 32'h0000_0000;

  // ARES single-core physical memory map (simulation configuration).
  localparam logic [31:0] ROM_BASE       = 32'h0000_0000;
  localparam logic [31:0] ROM_SIZE       = 32'h0001_0000;
  localparam logic [31:0] CLINT_BASE     = 32'h0001_0000;
  localparam logic [31:0] SCRATCH_BASE   = 32'h1000_0000;
  localparam logic [31:0] SCRATCH_SIZE   = 32'h0003_0000;
  localparam logic [31:0] DDR_UNC_BASE   = 32'h4000_0000;
  localparam logic [31:0] DDR_UNC_SIZE   = 32'h4000_0000;
  localparam logic [31:0] DDR_BASE       = 32'h8000_0000;
  localparam logic [31:0] DDR_SIZE       = 32'h4000_0000;
  localparam logic [31:0] MMIO_BASE      = 32'hD000_0000;
  // 16 MB: the peripheral space now holds two 320x240 frame windows (300 KB
  // each), which do not fit in the original 64 KB.  The simulation caught this:
  // loads beyond 0xD000_FFFF were routed to DDR and returned zero.
  localparam logic [31:0] MMIO_SIZE      = 32'h0100_0000;
  localparam logic [31:0] MT_BASE        = 32'hE000_0000;
  localparam logic [31:0] MT_SIZE        = 32'h0000_1000;

  // RISC-V opcodes
  localparam logic [6:0] OP_LUI      = 7'b0110111;
  localparam logic [6:0] OP_AUIPC    = 7'b0010111;
  localparam logic [6:0] OP_JAL      = 7'b1101111;
  localparam logic [6:0] OP_JALR     = 7'b1100111;
  localparam logic [6:0] OP_BRANCH   = 7'b1100011;
  localparam logic [6:0] OP_LOAD     = 7'b0000011;
  localparam logic [6:0] OP_STORE    = 7'b0100011;
  localparam logic [6:0] OP_IMM      = 7'b0010011;
  localparam logic [6:0] OP_REG      = 7'b0110011;
  localparam logic [6:0] OP_MISC_MEM = 7'b0001111;
  localparam logic [6:0] OP_SYSTEM   = 7'b1110011;

  // ALU operations
  typedef enum logic [4:0] {
    ALU_ADD  = 5'd0,
    ALU_SUB  = 5'd1,
    ALU_SLL  = 5'd2,
    ALU_SLT  = 5'd3,
    ALU_SLTU = 5'd4,
    ALU_XOR  = 5'd5,
    ALU_SRL  = 5'd6,
    ALU_SRA  = 5'd7,
    ALU_OR   = 5'd8,
    ALU_AND  = 5'd9,
    ALU_PASS_B = 5'd10
  } alu_op_t;

  // Branch operations
  typedef enum logic [2:0] {
    BR_BEQ  = 3'd0,
    BR_BNE  = 3'd1,
    BR_BLT  = 3'd4,
    BR_BGE  = 3'd5,
    BR_BLTU = 3'd6,
    BR_BGEU = 3'd7
  } branch_op_t;

  // CSR operations
  typedef enum logic [2:0] {
    CSR_NONE  = 3'd0,
    CSR_RW    = 3'd1,
    CSR_RS    = 3'd2,
    CSR_RC    = 3'd3,
    CSR_RWI   = 3'd4,
    CSR_RSI   = 3'd5,
    CSR_RCI   = 3'd6
  } csr_op_t;

  // Memory access size
  typedef enum logic [1:0] {
    MEM_BYTE = 2'd0,
    MEM_HALF = 2'd1,
    MEM_WORD = 2'd2
  } mem_size_t;

  // Multiply/divide operations
  typedef enum logic [3:0] {
    MD_NONE = 4'd0,
    MD_MUL  = 4'd1,
    MD_MULH = 4'd2,
    MD_MULHSU = 4'd3,
    MD_MULHU = 4'd4,
    MD_DIV  = 4'd5,
    MD_DIVU = 4'd6,
    MD_REM  = 4'd7,
    MD_REMU = 4'd8
  } muldiv_op_t;

  // Trap causes
  localparam logic [31:0] CAUSE_INST_MISALIGN  = 32'd0;
  localparam logic [31:0] CAUSE_ILLEGAL        = 32'd2;
  localparam logic [31:0] CAUSE_BREAKPOINT     = 32'd3;
  localparam logic [31:0] CAUSE_LOAD_MISALIGN  = 32'd4;
  localparam logic [31:0] CAUSE_STORE_MISALIGN = 32'd6;
  localparam logic [31:0] CAUSE_ECALL_M        = 32'd11;
  localparam logic [31:0] CAUSE_MACHINE_SOFT   = 32'h8000_0003;
  localparam logic [31:0] CAUSE_MACHINE_TIMER  = 32'h8000_0007;
  localparam logic [31:0] CAUSE_MACHINE_EXT    = 32'h8000_000B;

  // IF/ID payload
  typedef struct packed {
    logic        valid;
    logic [31:0] pc;
    logic [31:0] instr;
    logic        pred_taken;
    logic [31:0] pred_target;
  } ifid_t;

  // Decoded instruction carried through ID/EX and EX/MEM
  typedef struct packed {
    logic        valid;
    logic [31:0] pc;
    logic [31:0] instr;
    logic [4:0]  rs1;
    logic [4:0]  rs2;
    logic [4:0]  rd;
    logic [31:0] rs1_val;
    logic [31:0] rs2_val;
    logic [31:0] imm;
    alu_op_t     alu_op;
    logic        alu_a_pc;
    logic        alu_b_imm;
    logic        reg_write;
    logic        mem_read;
    logic        mem_write;
    logic [1:0]  mem_size;
    logic        mem_unsigned;
    branch_op_t  branch_op;
    logic        is_branch;
    logic        is_jal;
    logic        is_jalr;
    logic        csr_read;
    logic        csr_write;
    csr_op_t     csr_op;
    logic [11:0] csr_addr;
    logic        illegal;
    logic        ecall;
    logic        ebreak;
    logic        mret;
    logic        fence;
    logic        fence_i;
    logic        is_muldiv;
    muldiv_op_t  muldiv_op;
    logic        pred_taken;
    logic [31:0] pred_target;
    logic [31:0] next_pc;
  } pipe_t;

  // EX/MEM payload
  typedef struct packed {
    logic        valid;
    logic [31:0] pc;
    logic [31:0] instr;
    logic [4:0]  rd;
    logic        reg_write;
    logic        mem_read;
    logic        mem_write;
    logic [1:0]  mem_size;
    logic        mem_unsigned;
    logic [31:0] alu_result;
    logic [31:0] wb_data;
    logic [31:0] store_data;
    logic [31:0] next_pc;
    logic        csr_read;
    logic        csr_write;
    csr_op_t     csr_op;
    logic [11:0] csr_addr;
    logic [31:0] csr_wdata;
    logic        ecall;
    logic        ebreak;
    logic        mret;
    logic        fence;
    logic        fence_i;
    logic        illegal;
    logic [31:0] exception_cause;
    logic [31:0] exception_tval;
    logic        exception_valid;
  } exmem_t;

  // MEM/WB payload
  typedef struct packed {
    logic        valid;
    logic [31:0] pc;
    logic [31:0] instr;
    logic [4:0]  rd;
    logic        reg_write;
    logic [31:0] result;
    logic [31:0] next_pc;
    logic        csr_read;
    logic        csr_write;
    csr_op_t     csr_op;
    logic [11:0] csr_addr;
    logic [31:0] csr_wdata;
    logic        ecall;
    logic        ebreak;
    logic        mret;
    logic        fence;
    logic        fence_i;
    logic        illegal;
    logic [31:0] exception_cause;
    logic [31:0] exception_tval;
    logic        exception_valid;
  } memwb_t;

  function automatic logic [31:0] sign_extend_imm_i(input logic [31:0] instr);
    sign_extend_imm_i = {{20{instr[31]}}, instr[31:20]};
  endfunction
  function automatic logic [31:0] sign_extend_imm_s(input logic [31:0] instr);
    sign_extend_imm_s = {{20{instr[31]}}, instr[31:25], instr[11:7]};
  endfunction
  function automatic logic [31:0] sign_extend_imm_b(input logic [31:0] instr);
    sign_extend_imm_b = {{19{instr[31]}}, instr[31], instr[7], instr[30:25], instr[11:8], 1'b0};
  endfunction
  function automatic logic [31:0] sign_extend_imm_j(input logic [31:0] instr);
    sign_extend_imm_j = {{11{instr[31]}}, instr[31], instr[19:12], instr[20], instr[30:21], 1'b0};
  endfunction
endpackage