ENTRY(_start)

MEMORY
{
  DDR (rwx) : ORIGIN = 0x80000000, LENGTH = 512K
}

SECTIONS
{
  . = ORIGIN(DDR);

  .text : {
    *(.text.start)
    *(.text*)
    *(.rodata*)
  } > DDR

  .data : {
    __global_pointer$ = . + 0x800;
    *(.sdata*)
    *(.data*)
  } > DDR

  .bss : {
    . = ALIGN(4);
    __bss_start = .;
    *(.sbss*)
    *(.bss*)
    *(COMMON)
    . = ALIGN(4);
    __bss_end = .;
  } > DDR

  . = ALIGN(16);
  __stack_top = ORIGIN(DDR) + LENGTH(DDR) - 4;
}
