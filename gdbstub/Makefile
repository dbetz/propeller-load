ifndef BUILDROOT
BUILDROOT=.
endif

CC=gcc
NATIVECC=gcc
PROPCC=propeller-elf-gcc
RM=rm
LOAD=propeller-load

LOADERSRC=../src

CFLAGS=-Wall -I$(LOADERSRC)
SPINFLAGS=-Ogxr

OBJDIR=$(BUILDROOT)/obj
BINDIR=$(BUILDROOT)/bin

vpath %.c $(LOADERSRC)
vpath %.h $(LOADERSRC)

ifeq ($(OS),linux)
CFLAGS += -DLINUX
EXT=
OSINT=osint_linux
LIBS=
endif

ifeq ($(OS),cygwin)
CFLAGS += -DCYGWIN
EXT=.exe
OSINT=osint_cygwin enumcom
LIBS=-lsetupapi
endif

ifeq ($(OS),msys)
CFLAGS += -DMINGW
EXT=.exe
OSINT=osint_mingw enumcom
LIBS=-lsetupapi
endif

ifeq ($(OS),macosx)
CFLAGS += -DMACOSX
EXT=
OSINT=osint_linux
LIBS=
endif

EXE=$(BINDIR)/gdbstub$(EXT)

OBJS=$(OBJDIR)/gdbstub.o $(OBJDIR)/config.o $(OBJDIR)/expr.o \
	$(OBJDIR)/system.o \
	$(OBJDIR)/port.o \
	$(OBJDIR)/PLoadLib.o \
	$(foreach x, $(OSINT), $(OBJDIR)/$(x).o) \
	$(OBJDIR)/kernel_image.o

all:	dirs $(OBJDIR)/bin2c$(EXT) $(EXE)

dirs:
	mkdir -p $(OBJDIR)
	mkdir -p $(BINDIR)

$(EXE):	$(OBJS)
	$(CC) $(CFLAGS) -o $@ $(OBJS) $(LIBS)

$(OBJDIR)/%.o:	%.c
	$(CC) -c $(CFLAGS) -o $@ $<

$(OBJDIR)/%.o:	$(OBJDIR)/%.c
	$(CC) -c $(CFLAGS) -o $@ $<

################
# DUMMY KERNEL #
################

$(OBJDIR)/kernel_image.elf:	kernel.c
	$(PROPCC) -Os -mcog -fomit-frame-pointer -o $@ $<

###########################
# C TO BINARY IMAGE ARRAY #
###########################

$(OBJDIR)/%.binary:	$(OBJDIR)/%.elf
	$(LOAD) -s $<

$(OBJDIR)/%.c:	$(OBJDIR)/%.binary
	$(OBJDIR)/bin2c$(EXT) $< $@

#########
# TOOLS #
#########

$(OBJDIR)/bin2c$(EXT):	$(LOADERSRC)/tools/bin2c.c
	$(NATIVECC) $(CFLAGS) $(LDFLAGS) $< -o $@

.PHONY:	clean
clean:
	$(RM) -rf $(OBJDIR)
	$(RM) -rf $(BINDIR)
