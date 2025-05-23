/*
 * Entry point and assembler functions for ppc64 tests.
 *
 * Copyright (C) 2016, Red Hat Inc, Andrew Jones <drjones@redhat.com>
 *
 * This work is licensed under the terms of the GNU LGPL, version 2.
 */
#include <asm/hcall.h>
#include <asm/ppc_asm.h>
#include <asm/rtas.h>
#include <asm/ptrace.h>

#include "spapr.h"

#define P_HANDLER	0x2ff8

.section .init

/*
 * start is the entry point. r3 points to the DTB
 */
.globl start
start:
	FIXUP_ENDIAN
	/* Switch to 64-bit mode */
	mfmsr	r1
	li	r2,1
	sldi	r2,r2,MSR_SF_BIT
	or	r1,r1,r2
	mtmsrd	r1
	/*
	 * We were loaded at QEMU's kernel load address, but we're not
	 * allowed to link there due to how QEMU deals with linker VMAs,
	 * so we just linked at zero. This means the first thing to do is
	 * to find our stack and toc, and then do a relocate. powernv and
	 * pseries load addresses are not the same, so find the address
	 * dynamically:
	 */
	bl	0f
0:	mflr	r31
	subi	r31, r31, 0b - start	/* QEMU's kernel load address */

	ld	r1, (p_stack - start)(r31)
	ld	r2, (p_toc - start)(r31)
	add	r1, r1, r31
	add	r2, r2, r31

	/* Zero backpointers in initial stack frame so backtrace() stops */
	li	r0,0
	std	r0,0(r1)
	std	r0,16(r1)

	/* save DTB pointer */
	std	r3, 56(r1)

	/*
	 * Call relocate. relocate is C code, but careful to not use
	 * any global references, as they may use absolute addresses,
	 * which are, obviously, not yet relocated.
	 */
	mr	r3, r31
	ld	r4, (p_dyn - start)(r31)
	add	r4, r4, r31
	bl	relocate

	/* compute address of call_handler */

	LOAD_REG_ADDR(r4, call_handler)
	std	r4, P_HANDLER(0)

	/* relocate vector table to base address 0x0 (MSR_IP = 0) */

	/* source: r4, dest end: r5, destination: r6 */

	LOAD_REG_ADDR(r4, __start_interrupts)
	LOAD_REG_ADDR(r5, __end_interrupts)
	sub	r5,r5,r4
	li	r6,0x100

	sub	r4,r4,r6
	add	r5,r5,r6
	addi	r6,r6,-8
2:	li	r0,8
	mtctr	r0
	/* copy a cache line size */
3:	addi	r6,r6,8
	ldx	r0,r6,r4
	stdx	r0,0,r6
	bdnz	3b
	dcbst	0,r6
	/* flush icache */
	sync
	icbi	0,r6
	cmpld	0,r6,r5
	blt	2b
	sync
	isync

	/* powernv machine does not check broken_sc1 */
	mfmsr	r3
	li	r4,1
	sldi	r4,r4,MSR_HV_BIT
	and.	r3,r3,r4
	bne	1f

	/* patch sc1 if needed */
	bl	hcall_have_broken_sc1
	cmpwi	r3, 0
	beq	1f
	LOAD_REG_ADDR(r3, hcall)
	LOAD_REG_IMMEDIATE(r4, SC1_REPLACEMENT)
	stw	r4, 0(r3)

	/* complete setup */
1:	ld	r3, 56(r1)
	bl	setup

	/* run the test */
	LOAD_REG_ADDR(r3, __argc)
	LOAD_REG_ADDR(r4, __argv)
	LOAD_REG_ADDR(r5, __environ)
	lwz	r3, 0(r3)
	bl	main
	bl	exit
	b	halt

/*
 * start_secondary is the secondary entry point. r3 contains the cpu id
 */
.globl start_secondary
start_secondary:
	FIXUP_ENDIAN
	/* Switch to 64-bit mode */
	mfmsr	r1
	li	r2,1
	sldi	r2,r2,MSR_SF_BIT
	or	r1,r1,r2
	mtmsrd	r1

	bl	0f
0:	mflr	r31
	subi	r31, r31, 0b - start	/* QEMU's kernel load address */

	ld	r2, (p_toc - start)(r31)

	LOAD_REG_ADDR(r9, cpus)
	li	r8,0
	li	r7,0
1:	add	r6,r9,r7
	ld	r6,CPU_SERVER_NO(r6)
	cmpd	r6,r3
	beq	2f
	addi	r7,r7,SIZEOF_STRUCT_CPU
	addi	r8,r8,1
	cmpdi	r8,MAX_CPUS
	bne	1b
	b	.

2:	add	r3,r9,r7
	ld	r1,CPU_STACK(r3)

	/* Zero backpointers in initial stack frame so backtrace() stops */
	li	r0,0
	std	r0,0(r1)
	std	r0,16(r1)

	bl	main_secondary
	bl	exit
	b	halt

.align 3
p_stack:	.llong  stackptr
p_toc:		.llong  tocptr
p_dyn:		.llong  dynamic_start

.text
start_text:
.align 3
p_toc_text:	.llong	tocptr

.align 3
.globl hcall
hcall:
	sc	1
	blr

