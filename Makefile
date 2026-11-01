# ARES-S1: single ARES-L core + one miniTensor, YOLO simulation only.
#
#   make lint   - Verilator lint of the SoC
#   make sim    - build the Verilator SoC simulator
#   make yolo   - build the packed INT8 YOLO detector and run it
#   make clean  - remove build outputs

RISCV_PREFIX ?= riscv64-unknown-elf-
CC           := $(RISCV_PREFIX)gcc
OBJCOPY      := $(RISCV_PREFIX)objcopy
SIZE         := $(RISCV_PREFIX)size
VERILATOR    ?= verilator

DET_IMG_COUNT ?= 1
UART_DIV      ?= 8
# Extra -D flags for the firmware, e.g. make yolo EXTRA_DEFS=-DMT_PROF
EXTRA_DEFS    ?=

ARCH   := -march=rv32im_zicsr_zifencei -mabi=ilp32
CFLAGS := $(ARCH) -O2 -ffreestanding -fno-builtin -nostdlib -nostartfiles \
          -mno-relax -msmall-data-limit=0 -Ifirmware -Ifirmware/common \
          -DUART_DIV=$(UART_DIV)
LDFLAGS := $(ARCH) -nostdlib -nostartfiles -mno-relax -T firmware/common/linker.ld

RTL_COMMON := rtl/common/ares_pkg.sv
MT_RTL := \
  rtl/minitensor/interface/core_v_xif.sv \
  rtl/minitensor/common/minitensor_pkg.sv \
  rtl/minitensor/tensor/tensor_pkg.sv \
  rtl/minitensor/vector/vpu_pkg.sv \
  rtl/minitensor/vector/vpu_vector_regfile.sv \
  rtl/minitensor/vector/vpu_vector_alu.sv \
  rtl/minitensor/control/vpu_vector_controller.sv \
  rtl/minitensor/tensor/MXU/Systolic_Array/tensor_pe.sv \
  rtl/minitensor/tensor/MXU/Systolic_Array/tensor_systolic_array.sv \
  rtl/minitensor/tensor/MXU/INT8_GEMM/tensor_gemm_core.sv \
  rtl/minitensor/tensor/tensor_controller.sv \
  rtl/minitensor/tensor/Epilogue/tensor_epilogue_core.sv \
  rtl/minitensor/tensor/Epilogue/tensor_epilogue_controller.sv \
  rtl/minitensor/memory/unified_buffer.sv \
  rtl/minitensor/memory/vpu_dma.sv \
  rtl/minitensor/top/mt_fsm.sv \
  rtl/minitensor/top/mini_tensor_top.sv
CORE_RTL := \
  rtl/core/ares_regfile.sv rtl/core/ares_csr.sv rtl/core/ares_bpu.sv \
  rtl/core/ares_muldiv.sv rtl/cache/ares_l1i.sv rtl/cache/ares_dmem.sv \
  rtl/core/ares_l_core.sv
SOC_RTL := \
  rtl/soc/mt/mt_cmd_fifo.sv rtl/soc/mt/mt_cvxif_shim.sv rtl/soc/mt/mt_dma_l2_bridge.sv rtl/soc/mt/mt_cluster.sv \
  rtl/soc/ares_core_complex.sv rtl/soc/ares_clint.sv rtl/soc/ares_uart.sv \
  rtl/soc/ares_gpio.sv rtl/soc/ares_mmio_bus.sv rtl/soc/ares_l2.sv \
  rtl/soc/ddr/ddr3_model.sv rtl/soc/ares_soc.sv
RTL_ALL := $(RTL_COMMON) $(MT_RTL) $(CORE_RTL) $(SOC_RTL)

TB_SOC := sim/rtl/tb_soc.sv

.PHONY: all lint sim yolo clean

all: lint sim

lint:
	$(VERILATOR) --lint-only -Wall -Wno-fatal -Irtl/common -Irtl/minitensor \
	  $(RTL_ALL) --top-module ares_soc

sim:
	mkdir -p build/obj_soc
	$(VERILATOR) --binary --timing -Wall -Wno-fatal -Irtl/common -Irtl/minitensor \
	  $(RTL_ALL) $(TB_SOC) --top-module tb_soc --Mdir build/obj_soc -o Vtb_soc

# ---------------------------------------------------------------- YOLO
YOLO_SRC := firmware/common/start.S firmware/common/runtime.c \
  firmware/yolo/mt.c firmware/yolo/mt_net.c \
  firmware/yolo/mt_detect.c firmware/yolo/main.c

yolo: sim
	rm -rf build/yolo
	mkdir -p build/yolo
	for f in $(YOLO_SRC); do \
	  $(CC) $(CFLAGS) -Ifirmware/yolo -DDET_IMG_COUNT=$(DET_IMG_COUNT) \
	    $(EXTRA_DEFS) \
	    -c $$f -o build/yolo/$$(basename $$f).o; \
	done
	$(CC) $(LDFLAGS) build/yolo/*.o -lgcc -o build/yolo/yolo.elf
	$(OBJCOPY) -O binary build/yolo/yolo.elf build/yolo/yolo.bin
	python3 sim/tools/bin2hex.py build/yolo/yolo.bin build/yolo/yolo.hex
	$(SIZE) build/yolo/yolo.elf
	./build/obj_soc/Vtb_soc +DDR=build/yolo/yolo.hex >/dev/null 2>&1 || true
	@echo "--- YOLO UART output ---"
	@cat build/uart.log
	@grep -q "golden diff 0 bytes" build/uart.log
	@grep -q "YOLO run returned 0" build/uart.log
	@echo "--- YOLO simulation PASSED ---"

clean:
	rm -rf build

# ---------------------------------------------------------------- stereo sim
# Runs the stereo window path in the SoC simulation: the testbench fills the two
# frame memories with a shifted pair, the firmware reads them through the MMIO
# windows and reports the disparity.  Expected: 9.00 px.
STEREO_SIM_SRC := firmware/common/start.S firmware/common/runtime.c   firmware/yolo/stereo.c firmware/yolo/main_stereo_sim.c

stereo-sim: sim
	rm -rf build/stereo_sim
	mkdir -p build/stereo_sim
	for f in $(STEREO_SIM_SRC); do 	  $(CC) $(CFLAGS) -Ifirmware/yolo -c $$f -o build/stereo_sim/$$(basename $$f).o; 	done
	$(CC) $(LDFLAGS) build/stereo_sim/*.o -lgcc -o build/stereo_sim/stereo.elf
	$(OBJCOPY) -O binary build/stereo_sim/stereo.elf build/stereo_sim/stereo.bin
	python3 sim/tools/bin2hex.py build/stereo_sim/stereo.bin build/stereo_sim/stereo.hex
	./build/obj_soc/Vtb_soc +DDR=build/stereo_sim/stereo.hex >/dev/null 2>&1 || true
	@echo "--- stereo UART output ---"
	@cat build/uart.log
	@grep -q "STEREO SIM PASSED" build/uart.log
# ------------------------------------------------------------- tracker tests
# Synthetic 32x32 grids through the motion tracker: identity stability, merging
# of fragments, two objects, and dropping a track when the object leaves.
track-test:
	mkdir -p build
	gcc -O2 -I firmware/common -I firmware/yolo \
	  subprojects/gesture/ml/test_track.c firmware/yolo/mt_track.c -o build/test_track
	./build/test_track