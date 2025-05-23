SHELL := /usr/bin/env bash

ifeq ($(wildcard config.mak),)
$(error run ./configure first. See ./configure -h)
endif

include config.mak

# Set search path for %.c %.s and %.S files
vpath %.c $(SRCDIR)
vpath %.s $(SRCDIR)
vpath %.S $(SRCDIR)

libdirs-get = $(shell [ -d "lib/$(1)" ] && echo "lib/$(1) lib/$(1)/asm")
ARCH_LIBDIRS := $(call libdirs-get,$(ARCH_LIBDIR)) $(call libdirs-get,$(TEST_DIR))
OBJDIRS := $(ARCH_LIBDIRS)

DESTDIR := $(PREFIX)/share/kvm-unit-tests/

.PHONY: arch_clean clean distclean cscope

# cc-option
# Usage: OP_CFLAGS+=$(call cc-option, -falign-functions=0, -malign-functions=0)
cc-option = $(shell if $(CC) $(CFLAGS) -Werror $(1) -S -o /dev/null -xc /dev/null \
              > /dev/null 2>&1; then echo "$(1)"; else echo "$(2)"; fi ;)

libcflat := lib/libcflat.a
cflatobjs := \
	lib/argv.o \
	lib/printf.o \
	lib/string.o \
	lib/abort.o \
	lib/rand.o \
	lib/report.o \
	lib/stack.o

# libfdt paths
LIBFDT_objdir = lib/libfdt
LIBFDT_srcdir = $(SRCDIR)/lib/libfdt
LIBFDT_archive = $(LIBFDT_objdir)/libfdt.a

OBJDIRS += $(LIBFDT_objdir)

# EFI App
ifeq ($(CONFIG_EFI),y)
EFI_CFLAGS := -DCONFIG_EFI -DCONFIG_RELOC
# The following CFLAGS and LDFLAGS come from:
#   - GNU-EFI/Makefile.defaults
#   - GNU-EFI/apps/Makefile
# GCC defines wchar to be 32 bits, but EFI expects 16 bits
EFI_CFLAGS += -fshort-wchar
# EFI applications use PIC as they are loaded to dynamic addresses, not a fixed
# starting address
EFI_CFLAGS += -fPIC
# Avoid error with the initrd_dev_path struct
EFI_CFLAGS += -Wno-gnu-variable-sized-type-not-at-end
# Create shared library
EFI_LDFLAGS := -Bsymbolic -shared -nostdlib
endif

#include architecture specific make rules
include $(SRCDIR)/$(TEST_DIR)/Makefile

COMMON_CFLAGS += -g $(autodepend-flags) -fno-strict-aliasing -fno-common
COMMON_CFLAGS += -Wall -Wwrite-strings -Wempty-body -Wuninitialized
COMMON_CFLAGS += -Wignored-qualifiers -Wno-missing-braces $(CONFIG_WERROR)

frame-pointer-flag=-f$(if $(KEEP_FRAME_POINTER),no-,)omit-frame-pointer
fomit_frame_pointer := $(call cc-option, $(frame-pointer-flag), "")
fno_stack_protector := $(call cc-option, -fno-stack-protector, "")
fno_stack_protector_all := $(call cc-option, -fno-stack-protector-all, "")
wno_frame_address := $(call cc-option, -Wno-frame-address, "")
fno_pic := $(call cc-option, -fno-pic, "")
no_pie := $(call cc-option, -no-pie, "")
wclobbered := $(call cc-option, -Wclobbered, "")
wunused_but_set_parameter := $(call cc-option, -Wunused-but-set-parameter, "")
wmissing_parameter_type := $(call cc-option, -Wmissing-parameter-type, "")
wold_style_declaration := $(call cc-option, -Wold-style-declaration, "")

COMMON_CFLAGS += $(fomit_frame_pointer)
COMMON_CFLAGS += $(fno_stack_protector)
COMMON_CFLAGS += $(fno_stack_protector_all)
COMMON_CFLAGS += $(wno_frame_address)
COMMON_CFLAGS += $(if $(U32_LONG_FMT),-D__U32_LONG_FMT__,)
ifeq ($(CONFIG_EFI),y)
COMMON_CFLAGS += $(EFI_CFLAGS)
else
COMMON_CFLAGS += $(fno_pic)
endif
COMMON_CFLAGS += $(wclobbered)
COMMON_CFLAGS += $(wunused_but_set_parameter)

CFLAGS += $(COMMON_CFLAGS)
CFLAGS += $(wmissing_parameter_type)
CFLAGS += $(wold_style_declaration)
CFLAGS += -Woverride-init -Wmissing-prototypes -Wstrict-prototypes

autodepend-flags = -MMD -MP -MF $(dir $*).$(notdir $*).d

LDFLAGS += -nostdlib $(no_pie) -z noexecstack

$(libcflat): $(cflatobjs)
	$(AR) rcs $@ $^

include $(LIBFDT_srcdir)/Makefile.libfdt
$(LIBFDT_archive): CFLAGS += -ffreestanding -I $(SRCDIR)/lib -I $(SRCDIR)/lib/libfdt -Wno-sign-compare
$(LIBFDT_archive): $(addprefix $(LIBFDT_objdir)/,$(LIBFDT_OBJS))
	$(AR) rcs $@ $^

libfdt_clean: VECHO = echo " "
libfdt_clean: STD_CLEANFILES = *.o .*.d
libfdt_clean: LIBFDT_dir = $(LIBFDT_objdir)
libfdt_clean: SHAREDLIB_EXT = so

# Build directory target
.PHONY: directories
directories:
	@mkdir -p $(OBJDIRS)

%.o: %.S
	$(CC) $(CFLAGS) -c -nostdlib -o $@ $<

-include */.*.d */*/.*.d

all: directories $(shell (cd $(SRCDIR) && git rev-parse --verify --short=8 HEAD) >build-head 2>/dev/null)

standalone: all
	@scripts/mkstandalone.sh

install: standalone
	mkdir -p $(DESTDIR)
	install tests/* $(DESTDIR)

clean: arch_clean libfdt_clean
	$(RM) $(LIBFDT_archive)
	$(RM) lib/.*.d $(libcflat) $(cflatobjs)

distclean: clean
	$(RM) lib/asm lib/config.h config.mak $(TEST_DIR)-run msr.out cscope.* build-head
	$(RM) -r tests logs logs.old efi-tests

cscope: cscope_dirs = lib lib/libfdt lib/linux $(TEST_DIR) $(ARCH_LIBDIRS) lib/asm-generic
cscope:
	$(RM) ./cscope.*
	find -L $(cscope_dirs) -maxdepth 1 \
		-name '*.[chsS]' -exec realpath --relative-base=$(CURDIR) {} \; | sort -u > ./cscope.files
	cscope -bk

.PHONY: shellcheck
shellcheck:
	shellcheck -P $(SRCDIR) -a $(SRCDIR)/run_tests.sh $(SRCDIR)/*/run $(SRCDIR)/*/efi/run $(SRCDIR)/scripts/mkstandalone.sh

.PHONY: tags
tags:
	ctags -R

check-kerneldoc:
	find $(SRCDIR) -name '*.[ch]' -exec scripts/kernel-doc -none {} +
