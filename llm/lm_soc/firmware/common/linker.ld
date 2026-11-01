OUTPUT_ARCH(riscv)
ENTRY(_start)
SECTIONS
{
  . = 0x80000000;
  .text.init : { *(.text.init) }
  .text : { *(.text*) }
  .rodata : { *(.rodata*) }
  .data : { *(.data*) }
  . = ALIGN(16);
  __bss_start = .;
  .bss : { *(.bss*) *(COMMON) }
  __bss_end = .;
  . = ALIGN(16);
  PROVIDE(__global_pointer$ = . + 0x800);
  PROVIDE(__stack_top = 0x80020000);
}