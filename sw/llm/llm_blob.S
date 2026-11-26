/* The weights blob (llm_model.py export), linked in read-only. The build
 * passes the directory that holds llm_blob.bin with -Wa,-I. */
    .section .rodata.llm_blob, "a"
    .balign 4
    .globl llm_blob
llm_blob:
    .incbin "llm_blob.bin"