.globl halt
halt:
1:	b	1b

.globl enter_rtas
enter_rtas:
	LOAD_REG_ADDR(r11, rtas_entry)
	ld	r10, 0(r11)

	cmpdi	r10,0
	bne	external_rtas

	/* Use H_RTAS directly */
	mr	r4,r3
	lis	r3,KVMPPC_H_RTAS@h
	ori	r3,r3,KVMPPC_H_RTAS@l
	b	hcall

external_rtas:
	/* Use external RTAS blob */
	mflr	r0
	std	r0, 16(r1)

	LOAD_REG_ADDR(r11, rtas_return_loc)
	mtlr	r11

	mfmsr	r11
	LOAD_REG_IMMEDIATE(r9, RTAS_MSR_MASK)
	and	r11, r11, r9
	mtsrr0	r10
	mtsrr1	r11
	rfid
	b       .

rtas_return_loc:
	FIXUP_ENDIAN
	ld	r0, 16(r1)
	mtlr	r0
	blr

call_handler:
	/* save context */

	/* GPRs */

	.irp i, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 \
	        17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31
		SAVE_GPR(\i, r1)
	.endr
	mfsprg1	r0
	std	r0,GPR1(r1)
	std	r0,0(r1) /* Backchain from interrupt stack to regular stack */

	/* lr, xer, ccr */

	mflr	r0
	std	r0,_LINK(r1)

	mfxer	r0
	std	r0,_XER(r1)

	mfcr	r0
	std	r0,_CCR(r1)

	/* restore TOC pointer */
	bl	0f
0:	mflr	r31
	subi	r31, r31, 0b - start_text
	ld	r2, (p_toc_text - start_text)(r31)

	/* call generic handler */

	addi	r3,r1,STACK_FRAME_OVERHEAD
	bl	do_handle_exception
	.global do_handle_exception_return
do_handle_exception_return:

	/* restore context */

	ld	r0,_CTR(r1)
	mtctr	r0

	ld	r0,_LINK(r1)
	mtlr	r0

	ld	r0,_XER(r1)
	mtxer	r0

	ld	r0,_CCR(r1)
	mtcr	r0

	ld	r0, _NIP(r1)
	mtsrr0	r0

	ld	r0, _MSR(r1)
	mtsrr1	r0

	.irp i, 0, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 \
	        17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31
		REST_GPR(\i, r1)
	.endr

	/* restore r1, as we don't need it anymore */

	REST_GPR(1,r1)

	rfid
	b .

.section .text.ex

/* [H]VECTOR must not be more than 8 instructions to fit in 0x20 vectors */
.macro VECTOR vec
	. = \vec

	mtsprg1	r1	/* save r1 */
	mfsprg0	r1	/* get struct cpu address */
	ld	r1,CPU_EXCEPTION_STACK(r1) /* get exception stack address */
	subi	r1,r1, INT_FRAME_SIZE

	/* save r0 and ctr to call generic handler */
	SAVE_GPR(0,r1)

	li	r0,\vec
	std	r0,_TRAP(r1)

	b	handler_trampoline
.endm

.macro HVECTOR vec
	. = \vec

	mtsprg1	r1	/* save r1 */
	mfsprg0	r1	/* get struct cpu address */
	ld	r1,CPU_EXCEPTION_STACK(r1) /* get exception stack address */
	subi	r1,r1, INT_FRAME_SIZE

	/* save r0 and ctr to call generic handler */
	SAVE_GPR(0,r1)

	li	r0,\vec
	std	r0,_TRAP(r1)

	b	handler_htrampoline
.endm

	. = 0x100
	.globl __start_interrupts
__start_interrupts:

VECTOR(0x100)
VECTOR(0x200)
VECTOR(0x300)
VECTOR(0x380)
VECTOR(0x400)
VECTOR(0x480)
VECTOR(0x500)
VECTOR(0x600)
VECTOR(0x700)
VECTOR(0x800)
VECTOR(0x900)
HVECTOR(0x980)
VECTOR(0xa00)
VECTOR(0xc00)
VECTOR(0xd00)
HVECTOR(0xe00)
HVECTOR(0xe20)
HVECTOR(0xe40)
HVECTOR(0xe60)
HVECTOR(0xe80)
HVECTOR(0xea0)
VECTOR(0xf00)
VECTOR(0xf20)
VECTOR(0xf40)
VECTOR(0xf60)
HVECTOR(0xf80)

handler_trampoline:
	mfctr	r0
	std	r0,_CTR(r1)

	ld	r0, P_HANDLER(0)
	mtctr	r0

	/* nip and msr */
	mfsrr0	r0
	std	r0, _NIP(r1)

	mfsrr1	r0
	std	r0, _MSR(r1)

	bctr

handler_htrampoline:
	mfctr	r0
	std	r0,_CTR(r1)

	ld	r0, P_HANDLER(0)
	mtctr	r0

	/* nip and msr */
	mfspr	r0, SPR_HSRR0
	std	r0, _NIP(r1)

	mfspr	r0, SPR_HSRR1
	std	r0, _MSR(r1)

	bctr

	.align 7
	.globl __end_interrupts
__end_interrupts:
	.org	P_HANDLER
	.llong	0
