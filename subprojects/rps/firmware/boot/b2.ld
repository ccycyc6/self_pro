OUTPUT_ARCH(riscv)
ENTRY(_start)

/* B2 deliberately has no stack, no heap and no RAM: the whole image lives in
   the boot ROM at address 0, which is also the reset vector. */
SECTIONS
{
  . = 0x00000000;
  .text : { *(.text.init) *(.text*) }
  .rodata : { *(.rodata*) *(.srodata*) }
  .data : { *(.data*) }
  .bss : { *(.bss*) *(COMMON) }
}
