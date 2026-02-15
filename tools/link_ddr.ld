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
    *(.sbss*)
    *(.bss*)
    *(COMMON)
  } > DDR

  . = ALIGN(16);
  __stack_top = ORIGIN(DDR) + LENGTH(DDR) - 4;
}
