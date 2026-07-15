ENTRY(_start)

MEMORY
{
  DDR (rwx) : ORIGIN = 0x80000000, LENGTH = 8M
}

PHDRS
{
  text PT_LOAD FLAGS(5);
  data PT_LOAD FLAGS(6);
}

SECTIONS
{
  . = ORIGIN(DDR);

  .text : {
    KEEP(*(.text.start))
    *(.text*)
    *(.rodata*)
  } > DDR :text

  .data : {
    . = ALIGN(4);
    __global_pointer$ = . + 0x800;
    *(.sdata*)
    *(.data*)
  } > DDR :data

  .bss (NOLOAD) : {
    . = ALIGN(4);
    __bss_start = .;
    *(.sbss*)
    *(.bss*)
    *(COMMON)
    . = ALIGN(4);
    __bss_end = .;
  } > DDR :data

  .startup_stack (NOLOAD) : {
    . = ALIGN(16);
    __stack_bottom = .;
    . = . + 64K;
    __stack_top = .;
  } > DDR :data

  .rtos_heap (NOLOAD) : {
    . = ALIGN(16);
    __heap_start = .;
    KEEP(*(.rtos_heap))
    . = ALIGN(16);
    __heap_end = .;
  } > DDR :data

  . = ALIGN(16);
  __image_end = LOADADDR(.data) + SIZEOF(.data);

  ASSERT(__heap_end <= ORIGIN(DDR) + LENGTH(DDR), "RTOS image/stack/heap exceeds DDR")
}
