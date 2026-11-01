`timescale 1ns/1ps
// ARES-L: RV32IM five-stage in-order core.
//
// IF -> ID -> EX -> MEM -> WB
//   * full EX/MEM and MEM/WB forwarding
//   * one-cycle load-use interlock
//   * 2-bit BHT + BTB branch prediction, resolved in EX
//   * RV32M multiply/divide with a multi-cycle unit
//   * M-mode CSR, precise traps, MSIP/MTIP/MEIP
//   * FENCE (L1D writeback+invalidate) and FENCE.I (L1I invalidate)
module ares_l_core #(
  parameter logic [31:0] RESET_PC = 32'h0000_0000,
  parameter logic [3:0]  HARTID   = 4'd0
) (
  input  logic        clk,
  input  logic        rst,

  // instruction cache port
  output logic        imem_req_valid,
  input  logic        imem_req_ready,
  output logic [31:0] imem_req_addr,
  input  logic        imem_rsp_valid,
  input  logic [31:0] imem_rsp_data,

  // data cache port
  output logic        dmem_req_valid,
  input  logic        dmem_req_ready,
  output logic        dmem_req_write,
  output logic [31:0] dmem_req_addr,
  output logic [31:0] dmem_req_wdata,
  output logic [3:0]  dmem_req_wstrb,
  input  logic        dmem_rsp_valid,
  input  logic [31:0] dmem_rsp_rdata,

  // interrupts
  input  logic        irq_timer,
  input  logic        irq_soft,
  input  logic        irq_ext,

  // cache maintenance
  output logic        dcache_flush_req,
  input  logic        dcache_flush_done,
  output logic        icache_invalidate,
  input  logic        icache_invalidate_done,

  // debug / commit trace
  output logic [31:0] dbg_pc,
  output logic [31:0] dbg_instr,
  output logic        dbg_commit,
  output logic        dbg_halt,
  output logic [31:0] dbg_pc_f,
  output logic        dbg_ifid_valid,
  output logic        dbg_idex_valid,
  output logic        dbg_exmem_valid,
  output logic        dbg_memwb_valid,
  output logic        dbg_if_pending,
  output logic [31:0] dbg_exmem_addr,
  output logic [1:0]  dbg_exmem_size,
  output logic [31:0] dbg_mem_rsp_data,
  output logic [31:0] dbg_mem_result,
  output logic [31:0] dbg_memwb_result
);
  import ares_pkg::*;

  // ------------------------------------------------------------------ fetch
  logic [31:0] pc_f;
  logic        if_pending_q;
  logic [31:0] if_req_pc_q;
  logic        if_pred_taken_q;
  logic [31:0] if_pred_target_q;

  logic        bpu_pred_taken;
  logic [31:0] bpu_pred_target;
  logic        bpu_update_en;
  logic [31:0] bpu_update_pc;
  logic        bpu_update_taken;
  logic [31:0] bpu_update_target;
  logic        bpu_update_is_jal;
  logic        bpu_update_is_jalr;
  logic        bpu_update_is_cond;

  ares_bpu u_bpu (
    .clk,
    .rst,
    .fetch_pc(pc_f),
    .pred_taken(bpu_pred_taken),
    .pred_target(bpu_pred_target),
    .update_en(bpu_update_en),
    .update_pc(bpu_update_pc),
    .update_taken(bpu_update_taken),
    .update_target(bpu_update_target),
    .update_is_jal(bpu_update_is_jal),
    .update_is_jalr(bpu_update_is_jalr),
    .update_is_cond(bpu_update_is_cond)
  );

  // --------------------------------------------------------------- pipeline
  ifid_t   ifid_q;
  pipe_t   idex_q;
  exmem_t  exmem_q;
  memwb_t  memwb_q;

  logic [31:0] arch_next_pc_q;
  logic        halt_q;
  logic        fence_wait_q;
  logic        fence_kind_i_q;

  // Writeback / trap signals declared early because the register file and CSR
  // instances below reference them.
  logic [31:0] wb_value;
  logic        wb_reg_write;
  logic        wb_exception;
  logic        wb_mret;
  logic        wb_fence;
  logic        wb_fence_i;
  logic        wb_irq;
  logic        pipeline_empty;
  logic [31:0] wb_trap_cause;
  logic [31:0] irq_rising_cause;
  logic        trap_en;
  logic [31:0] trap_cause;
  logic [31:0] trap_tval;
  logic [31:0] trap_epc;
  logic        mret_en;
  logic        csr_wr_en;
  logic        instret_inc;

  // Decode result for the instruction in IF/ID.
  pipe_t decoded_d;
  pipe_t idex_d;
  logic  dec_rs1_used, dec_rs2_used;
  logic [31:0] rf_rdata1, rf_rdata2;

  ares_regfile u_regfile (
    .clk,
    .rs1(ifid_q.instr[19:15]),
    .rs2(ifid_q.instr[24:20]),
    .rdata1(rf_rdata1),
    .rdata2(rf_rdata2),
    .we(wb_reg_write),
    .rd(memwb_q.rd),
    .wdata(wb_value)
  );

  // --------------------------------------------------------------- CSR file
  logic [31:0] csr_rdata;
  logic [31:0] trap_vector;
  logic [31:0] mret_epc;
  logic        irq_pending;

  ares_csr u_csr (
    .clk,
    .rst,
    .hartid(HARTID),
    .addr(memwb_q.csr_addr),
    .wdata(memwb_q.csr_wdata),
    .op(memwb_q.csr_op),
    .wr_en(csr_wr_en),
    .rdata(csr_rdata),
    .trap_en(trap_en),
    .trap_cause(trap_cause),
    .trap_tval(trap_tval),
    .trap_epc(trap_epc),
    .trap_vector(trap_vector),
    .mret_en(mret_en),
    .mret_epc(mret_epc),
    .irq_timer(irq_timer),
    .irq_soft(irq_soft),
    .irq_ext(irq_ext),
    .irq_pending(irq_pending),
    .instret_inc(instret_inc),
    .cycle_inc(1'b1),
    .mcycle_o()
  );

  // --------------------------------------------------------- multiply/divide
  logic        md_start, md_busy, md_done;
  logic [31:0] md_result;
  muldiv_op_t  md_op;
  logic [31:0] md_a, md_b;
  logic        md_started_q;

  ares_muldiv u_muldiv (
    .clk,
    .rst,
    .start(md_start),
    .op(md_op),
    .a(md_a),
    .b(md_b),
    .busy(md_busy),
    .done(md_done),
    .result(md_result)
  );

  // ------------------------------------------------------------------ decode
  logic [31:0] dec_instr;
  logic [6:0]  dec_opcode;
  logic [2:0]  dec_funct3;
  logic [6:0]  dec_funct7;
  assign dec_instr  = ifid_q.instr;
  assign dec_opcode = dec_instr[6:0];
  assign dec_funct3 = dec_instr[14:12];
  assign dec_funct7 = dec_instr[31:25];

  always_comb begin
    decoded_d = '0;
    decoded_d.pc     = ifid_q.pc;
    decoded_d.instr  = ifid_q.instr;
    decoded_d.rs1    = dec_instr[19:15];
    decoded_d.rs2    = dec_instr[24:20];
    decoded_d.rd     = dec_instr[11:7];
    decoded_d.alu_op = ALU_ADD;
    decoded_d.imm    = 32'd0;
    dec_rs1_used  = 1'b0;
    dec_rs2_used  = 1'b0;

    case (dec_opcode)
      OP_LUI: begin
        decoded_d.reg_write = 1'b1;
        decoded_d.alu_op    = ALU_PASS_B;
        decoded_d.alu_b_imm = 1'b1;
        decoded_d.imm       = {dec_instr[31:12], 12'b0};
      end
      OP_AUIPC: begin
        decoded_d.reg_write = 1'b1;
        decoded_d.alu_op    = ALU_ADD;
        decoded_d.alu_a_pc  = 1'b1;
        decoded_d.alu_b_imm = 1'b1;
        decoded_d.imm       = {dec_instr[31:12], 12'b0};
      end
      OP_JAL: begin
        decoded_d.reg_write = 1'b1;
        decoded_d.is_jal    = 1'b1;
        decoded_d.alu_op    = ALU_ADD;
        decoded_d.alu_a_pc  = 1'b1;
        decoded_d.alu_b_imm = 1'b1;
        decoded_d.imm       = sign_extend_imm_j(dec_instr);
      end
      OP_JALR: begin
        decoded_d.reg_write = 1'b1;
        decoded_d.is_jalr   = 1'b1;
        decoded_d.alu_op    = ALU_ADD;
        decoded_d.alu_b_imm = 1'b1;
        decoded_d.imm       = sign_extend_imm_i(dec_instr);
        dec_rs1_used        = 1'b1;
      end
      OP_BRANCH: begin
        decoded_d.is_branch = 1'b1;
        decoded_d.branch_op = branch_op_t'(dec_funct3);
        decoded_d.alu_op    = ALU_ADD;
        decoded_d.alu_a_pc  = 1'b1;
        decoded_d.alu_b_imm = 1'b1;
        decoded_d.imm       = sign_extend_imm_b(dec_instr);
        dec_rs1_used        = 1'b1;
        dec_rs2_used        = 1'b1;
        if ((dec_funct3 == 3'd2) || (dec_funct3 == 3'd3)) decoded_d.illegal = 1'b1;
      end
      OP_LOAD: begin
        decoded_d.reg_write = 1'b1;
        decoded_d.mem_read  = 1'b1;
        decoded_d.mem_size  = dec_funct3[1:0];
        decoded_d.mem_unsigned = dec_funct3[2];
        decoded_d.alu_op    = ALU_ADD;
        decoded_d.alu_b_imm = 1'b1;
        decoded_d.imm       = sign_extend_imm_i(dec_instr);
        dec_rs1_used        = 1'b1;
        if ((dec_funct3 == 3'd3) || (dec_funct3 > 3'd5)) decoded_d.illegal = 1'b1;
      end
      OP_STORE: begin
        decoded_d.mem_write = 1'b1;
        decoded_d.mem_size  = dec_funct3[1:0];
        decoded_d.alu_op    = ALU_ADD;
        decoded_d.alu_b_imm = 1'b1;
        decoded_d.imm       = sign_extend_imm_s(dec_instr);
        dec_rs1_used        = 1'b1;
        dec_rs2_used        = 1'b1;
        if (dec_funct3 > 3'd2) decoded_d.illegal = 1'b1;
      end
      OP_IMM: begin
        decoded_d.reg_write = 1'b1;
        decoded_d.alu_b_imm = 1'b1;
        decoded_d.imm       = sign_extend_imm_i(dec_instr);
        dec_rs1_used        = 1'b1;
        case (dec_funct3)
          3'b000: decoded_d.alu_op = ALU_ADD;
          3'b010: decoded_d.alu_op = ALU_SLT;
          3'b011: decoded_d.alu_op = ALU_SLTU;
          3'b100: decoded_d.alu_op = ALU_XOR;
          3'b110: decoded_d.alu_op = ALU_OR;
          3'b111: decoded_d.alu_op = ALU_AND;
          3'b001: begin decoded_d.alu_op = ALU_SLL; decoded_d.imm = {27'd0, dec_instr[24:20]}; end
          3'b101: begin
            decoded_d.alu_op = dec_instr[30] ? ALU_SRA : ALU_SRL;
            decoded_d.imm = {27'd0, dec_instr[24:20]};
          end
          default: decoded_d.illegal = 1'b1;
        endcase
      end
      OP_REG: begin
        decoded_d.reg_write = 1'b1;
        dec_rs1_used        = 1'b1;
        dec_rs2_used        = 1'b1;
        if (dec_funct7 == 7'b0000001) begin
          decoded_d.is_muldiv = 1'b1;
          case (dec_funct3)
            3'b000: decoded_d.muldiv_op = MD_MUL;
            3'b001: decoded_d.muldiv_op = MD_MULH;
            3'b010: decoded_d.muldiv_op = MD_MULHSU;
            3'b011: decoded_d.muldiv_op = MD_MULHU;
            3'b100: decoded_d.muldiv_op = MD_DIV;
            3'b101: decoded_d.muldiv_op = MD_DIVU;
            3'b110: decoded_d.muldiv_op = MD_REM;
            3'b111: decoded_d.muldiv_op = MD_REMU;
            default: decoded_d.illegal = 1'b1;
          endcase
        end else begin
          case (dec_funct3)
            3'b000: decoded_d.alu_op = dec_funct7[5] ? ALU_SUB : ALU_ADD;
            3'b001: decoded_d.alu_op = ALU_SLL;
            3'b010: decoded_d.alu_op = ALU_SLT;
            3'b011: decoded_d.alu_op = ALU_SLTU;
            3'b100: decoded_d.alu_op = ALU_XOR;
            3'b101: decoded_d.alu_op = dec_funct7[5] ? ALU_SRA : ALU_SRL;
            3'b110: decoded_d.alu_op = ALU_OR;
            3'b111: decoded_d.alu_op = ALU_AND;
            default: decoded_d.illegal = 1'b1;
          endcase
          if ((dec_funct7 != 7'b0000000) && (dec_funct7 != 7'b0100000))
            decoded_d.illegal = 1'b1;
        end
      end
      OP_MISC_MEM: begin
        if (dec_funct3 == 3'b000) decoded_d.fence = 1'b1;
        else if (dec_funct3 == 3'b001) decoded_d.fence_i = 1'b1;
        else decoded_d.illegal = 1'b1;
      end
      OP_SYSTEM: begin
        if (dec_instr == 32'h0000_0073) begin
          decoded_d.ecall = 1'b1;
        end else if (dec_instr == 32'h0010_0073) begin
          decoded_d.ebreak = 1'b1;
        end else if (dec_instr == 32'h3020_0073) begin
          decoded_d.mret = 1'b1;
        end else if (dec_instr == 32'h1050_0073) begin
          // WFI is treated as a NOP in this implementation.
        end else if (dec_funct3 != 3'b000) begin
          decoded_d.reg_write = 1'b1;
          decoded_d.csr_read  = 1'b1;
          decoded_d.csr_addr  = dec_instr[31:20];
          case (dec_funct3)
            3'b001: begin decoded_d.csr_op = CSR_RW;  decoded_d.csr_write = 1'b1; dec_rs1_used = 1'b1; end
            3'b010: begin decoded_d.csr_op = CSR_RS;  decoded_d.csr_write = (dec_instr[19:15] != 5'd0); dec_rs1_used = 1'b1; end
            3'b011: begin decoded_d.csr_op = CSR_RC;  decoded_d.csr_write = (dec_instr[19:15] != 5'd0); dec_rs1_used = 1'b1; end
            3'b101: begin decoded_d.csr_op = CSR_RWI; decoded_d.csr_write = 1'b1; end
            3'b110: begin decoded_d.csr_op = CSR_RSI; decoded_d.csr_write = (dec_instr[19:15] != 5'd0); end
            3'b111: begin decoded_d.csr_op = CSR_RCI; decoded_d.csr_write = (dec_instr[19:15] != 5'd0); end
            default: decoded_d.illegal = 1'b1;
          endcase
        end else begin
          decoded_d.illegal = 1'b1;
        end
      end
      default: decoded_d.illegal = 1'b1;
    endcase
  end

  // Register operands with WB bypass and branch-prediction metadata.  This is
  // the only procedural driver of idex_d.
  always_comb begin
    idex_d = decoded_d;
    idex_d.rs1_val = rf_rdata1;
    idex_d.rs2_val = rf_rdata2;
    if (wb_reg_write && (memwb_q.rd != 5'd0) &&
        (memwb_q.rd == decoded_d.rs1)) begin
      idex_d.rs1_val = wb_value;
    end
    if (wb_reg_write && (memwb_q.rd != 5'd0) &&
        (memwb_q.rd == decoded_d.rs2)) begin
      idex_d.rs2_val = wb_value;
    end
    idex_d.pred_taken  = ifid_q.pred_taken;
    idex_d.pred_target = ifid_q.pred_target;
  end

  // ------------------------------------------------------------- EX stage
  logic [31:0] ex_rs1, ex_rs2;
  logic [31:0] ex_a, ex_b;
  logic [31:0] ex_alu_result;
  logic [31:0] ex_next_pc;
  logic        ex_branch_taken;
  logic        ex_take_branch;
  logic [31:0] ex_target;
  logic        ex_mispredict;
  logic        ex_misaligned;
  logic [31:0] ex_addr;
  logic [31:0] ex_wb_data;
  logic        ex_exception;
  logic [31:0] ex_cause;
  logic [31:0] ex_tval;
  logic        ex_hold;

  // Forwarding.
  always_comb begin
    ex_rs1 = idex_q.rs1_val;
    ex_rs2 = idex_q.rs2_val;
    if (exmem_q.valid && exmem_q.reg_write && !exmem_q.mem_read &&
        (exmem_q.rd != 5'd0) && (exmem_q.rd == idex_q.rs1)) begin
      ex_rs1 = exmem_q.wb_data;
    end else if (wb_reg_write && (memwb_q.rd != 5'd0) &&
                 (memwb_q.rd == idex_q.rs1)) begin
      ex_rs1 = wb_value;
    end
    if (exmem_q.valid && exmem_q.reg_write && !exmem_q.mem_read &&
        (exmem_q.rd != 5'd0) && (exmem_q.rd == idex_q.rs2)) begin
      ex_rs2 = exmem_q.wb_data;
    end else if (wb_reg_write && (memwb_q.rd != 5'd0) &&
                 (memwb_q.rd == idex_q.rs2)) begin
      ex_rs2 = wb_value;
    end
  end

  always_ff @(posedge clk) begin
    if (!rst && idex_q.valid && idex_q.is_branch && idex_q.pc == 32'h8000_003c) begin
      
    end
  end

  always_ff @(posedge clk) begin
    if (!rst && idex_q.valid && (idex_q.is_jalr || idex_q.is_jal)) begin
      
    end
    if (!rst && memwb_q.valid && ((memwb_q.pc == 32'h8000_0000) || (memwb_q.pc == 32'h8000_002c) || (memwb_q.pc == 32'h8000_004c))) begin
      
    end
  end

  always_comb begin
    ex_a = idex_q.alu_a_pc ? idex_q.pc : ex_rs1;
    ex_b = idex_q.alu_b_imm ? idex_q.imm : ex_rs2;

    case (idex_q.alu_op)
      ALU_ADD:  ex_alu_result = ex_a + ex_b;
      ALU_SUB:  ex_alu_result = ex_a - ex_b;
      ALU_SLL:  ex_alu_result = ex_a << ex_b[4:0];
      ALU_SLT:  ex_alu_result = ($signed(ex_a) < $signed(ex_b)) ? 32'd1 : 32'd0;
      ALU_SLTU: ex_alu_result = (ex_a < ex_b) ? 32'd1 : 32'd0;
      ALU_XOR:  ex_alu_result = ex_a ^ ex_b;
      ALU_SRL:  ex_alu_result = ex_a >> ex_b[4:0];
      ALU_SRA:  ex_alu_result = $signed(ex_a) >>> ex_b[4:0];
      ALU_OR:   ex_alu_result = ex_a | ex_b;
      ALU_AND:  ex_alu_result = ex_a & ex_b;
      ALU_PASS_B: ex_alu_result = ex_b;
      default:  ex_alu_result = 32'd0;
    endcase

    ex_branch_taken = 1'b0;
    case (idex_q.branch_op)
      BR_BEQ:  ex_branch_taken = (ex_rs1 == ex_rs2);
      BR_BNE:  ex_branch_taken = (ex_rs1 != ex_rs2);
      BR_BLT:  ex_branch_taken = ($signed(ex_rs1) < $signed(ex_rs2));
      BR_BGE:  ex_branch_taken = ($signed(ex_rs1) >= $signed(ex_rs2));
      BR_BLTU: ex_branch_taken = (ex_rs1 < ex_rs2);
      BR_BGEU: ex_branch_taken = (ex_rs1 >= ex_rs2);
      default: ex_branch_taken = 1'b0;
    endcase

    ex_target = ex_alu_result;
    if (idex_q.is_jalr)
      ex_target = (ex_rs1 + idex_q.imm) & 32'hFFFF_FFFE;

    ex_take_branch = (idex_q.is_branch && ex_branch_taken) || idex_q.is_jal || idex_q.is_jalr;

    if (idex_q.is_jal)
      ex_next_pc = idex_q.pc + idex_q.imm;
    else if (idex_q.is_jalr)
      ex_next_pc = ex_target;
    else if (idex_q.is_branch && ex_branch_taken)
      ex_next_pc = idex_q.pc + idex_q.imm;
    else
      ex_next_pc = idex_q.pc + 32'd4;

    ex_mispredict = (idex_q.is_branch || idex_q.is_jal || idex_q.is_jalr) &&
        ((ex_take_branch != idex_q.pred_taken) ||
         (ex_take_branch && (ex_next_pc != idex_q.pred_target)));

    ex_addr = ex_alu_result;
    ex_misaligned = (idex_q.mem_read || idex_q.mem_write) &&
        (((idex_q.mem_size == MEM_HALF) && ex_addr[0]) ||
         ((idex_q.mem_size == MEM_WORD) && (ex_addr[1:0] != 2'b00)));

    ex_exception = idex_q.illegal || ex_misaligned;
    ex_cause = idex_q.illegal ? CAUSE_ILLEGAL :
               idex_q.mem_read ? CAUSE_LOAD_MISALIGN : CAUSE_STORE_MISALIGN;
    ex_tval = idex_q.illegal ? idex_q.instr : ex_addr;

    ex_wb_data = ex_alu_result;
    if (idex_q.is_jal || idex_q.is_jalr) ex_wb_data = idex_q.pc + 32'd4;
    if (idex_q.is_muldiv) ex_wb_data = md_result;

    ex_hold = idex_q.valid && idex_q.is_muldiv && !md_done;
  end

  // Multiply/divide start control.
  assign md_op = idex_q.muldiv_op;
  assign md_a  = ex_rs1;
  assign md_b  = ex_rs2;
  assign md_start = idex_q.valid && idex_q.is_muldiv && !md_started_q && !md_busy && !md_done;

  always_ff @(posedge clk) begin
    if (rst) md_started_q <= 1'b0;
    else begin
      if (md_start) md_started_q <= 1'b1;
      if (md_done || !idex_q.is_muldiv) md_started_q <= 1'b0;
    end
  end

  // ------------------------------------------------------------- MEM stage
  logic        mem_op;
  logic        mem_req_sent_q;
  logic        mem_rsp_done_q;
  logic [31:0] mem_rsp_data_q;
  logic        mem_stall;

  assign mem_op = exmem_q.valid && (exmem_q.mem_read || exmem_q.mem_write) &&
                  !exmem_q.exception_valid;

  assign dmem_req_valid = mem_op && !mem_req_sent_q;
  assign dmem_req_write = exmem_q.mem_write;
  assign dmem_req_addr  = {exmem_q.alu_result[31:2], 2'b00};
  assign dmem_req_wstrb = !exmem_q.mem_write ? 4'b0000 :
      (exmem_q.mem_size == MEM_BYTE) ? (4'b0001 << exmem_q.alu_result[1:0]) :
      (exmem_q.mem_size == MEM_HALF) ? (4'b0011 << {exmem_q.alu_result[1], 1'b0}) :
                                       4'b1111;
  assign dmem_req_wdata = !exmem_q.mem_write ? 32'd0 :
      (exmem_q.mem_size == MEM_BYTE) ? (exmem_q.store_data << (exmem_q.alu_result[1:0] * 8)) :
      (exmem_q.mem_size == MEM_HALF) ? (exmem_q.store_data << ({exmem_q.alu_result[1], 1'b0} * 8)) :
                                       exmem_q.store_data;

  assign mem_stall = mem_op && !mem_rsp_done_q && !exmem_q.exception_valid;

  logic [31:0] mem_load_data;
  logic [31:0] mem_result;
  always_comb begin
    mem_load_data = mem_rsp_data_q >> (exmem_q.alu_result[1:0] * 8);
    case (exmem_q.mem_size)
      MEM_BYTE: mem_result = exmem_q.mem_unsigned ? {24'd0, mem_load_data[7:0]}
                                                  : {{24{mem_load_data[7]}}, mem_load_data[7:0]};
      MEM_HALF: mem_result = exmem_q.mem_unsigned ? {16'd0, mem_load_data[15:0]}
                                                  : {{16{mem_load_data[15]}}, mem_load_data[15:0]};
      default:  mem_result = mem_rsp_data_q;
    endcase
    if (!exmem_q.mem_read) mem_result = 32'd0;
  end

  // ------------------------------------------------------------ WB/trap
  assign wb_exception = memwb_q.valid &&
      (memwb_q.exception_valid || memwb_q.illegal || memwb_q.ecall || memwb_q.ebreak);
  assign wb_mret = memwb_q.valid && memwb_q.mret;
  assign wb_fence = memwb_q.valid && memwb_q.fence;
  assign wb_fence_i = memwb_q.valid && memwb_q.fence_i;
  assign pipeline_empty = !exmem_q.valid && !idex_q.valid && !ifid_q.valid;
  assign wb_irq = irq_pending &&
      (memwb_q.valid ? (!wb_exception && !wb_mret && !wb_fence && !wb_fence_i)
                     : pipeline_empty);

  assign wb_trap_cause = memwb_q.ecall ? CAUSE_ECALL_M :
                         memwb_q.ebreak ? CAUSE_BREAKPOINT :
                         memwb_q.exception_valid ? memwb_q.exception_cause :
                         irq_rising_cause;

  // IRQ cause priority: external > software > timer.
  always_comb begin
    if (irq_pending) begin
      // mip/mie are not visible here; use the raw source pins in priority order.
      if (irq_ext)      irq_rising_cause = CAUSE_MACHINE_EXT;
      else if (irq_soft) irq_rising_cause = CAUSE_MACHINE_SOFT;
      else               irq_rising_cause = CAUSE_MACHINE_TIMER;
    end else begin
      irq_rising_cause = CAUSE_MACHINE_TIMER;
    end
  end

  assign trap_en = wb_exception || wb_irq;
  assign trap_cause = wb_trap_cause;
  assign trap_tval = memwb_q.ecall ? 32'd0 :
                     memwb_q.ebreak ? 32'd0 :
                     memwb_q.exception_valid ? memwb_q.exception_tval : 32'd0;
  assign trap_epc = wb_exception ? memwb_q.pc :
                    (memwb_q.valid ? memwb_q.next_pc : arch_next_pc_q);
  assign mret_en = wb_mret && !wb_irq;

  assign wb_value = memwb_q.csr_read ? csr_rdata : memwb_q.result;
  assign wb_reg_write = memwb_q.valid && memwb_q.reg_write && !wb_exception &&
                        !wb_mret && !wb_fence && !wb_fence_i && (memwb_q.rd != 5'd0);
  assign csr_wr_en = memwb_q.valid && memwb_q.csr_write && !wb_exception &&
                     !wb_mret && !wb_fence && !wb_fence_i;
  assign instret_inc = memwb_q.valid && !wb_exception && !wb_mret && !wb_fence && !wb_fence_i;

  assign dbg_pc_f = pc_f;
  assign dbg_ifid_valid = ifid_q.valid;
  assign dbg_idex_valid = idex_q.valid;
  assign dbg_exmem_valid = exmem_q.valid;
  assign dbg_memwb_valid = memwb_q.valid;
  assign dbg_if_pending = if_pending_q;
  assign dbg_exmem_addr = exmem_q.alu_result;
  assign dbg_exmem_size = exmem_q.mem_size;
  assign dbg_mem_rsp_data = mem_rsp_data_q;
  assign dbg_mem_result = mem_result;
  assign dbg_memwb_result = memwb_q.result;

  assign dcache_flush_req = wb_fence && !fence_wait_q;
  assign icache_invalidate = wb_fence_i && !fence_wait_q;

  integer state_dbg_cnt;
  always_ff @(posedge clk) begin
    if (!rst && memwb_q.valid && (memwb_q.pc >= 32'h8000_003c) && (memwb_q.pc <= 32'h8000_004c)) begin
      
    end
    if (!rst && memwb_q.valid && (memwb_q.pc >= 32'h8000_223c) && (memwb_q.pc <= 32'h8000_2260)) begin
      
    end
    if (!rst && trap_en) begin
      
    end
    if (rst) state_dbg_cnt <= 0;
    else begin
      state_dbg_cnt <= state_dbg_cnt + 1;
      if ((state_dbg_cnt % 1000) == 0) begin
        
      end
    end
  end

  // ------------------------------------------------------- hazard / advance
  logic load_use;
  logic id_advance;
  logic stall_id;
  logic flush_ifid, flush_idex, flush_exmem;
  logic redirect_en;
  logic [31:0] redirect_pc;

  assign load_use = idex_q.valid && idex_q.mem_read && (idex_q.rd != 5'd0) &&
      ((idex_q.rd == ifid_q.instr[19:15]) || (idex_q.rd == ifid_q.instr[24:20]));

  assign stall_id = load_use || ex_hold || mem_stall || fence_wait_q;
  assign id_advance = ifid_q.valid && !stall_id && !flush_idex && !flush_ifid;

  // Redirect events.
  always_comb begin
    flush_ifid  = 1'b0;
    flush_idex  = 1'b0;
    flush_exmem = 1'b0;
    redirect_en = 1'b0;
    redirect_pc = 32'd0;

    if (ex_mispredict) begin
      flush_ifid  = 1'b1;
      redirect_en = 1'b1;
      redirect_pc = ex_next_pc;
    end

    if (wb_exception || wb_irq) begin
      flush_ifid  = 1'b1;
      flush_idex  = 1'b1;
      flush_exmem = 1'b1;
      redirect_en = 1'b1;
      redirect_pc = trap_vector;
    end else if (wb_mret) begin
      flush_ifid  = 1'b1;
      flush_idex  = 1'b1;
      flush_exmem = 1'b1;
      redirect_en = 1'b1;
      redirect_pc = mret_epc;
    end else if (wb_fence || wb_fence_i) begin
      flush_ifid  = 1'b1;
      flush_idex  = 1'b1;
      flush_exmem = 1'b1;
      redirect_en = 1'b1;
      redirect_pc = memwb_q.next_pc;
    end
  end

  logic [31:0] last_t0_q;
  always_ff @(posedge clk) begin
    if (rst) last_t0_q <= 32'd0;
    else if (idex_q.valid && (idex_q.pc == 32'h8000_003c)) begin
      if (ex_rs1 < last_t0_q) 
      if (ex_branch_taken) 
      last_t0_q <= ex_rs1;
    end
  end

  integer br_hold_cnt;
  always_ff @(posedge clk) begin
    if (rst) br_hold_cnt <= 0;
    else if (idex_q.valid && (idex_q.pc == 32'h8000_003c)) begin
      br_hold_cnt <= br_hold_cnt + 1;
      if (br_hold_cnt == 50) begin
        
      end
    end else br_hold_cnt <= 0;
  end

  // ---------------------------------------------------------- pipeline regs
  logic        imem_rsp_accept;
  logic        if_can_issue;

  assign if_can_issue = !if_pending_q && (!ifid_q.valid || id_advance) &&
                        !redirect_en && !fence_wait_q;
  assign imem_req_valid = if_can_issue && !halt_q;
  assign imem_req_addr  = pc_f;
  assign imem_rsp_accept = imem_rsp_valid && if_pending_q;

  always_ff @(posedge clk) begin
    if (rst) begin
      pc_f <= RESET_PC;
      if_pending_q <= 1'b0;
      if_req_pc_q <= RESET_PC;
      if_pred_taken_q <= 1'b0;
      if_pred_target_q <= 32'd0;
      ifid_q <= '0;
      idex_q <= '0;
      exmem_q <= '0;
      memwb_q <= '0;
      arch_next_pc_q <= RESET_PC;
      halt_q <= 1'b0;
      fence_wait_q <= 1'b0;
      fence_kind_i_q <= 1'b0;
      mem_req_sent_q <= 1'b0;
      mem_rsp_done_q <= 1'b0;
      mem_rsp_data_q <= 32'd0;
      bpu_update_en <= 1'b0;
      bpu_update_pc <= 32'd0;
      bpu_update_taken <= 1'b0;
      bpu_update_target <= 32'd0;
      bpu_update_is_jal <= 1'b0;
      bpu_update_is_jalr <= 1'b0;
      bpu_update_is_cond <= 1'b0;
    end else begin
      bpu_update_en <= 1'b0;

      // ---------------------------------------------------------- fetch
      if (redirect_en) begin
        pc_f <= redirect_pc;
        if_pending_q <= 1'b0;
      end else if (imem_rsp_valid && if_pending_q) begin
        if_pending_q <= 1'b0;
      end

      if (fence_wait_q) begin
        if ((fence_kind_i_q && icache_invalidate_done) ||
            (!fence_kind_i_q && dcache_flush_done)) begin
          fence_wait_q <= 1'b0;
        end
      end

      if (imem_rsp_valid && if_pending_q &&
          (if_req_pc_q >= 32'h8000_003c) && (if_req_pc_q <= 32'h8000_004c)) begin
        
      end
      if (imem_rsp_valid && if_pending_q &&
          (if_req_pc_q >= 32'h8000_223c) && (if_req_pc_q <= 32'h8000_225c)) begin
        
      end
      if (imem_rsp_valid && if_pending_q &&
          ((if_req_pc_q == 32'h8000_004c) || (if_req_pc_q == 32'h8000_0050) ||
           (if_req_pc_q == 32'h8000_0000) || (if_req_pc_q == 32'h8000_002c))) begin
        
      end
      if (!redirect_en && !fence_wait_q && imem_req_valid && imem_req_ready) begin
        if_pending_q <= 1'b1;
        if_req_pc_q <= pc_f;
        if_pred_taken_q <= bpu_pred_taken;
        if_pred_target_q <= bpu_pred_target;
        pc_f <= bpu_pred_taken ? bpu_pred_target : (pc_f + 32'd4);
      end

      // IF/ID update
      if (flush_ifid) begin
        ifid_q <= '0;
      end else if (imem_rsp_accept) begin
        ifid_q.valid <= 1'b1;
        ifid_q.pc <= if_req_pc_q;
        ifid_q.instr <= imem_rsp_data;
        ifid_q.pred_taken <= if_pred_taken_q;
        ifid_q.pred_target <= if_pred_target_q;
      end else if (id_advance) begin
        ifid_q <= '0;
      end

      // ID/EX update
      if (flush_idex) begin
        idex_q <= '0;
      end else if (stall_id) begin
        // hold
      end else if (id_advance) begin
        idex_q <= idex_d;
        idex_q.valid <= 1'b1;
      end else begin
        idex_q <= '0;
      end

      // EX/MEM update
      if (flush_exmem) begin
        exmem_q <= '0;
      end else if (ex_hold || mem_stall) begin
        // hold
      end else if (idex_q.valid) begin
        exmem_q.valid <= 1'b1;
        exmem_q.pc <= idex_q.pc;
        exmem_q.instr <= idex_q.instr;
        exmem_q.rd <= idex_q.rd;
        exmem_q.reg_write <= idex_q.reg_write;
        exmem_q.mem_read <= idex_q.mem_read;
        exmem_q.mem_write <= idex_q.mem_write;
        exmem_q.mem_size <= idex_q.mem_size;
        exmem_q.mem_unsigned <= idex_q.mem_unsigned;
        exmem_q.alu_result <= ex_alu_result;
        exmem_q.store_data <= ex_rs2;
        exmem_q.next_pc <= ex_next_pc;
        exmem_q.csr_read <= idex_q.csr_read;
        exmem_q.csr_write <= idex_q.csr_write;
        exmem_q.csr_op <= idex_q.csr_op;
        exmem_q.csr_addr <= idex_q.csr_addr;
        exmem_q.csr_wdata <= (idex_q.csr_op == CSR_RWI) ? {27'd0, idex_q.instr[19:15]} :
                              (idex_q.csr_op == CSR_RSI) ? {27'd0, idex_q.instr[19:15]} :
                              (idex_q.csr_op == CSR_RCI) ? {27'd0, idex_q.instr[19:15]} :
                              ex_rs1;
        exmem_q.ecall <= idex_q.ecall;
        exmem_q.ebreak <= idex_q.ebreak;
        exmem_q.mret <= idex_q.mret;
        exmem_q.fence <= idex_q.fence;
        exmem_q.fence_i <= idex_q.fence_i;
        exmem_q.illegal <= idex_q.illegal;
        exmem_q.exception_cause <= ex_cause;
        exmem_q.exception_tval <= ex_tval;
        exmem_q.exception_valid <= ex_exception;
        exmem_q.wb_data <= ex_wb_data;
      end else begin
        exmem_q <= '0;
      end

      // MEM/WB update
      if (flush_exmem) begin
        memwb_q <= '0;
      end else if (mem_stall) begin
        memwb_q <= '0;
      end else if (exmem_q.valid) begin
        memwb_q.valid <= 1'b1;
        memwb_q.pc <= exmem_q.pc;
        memwb_q.instr <= exmem_q.instr;
        memwb_q.rd <= exmem_q.rd;
        memwb_q.reg_write <= exmem_q.reg_write;
        memwb_q.result <= exmem_q.mem_read ? mem_result : exmem_q.wb_data;
        memwb_q.next_pc <= exmem_q.next_pc;
        memwb_q.csr_read <= exmem_q.csr_read;
        memwb_q.csr_write <= exmem_q.csr_write;
        memwb_q.csr_op <= exmem_q.csr_op;
        memwb_q.csr_addr <= exmem_q.csr_addr;
        memwb_q.csr_wdata <= exmem_q.csr_wdata;
        memwb_q.ecall <= exmem_q.ecall;
        memwb_q.ebreak <= exmem_q.ebreak;
        memwb_q.mret <= exmem_q.mret;
        memwb_q.fence <= exmem_q.fence;
        memwb_q.fence_i <= exmem_q.fence_i;
        memwb_q.illegal <= exmem_q.illegal;
        memwb_q.exception_cause <= exmem_q.exception_cause;
        memwb_q.exception_tval <= exmem_q.exception_tval;
        memwb_q.exception_valid <= exmem_q.exception_valid;
      end else begin
        memwb_q <= '0;
      end

      // Memory handshake bookkeeping.
      if (!mem_op) begin
        mem_req_sent_q <= 1'b0;
        mem_rsp_done_q <= 1'b0;
      end else begin
        if (dmem_req_valid && dmem_req_ready) mem_req_sent_q <= 1'b1;
        if (dmem_rsp_valid) begin
          mem_rsp_data_q <= dmem_rsp_rdata;
          mem_rsp_done_q <= 1'b1;
        end
        if (mem_stall && mem_rsp_done_q) mem_req_sent_q <= 1'b0;
        if (!mem_stall) begin
          mem_req_sent_q <= 1'b0;
          mem_rsp_done_q <= 1'b0;
        end
      end

      // FENCE wait entry.
      if (wb_fence && !fence_wait_q) begin
        fence_wait_q <= 1'b1;
        fence_kind_i_q <= 1'b0;
      end
      if (wb_fence_i && !fence_wait_q) begin
        fence_wait_q <= 1'b1;
        fence_kind_i_q <= 1'b1;
      end

      // Commit bookkeeping and halt.
      if (memwb_q.valid && !wb_exception && !wb_mret && !wb_fence && !wb_fence_i && !wb_irq) begin
        arch_next_pc_q <= memwb_q.next_pc;
      end
      if (memwb_q.valid && memwb_q.ebreak) halt_q <= 1'b1;

      // BPU training.
      if (idex_q.valid && !ex_hold && !flush_idex &&
          (idex_q.is_branch || idex_q.is_jal || idex_q.is_jalr)) begin
        bpu_update_en <= 1'b1;
        bpu_update_pc <= idex_q.pc;
        bpu_update_taken <= ex_take_branch;
        bpu_update_target <= ex_next_pc;
        bpu_update_is_jal <= idex_q.is_jal;
        bpu_update_is_jalr <= idex_q.is_jalr;
        bpu_update_is_cond <= idex_q.is_branch;
      end

      // Debug trace.
      dbg_pc <= memwb_q.pc;
      dbg_instr <= memwb_q.instr;
      dbg_commit <= memwb_q.valid && !wb_exception && !wb_irq;
      dbg_halt <= halt_q;
    end
  end
endmodule