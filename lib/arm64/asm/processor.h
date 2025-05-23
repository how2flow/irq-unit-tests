#ifndef _ASMARM64_PROCESSOR_H_
#define _ASMARM64_PROCESSOR_H_
/*
 * Copyright (C) 2014, Red Hat Inc, Andrew Jones <drjones@redhat.com>
 *
 * This work is licensed under the terms of the GNU LGPL, version 2.
 */

#ifndef __ASSEMBLER__
#include <asm/ptrace.h>
#include <asm/esr.h>
#include <asm/sysreg.h>
#include <asm/barrier.h>

enum vector {
	EL1T_SYNC,
	EL1T_IRQ,
	EL1T_FIQ,
	EL1T_ERROR,
	EL1H_SYNC,
	EL1H_IRQ,
	EL1H_FIQ,
	EL1H_ERROR,
	EL0_SYNC_64,
	EL0_IRQ_64,
	EL0_FIQ_64,
	EL0_ERROR_64,
	EL0_SYNC_32,
	EL0_IRQ_32,
	EL0_FIQ_32,
	EL0_ERROR_32,
	VECTOR_MAX,
};

#define EC_MAX 64

typedef void (*vector_fn)(enum vector v, struct pt_regs *regs,
			  unsigned int esr);
typedef void (*exception_fn)(struct pt_regs *regs, unsigned int esr);
typedef void (*irq_handler_fn)(struct pt_regs *regs);
extern void install_vector_handler(enum vector v, vector_fn fn);
extern void install_exception_handler(enum vector v, unsigned int ec,
				      exception_fn fn);
extern void install_irq_handler(enum vector v, irq_handler_fn fn);
extern void default_vector_sync_handler(enum vector v, struct pt_regs *regs,
					unsigned int esr);
extern void default_vector_irq_handler(enum vector v, struct pt_regs *regs,
				       unsigned int esr);
extern void vector_handlers_default_init(vector_fn *handlers);

extern void show_regs(struct pt_regs *regs);
extern bool get_far(unsigned int esr, unsigned long *far);

static inline unsigned long current_level(void)
{
	unsigned long el;
	asm volatile("mrs %0, CurrentEL" : "=r" (el));
	return el & 0xc;
}

static inline void local_irq_enable(void)
{
	asm volatile("msr daifclr, #2" : : : "memory");
}

static inline void local_irq_disable(void)
{
	asm volatile("msr daifset, #2" : : : "memory");
}

static inline uint64_t get_mpidr(void)
{
	return read_sysreg(mpidr_el1);
}

#define MPIDR_HWID_BITMASK 0xff00ffffff
extern int mpidr_to_cpu(uint64_t mpidr);

#define MPIDR_LEVEL_SHIFT(level) \
	(((1 << level) >> 1) << 3)
#define MPIDR_AFFINITY_LEVEL(mpidr, level) \
	((mpidr >> MPIDR_LEVEL_SHIFT(level)) & 0xff)

extern void start_usr(void (*func)(void *arg), void *arg, unsigned long sp_usr);
extern bool is_user(void);
extern bool __mmu_enabled(void);

static inline u64 get_cntvct(void)
{
	isb();
	return read_sysreg(cntvct_el0);
}

static inline u32 get_cntfrq(void)
{
	return read_sysreg(cntfrq_el0);
}

static inline u64 get_ctr(void)
{
	return read_sysreg(ctr_el0);
}

static inline unsigned long get_id_aa64mmfr0_el1(void)
{
	return read_sysreg(id_aa64mmfr0_el1);
}

#define ID_AA64MMFR0_TGRAN4_SHIFT	28
#define ID_AA64MMFR0_TGRAN64_SHIFT	24
#define ID_AA64MMFR0_TGRAN16_SHIFT	20

#define ID_AA64MMFR0_TGRAN4_SUPPORTED(r)			\
({								\
	u64 __v = ((r) >> ID_AA64MMFR0_TGRAN4_SHIFT) & 0xf;	\
	(__v) == 0 || (__v) == 1;				\
})

#define ID_AA64MMFR0_TGRAN64_SUPPORTED(r)			\
({								\
	u64 __v = ((r) >> ID_AA64MMFR0_TGRAN64_SHIFT) & 0xf;	\
	(__v) == 0;						\
})

#define ID_AA64MMFR0_TGRAN16_SUPPORTED(r)			\
({								\
	u64 __v = ((r) >> ID_AA64MMFR0_TGRAN16_SHIFT) & 0xf;	\
	(__v) == 1 || (__v) == 2;				\
})

static inline bool system_supports_granule(size_t granule)
{
	u64 mmfr0 = get_id_aa64mmfr0_el1();

	if (granule == SZ_4K)
		return ID_AA64MMFR0_TGRAN4_SUPPORTED(mmfr0);

	if (granule == SZ_16K)
		return ID_AA64MMFR0_TGRAN16_SUPPORTED(mmfr0);

	assert(granule == SZ_64K);
	return ID_AA64MMFR0_TGRAN64_SUPPORTED(mmfr0);
}

static inline unsigned long get_id_aa64pfr0_el1(void)
{
	return read_sysreg(id_aa64pfr0_el1);
}

#define ID_AA64PFR0_EL1_SVE_SHIFT	32

static inline bool system_supports_sve(void)
{
	return ((get_id_aa64pfr0_el1() >> ID_AA64PFR0_EL1_SVE_SHIFT) & 0xf) != 0;
}

static inline unsigned long sve_vl(void)
{
	unsigned long vl;

	asm volatile(".arch_extension sve\n"
		     "rdvl %x0, #8"
		     : "=r" (vl));

	return vl;
}


static inline bool system_supports_rndr(void)
{
	u64 id_aa64isar0_el1 = read_sysreg(ID_AA64ISAR0_EL1);

	return ((id_aa64isar0_el1 >> ID_AA64ISAR0_EL1_RNDR_SHIFT) & 0xf) != 0;
}

#endif /* !__ASSEMBLER__ */
#endif /* _ASMARM64_PROCESSOR_H_ */
