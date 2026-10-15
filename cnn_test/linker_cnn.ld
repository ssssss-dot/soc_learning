OUTPUT_ARCH(riscv)
ENTRY(_start)

/* Loader still accepts 128 KiB of DMEM. Firmware uses the lower 64 KiB;
 * packed model constants occupy the upper 64 KiB and are loaded separately
 * or as part of the combined D0 packet produced by pack_model.py. */
MEMORY
{
    IMEM  (rx)  : ORIGIN = 0x00000000, LENGTH = 128K
    DMEM  (rwx) : ORIGIN = 0x80000000, LENGTH = 64K
    MODEL (r)   : ORIGIN = 0x80010000, LENGTH = 64K
}

SECTIONS
{
    .text :
    {
        . = ALIGN(4);
        KEEP(*(.text.start))
        KEEP(*(.text._start))
        *(.text*)
        . = ALIGN(4);
    } > IMEM

    .data :
    {
        . = ALIGN(4);
        *(.rodata*)
        *(.srodata*)
        *(.data*)
        *(.sdata*)
        . = ALIGN(4);
    } > DMEM

    .bss (NOLOAD) :
    {
        . = ALIGN(4);
        __bss_start = .;
        *(.bss*)
        *(.sbss*)
        *(COMMON)
        . = ALIGN(4);
        __bss_end = .;
    } > DMEM

    __stack_top = ORIGIN(DMEM) + LENGTH(DMEM);
    __model_base = ORIGIN(MODEL);
    __model_limit = ORIGIN(MODEL) + LENGTH(MODEL);
    ASSERT(__bss_end <= __stack_top - 4096, "Firmware must leave at least 4 KiB for stack below model")

    /DISCARD/ :
    {
        *(.comment)
        *(.note*)
        *(.eh_frame*)
        *(.riscv.attributes)
    }
}
