/* x86-64 SysV context switch.
 *
 * A context is a single saved stack pointer. The saved frame, from the
 * saved sp upward:
 *
 *   sp+0   mxcsr (4 bytes), x87 control word (2 bytes), pad
 *   sp+8   r15
 *   sp+16  r14
 *   sp+24  r13
 *   sp+32  r12
 *   sp+40  rbx
 *   sp+48  rbp
 *   sp+56  return address
 *
 * Everything else is caller-saved under SysV, so the compiler has already
 * spilled whatever it needs across the call to wump_ctx_switch.
 */

    .text

/* void wump_ctx_switch(void **save_sp, void *load_sp) */
    .globl  wump_ctx_switch
    .hidden wump_ctx_switch
    .type   wump_ctx_switch, @function
wump_ctx_switch:
    .cfi_startproc
    endbr64
    pushq   %rbp
    pushq   %rbx
    pushq   %r12
    pushq   %r13
    pushq   %r14
    pushq   %r15
    subq    $8, %rsp
    stmxcsr (%rsp)
    fnstcw  4(%rsp)

    movq    %rsp, (%rdi)
    movq    %rsi, %rsp

    ldmxcsr (%rsp)
    fldcw   4(%rsp)
    addq    $8, %rsp
    popq    %r15
    popq    %r14
    popq    %r13
    popq    %r12
    popq    %rbx
    popq    %rbp
    ret
    .cfi_endproc
    .size   wump_ctx_switch, .-wump_ctx_switch

/* First frame of every coroutine. wump_ctx_init leaves the entry function
 * in r12 and its argument in r13. The entry function must never return. */
    .globl  wump_ctx_trampoline
    .hidden wump_ctx_trampoline
    .type   wump_ctx_trampoline, @function
wump_ctx_trampoline:
    .cfi_startproc
    .cfi_undefined rip          /* end of the call chain for unwinders */
    endbr64
    movq    %r13, %rdi
    call    *%r12
    ud2
    .cfi_endproc
    .size   wump_ctx_trampoline, .-wump_ctx_trampoline

    .section .note.GNU-stack,"",@progbits
