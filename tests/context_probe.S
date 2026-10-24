	.text
	.globl wump_test_registers
	.type wump_test_registers, @function
wump_test_registers:
	pushq %rbp
	pushq %rbx
	pushq %r12
	pushq %r13
	pushq %r14
	pushq %r15
	subq $8, %rsp
	movl $100, (%rsp)
	movq $0x11223344, %rbp
	movq $0x22334455, %rbx
	movq $0x33445566, %r12
	movq $0x44556677, %r13
	movq $0x55667788, %r14
	movq $0x66778899, %r15
.Lagain:
	call wump_yield
	cmpq $0x11223344, %rbp
	jne .Lbad
	cmpq $0x22334455, %rbx
	jne .Lbad
	cmpq $0x33445566, %r12
	jne .Lbad
	cmpq $0x44556677, %r13
	jne .Lbad
	cmpq $0x55667788, %r14
	jne .Lbad
	cmpq $0x66778899, %r15
	jne .Lbad
	decl (%rsp)
	jnz .Lagain
	xorl %eax, %eax
	jmp .Ldone
.Lbad:
	movl $1, %eax
.Ldone:
	addq $8, %rsp
	popq %r15
	popq %r14
	popq %r13
	popq %r12
	popq %rbx
	popq %rbp
	ret
	.size wump_test_registers, .-wump_test_registers
	.section .note.GNU-stack,"",@progbits
