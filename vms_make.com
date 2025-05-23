$! make FreeType 2 under OpenVMS
$!
$! Copyright (C) 2003-2024 by
$! David Turner, Robert Wilhelm, and Werner Lemberg.
$!
$! This file is part of the FreeType project, and may only be used, modified,
$! and distributed under the terms of the FreeType project license,
$! LICENSE.TXT.  By continuing to use, modify, or distribute this file you
$! indicate that you have read the license and understand and accept it
$! fully.
$!
$!
$! External libraries (like FreeType, XPM, etc.) are supported via the
$! config file VMSLIB.DAT. Please check the sample file, which is part of this
$! distribution, for the information you need to provide
$!
$! This procedure currently does support the following commandline options
$! in arbitrary order
$!
$! * DEBUG - Compile modules with /noopt/debug and link shareable image
$!           with /debug
$! * LOPTS - Options to be passed to the link command
$! * CCOPT - Options to be passed to the C compiler
$!
$! In case of problems with the install you might contact me at
$! zinser@zinser.no-ip.info (preferred) or
$! zinser@sysdev.deutsche-boerse.com (work)
$!
$! Make procedure history for FreeType 2
$!
$!------------------------------------------------------------------------------
$! Version history
$! 0.01 20040401 First version to receive a number
$! 0.02 20041030 Add error handling, FreeType 2.1.9
$!
$ on error then goto err_exit
$!
$! Get platform
$ vax      = f$getsyi("ARCH_NAME").eqs. "VAX"
$ axp      = f$getsyi("ARCH_NAME").eqs. "Alpha"
$ ia64     = f$getsyi("ARCH_NAME").eqs. "IA64"
$ x86_64   = f$getsyi("ARCH_NAME").eqs. "x86_64"
$!
$ true  = 1
$ false = 0
$ tmpnam = "temp_" + f$getjpi("","pid")
$ tt = tmpnam + ".txt"
$ tc = tmpnam + ".c"
$ th = tmpnam + ".h"
$ its_decc = false
$ its_vaxc = false
$ its_gnuc = false
$!
$! Setup variables holding "config" information
$!
$ Make    = ""
$ ccopt   = "/name=(as_is,short)/float=ieee"
$ if ( x86_64 ) then cxxopt = " -names2=shortened "
$ lopts   = ""
$ dnsrl   = ""
$ aconf_in_file = "config.hin"
$ name    = "Freetype2"
$ mapfile = name + ".map"
$ optfile = name + ".opt"
$ s_case  = false
$ liblist = ""
$!
$ whoami = f$parse(f$environment("Procedure"),,,,"NO_CONCEAL")
$ mydef  = F$parse(whoami,,,"DEVICE")
$ mydir  = f$parse(whoami,,,"DIRECTORY") - "]["
$ myproc = f$parse(whoami,,,"Name") + f$parse(whoami,,,"type")
$!
$! Check for MMK/MMS
$!
$ If F$Search ("Sys$System:MMS.EXE") .nes. "" Then Make = "MMS"
$ If F$Type (MMK) .eqs. "STRING" Then Make = "MMK"
$!
$! Which command parameters were given
$!
$ gosub check_opts
$!
$!
$! Pull in external libraries
$!
$ have_png = f$search("sys$library:libpng.olb") .nes. ""
$ have_bz2 = f$search("sys$library:libbz2.olb") .nes. ""
$ have_z = f$search("sys$library:libz.olb") .nes. ""
$ have_harfbuzz = f$search("sys$library:libharfbuzz.olb") .nes. ""
$!
$ create libs.opt
$ open/write libsf libs.opt
$ if ( have_harfbuzz ) then write libsf "sys$library:libharfbuzz.olb/lib"
$ if ( have_png ) then write libsf "sys$library:libpng.olb/lib"
$ if ( have_bz2 ) then write libsf "sys$library:libbz2.olb/lib"
$ if ( have_z ) then write libsf "sys$library:libz.olb/lib"
$ close libsf
$ open/write libsf libs_cxx.opt
$ if ( have_harfbuzz ) then write libsf "sys$library:libharfbuzz.olb/lib"
$ if ( have_png ) then write libsf "sys$library:libpng_cxx.olb/lib"
$ if ( have_bz2 ) then write libsf "sys$library:libbz2_cxx.olb/lib"
$ if ( have_z ) then write libsf "sys$library:libz_cxx.olb/lib"
$ close libsf
$!
$! Create objects
$!
$ libdefs = "FT2_BUILD_LIBRARY,FT_CONFIG_OPTION_OLD_INTERNALS"
$ if ( have_bz2 ) then libdefs=libdefs+",FT_CONFIG_OPTION_USE_BZIP2=1"
$ if ( have_png ) then libdefs=libdefs+",FT_CONFIG_OPTION_USE_PNG=1"
$ if ( have_z ) then libdefs=libdefs+",FT_CONFIG_OPTION_SYSTEM_ZLIB=1"
$ if ( have_harfbuzz ) then libdefs=libdefs+",FT_CONFIG_OPTION_USE_HARFBUZZ=1"
$ libdefs_cxx = "-DFT2_BUILD_LIBRARY -DFT_CONFIG_OPTION_OLD_INTERNALS"
$ if ( have_bz2 ) then libdefs_cxx=libdefs_cxx+" -DFT_CONFIG_OPTION_USE_BZIP2=1"
$ if ( have_png ) then libdefs_cxx=libdefs_cxx+" -DFT_CONFIG_OPTION_USE_PNG=1"
$ if ( have_z ) then libdefs_cxx=libdefs_cxx+" -DFT_CONFIG_OPTION_SYSTEM_ZLIB=1"
$ if ( have_harfbuzz ) then libdefs_cxx=libdefs_cxx+" -DFT_CONFIG_OPTION_USE_HARFBUZZ=1"
$ if libdefs .nes. ""
$ then
$   ccopt = ccopt + "/define=(" + libdefs + ")"
$ if ( x86_64 ) then cxxopt = cxxopt + libdefs_cxx
$ endif
$!
$ if f$locate("AS_IS",f$edit(ccopt,"UPCASE")) .lt. f$length(ccopt) -
    then s_case = true
$ gosub crea_mms
$!
$ if x86_64
$ then
$   'Make' /macro=(comp_flags="''ccopt'",cxxcomp_flags="''cxxopt'","X86=1")
$ else
$   'Make' /macro=(comp_flags="''ccopt'")
$ endif
$ purge/nolog [...]descrip.mms
$!
$!
$! Alpha & Itanium get a shareable image
$!
$ If .not. vax
$ Then
$   write sys$output "Creating freetype2shr.exe"
$   library/extract=* [.lib]freetype.olb
$   set def [.src.tools]
$   cc apinames.c
$   link apinames
$   set def [--]
$   pur [.include.freetype]ftmac.h
$   rename [.include.freetype]ftmac.h [.include.freetype]ftmac.h_tmp
$   bash builds/vms/apinames_vms.bash
$   rename [.include.freetype]ftmac.h_tmp [.include.freetype]ftmac.h
$   open/write file  libfreetype.opt
$   write file "!"
$   write file "! libfreetype.opt generated by vms_make.com"
$   write file "!"
$   write file "IDENTIFICATION=""freetype2 2.0"""
$   write file "GSMATCH=LEQUAL,2,0
$   write file "freetype.obj"
$   close file
$   link/nodeb/share=[.lib]freetype2shr.exe/map=libfreetype.map/full -
      libfreetype/opt,freetype_vms/opt,libs/opt
$   delete freetype.obj;*
$ endif
$ if x86_64
$ then
$   write sys$output "Creating freetype2shr_cxx.exe"
$   library/extract=* [.lib]freetype_cxx.olb
$   open/write file  libfreetype_cxx.opt
$   write file "!"
$   write file "! libfreetype_cxx.opt generated by vms_make.com"
$   write file "!"
$   write file "IDENTIFICATION=""freetype2 2.0"""
$   write file "GSMATCH=LEQUAL,2,0
$   write file "freetype_cxx.obj"
$   close file
$   link/nodeb/share=[.lib]freetype2shr_cxx.exe/map=libfreetype_cxx.map/full -
      libfreetype_cxx/opt,freetype_vms/opt,libs_cxx/opt
$   delete freetype_cxx.obj;*
$ endif
$!
$ exit
$!
$
$ERR_EXIT:
$ set message/facil/ident/sever/text
$ close/nolog optf
$ close/nolog out
$ close/nolog libdata
$ close/nolog in
$ close/nolog atmp
$ close/nolog xtmp
$ write sys$output "Exiting..."
$ exit 2
$!
$!------------------------------------------------------------------------------
$!
$! If MMS/MMK are available dump out the descrip.mms if required
$!
$CREA_MMS:
$ write sys$output "Creating descrip.mms files ..."
$ write sys$output "... Main directory"
$ create descrip.mms
$ open/append out descrip.mms
$ copy sys$input: out
$ deck
#
# FreeType 2 build system -- top-level Makefile for OpenVMS
#


# Copyright 2001-2019 by
# David Turner, Robert Wilhelm, and Werner Lemberg.
#
# This file is part of the FreeType project, and may only be used, modified,
# and distributed under the terms of the FreeType project license,
# LICENSE.TXT.  By continuing to use, modify, or distribute this file you
# indicate that you have read the license and understand and accept it
# fully.
$ EOD
$ write out "CFLAGS = ", ccopt
$ if x86_64 then write out "CXXFLAGS = ", cxxopt
$ copy sys$input: out
$ deck


all :
	define config [--.include.freetype.config]
	define internal [--.include.freetype.internal]
	define autofit [-.autofit]
	define base [-.base]
	define cache [-.cache]
	define cff [-.cff]
	define cid [-.cid]
	define freetype [--.include.freetype]
	define pcf [-.pcf]
	define psaux [-.psaux]
	define psnames [-.psnames]
	define raster [-.raster]
	define sfnt [-.sfnt]
	define smooth [-.smooth]
	define truetype [-.truetype]
	define type1 [-.type1]
	define winfonts [-.winfonts]
	if f$search("lib.dir") .eqs. "" then create/directory [.lib]
	set default [.builds.vms]
	$(MMS)$(MMSQUALIFIERS)
	set default [--.src.autofit]
	$(MMS)$(MMSQUALIFIERS)
	set default [-.base]
	$(MMS)$(MMSQUALIFIERS)
	set default [-.bdf]
	$(MMS)$(MMSQUALIFIERS)
	set default [-.cache]
	$(MMS)$(MMSQUALIFIERS)
	set default [-.cff]
	$(MMS)$(MMSQUALIFIERS)
	set default [-.cid]
	$(MMS)$(MMSQUALIFIERS)
	set default [-.gxvalid]
	$(MMS)$(MMSQUALIFIERS)
	set default [-.gzip]
	$(MMS)$(MMSQUALIFIERS)
	set default [-.bzip2]
	$(MMS)$(MMSQUALIFIERS)
	set default [-.lzw]
	$(MMS)$(MMSQUALIFIERS)
	set default [-.otvalid]
	$(MMS)$(MMSQUALIFIERS)
	set default [-.pcf]
	$(MMS)$(MMSQUALIFIERS)
	set default [-.pfr]
	$(MMS)$(MMSQUALIFIERS)
	set default [-.psaux]
	$(MMS)$(MMSQUALIFIERS)
	set default [-.pshinter]
	$(MMS)$(MMSQUALIFIERS)
	set default [-.psnames]
	$(MMS)$(MMSQUALIFIERS)
	set default [-.raster]
	$(MMS)$(MMSQUALIFIERS)
	set default [-.sfnt]
	$(MMS)$(MMSQUALIFIERS)
	set default [-.smooth]
	$(MMS)$(MMSQUALIFIERS)
	set default [-.svg]
	$(MMS)$(MMSQUALIFIERS)
	set default [-.truetype]
	$(MMS)$(MMSQUALIFIERS)
	set default [-.type1]
	$(MMS)$(MMSQUALIFIERS)
	set default [-.type42]
	$(MMS)$(MMSQUALIFIERS)
	set default [-.winfonts]
	$(MMS)$(MMSQUALIFIERS)
	set default [-.sdf]
	$(MMS)$(MMSQUALIFIERS)
	set default [--]

# EOF
$ eod
$ close out
$ write sys$output "... [.builds.vms] directory"
$ create [.builds.vms]descrip.mms
$ open/append out [.builds.vms]descrip.mms
$ copy sys$input: out
$ deck
#
# FreeType 2 system rules for VMS
#


# Copyright 2001-2019 by
# David Turner, Robert Wilhelm, and Werner Lemberg.
#
# This file is part of the FreeType project, and may only be used, modified,
# and distributed under the terms of the FreeType project license,
# LICENSE.TXT.  By continuing to use, modify, or distribute this file you
# indicate that you have read the license and understand and accept it
# fully.


CFLAGS=$(COMP_FLAGS)$(DEBUG)/list/show=all/include=([],[--.include],[--.src.base])
.ifdef X86
CXXFLAGS=$(CXXCOMP_FLAGS) -I[] -I[--.include] -I[--.src.base]
.endif

.ifdef X86
.c.obj :
	clang $(CXXFLAGS) -o $(MMS$TARGET_NAME)_cxx.obj $(MMS$TARGET_NAME).c
	cc$(CFLAGS)/warn=noinfo/point=32/list/show=all $(MMS$TARGET_NAME).c
	pipe link/map/full/exec=nl: $(MMS$TARGET_NAME).obj | copy sys$input nl:
	mc sys$library:vms_auto64 $(MMS$TARGET_NAME).map
	cc$(CFLAGS)/warn=(noinfo,disable=(MAYLOSEDATA3))/point=64/obj=$(MMS$TARGET_NAME)_64.obj\
	$(MMS$TARGET_NAME)_64.c
	clang $(CXXFLAGS) -o $(MMS$TARGET_NAME)_64_cxx.obj $(MMS$TARGET_NAME)_64.c
	delete $(MMS$TARGET_NAME)_64.c;*
.else
.c.obj :
	cc$(CFLAGS)/warn=noinfo/point=32/list/show=all $(MMS$TARGET_NAME).c
	pipe link/map/full/exec=nl: $(MMS$TARGET_NAME).obj | copy sys$input nl:
	mc sys$library:vms_auto64 $(MMS$TARGET_NAME).map
	cc$(CFLAGS)/warn=noinfo/point=64/obj=$(MMS$TARGET_NAME)_64.obj\
	$(MMS$TARGET_NAME)_64.c
	delete $(MMS$TARGET_NAME)_64.c;*
.endif

OBJS=ftsystem.obj

OBJS64=ftsystem_64.obj

OBJSCXX=ftsystem_cxx.obj

all : $(OBJS)
	library/create [--.lib]freetype.olb $(OBJS)
	library [--.lib]freetype.olb $(OBJS64)
.ifdef X86
	library/create [--.lib]freetype_cxx.olb $(OBJSCXX)
	library [--.lib]freetype_cxx.olb $(OBJS64)
.endif

ftsystem.obj : ftsystem.c ftconfig.h

# EOF
$ eod
$ close out
$ write sys$output "... [.src.autofit] directory"
$ create [.src.autofit]descrip.mms
$ open/append out [.src.autofit]descrip.mms
$ copy sys$input: out
$ deck
#
# FreeType 2 auto-fit module compilation rules for VMS
#


# Copyright 2002-2019 by
# David Turner, Robert Wilhelm, and Werner Lemberg.
#
# This file is part of the FreeType project, and may only be used, modified,
# and distributed under the terms of the FreeType project license,
# LICENSE.TXT.  By continuing to use, modify, or distribute this file you
# indicate that you have read the license and understand and accept it
# fully.

CFLAGS=$(COMP_FLAGS)$(DEBUG)/include=([--.include],[--.src.autofit])
.ifdef X86
CXXFLAGS=$(CXXCOMP_FLAGS) -I[] -I[--.include] -I[--.src.base] -Isys$library
.endif

.ifdef X86
.c.obj :
	clang $(CXXFLAGS) -o $(MMS$TARGET_NAME)_cxx.obj $(MMS$TARGET_NAME).c
	cc$(CFLAGS)/warn=noinfo/point=32/list/show=all $(MMS$TARGET_NAME).c
	pipe link/map/full/exec=nl: $(MMS$TARGET_NAME).obj | copy sys$input nl:
	mc sys$library:vms_auto64 $(MMS$TARGET_NAME).map nl: exclude hb_
	cc$(CFLAGS)/warn=(noinfo,disable=(MAYLOSEDATA3))/point=64/obj=$(MMS$TARGET_NAME)_64.obj\
	$(MMS$TARGET_NAME)_64.c
	clang $(CXXFLAGS) -o $(MMS$TARGET_NAME)_64_cxx.obj $(MMS$TARGET_NAME)_64.c
	delete $(MMS$TARGET_NAME)_64.c;*
.else
.c.obj :
	cc$(CFLAGS)/warn=noinfo/point=32/list/show=all $(MMS$TARGET_NAME).c
	pipe link/map/full/exec=nl: $(MMS$TARGET_NAME).obj | copy sys$input nl:
	mc sys$library:vms_auto64 $(MMS$TARGET_NAME).map
	cc$(CFLAGS)/warn=(noinfo,disable=(MAYLOSEDATA3))/point=64/obj=$(MMS$TARGET_NAME)_64.obj\
	$(MMS$TARGET_NAME)_64.c
	delete $(MMS$TARGET_NAME)_64.c;*
.endif

OBJS=autofit.obj

OBJS64=autofit_64.obj

OBJSCXX=autofit_cxx.obj

all : $(OBJS)
	library [--.lib]freetype.olb $(OBJS)
	library [--.lib]freetype.olb $(OBJS64)
.ifdef X86
	library [--.lib]freetype_cxx.olb $(OBJSCXX)
	library [--.lib]freetype_cxx.olb $(OBJS64)
.endif

# EOF
$ eod
$ close out
$ write sys$output "... [.src.base] directory"
$ create [.src.base]descrip.mms
$ open/append out [.src.base]descrip.mms
$ copy sys$input: out
$ deck
#
# FreeType 2 base layer compilation rules for VMS
#


# Copyright 2001-2019 by
# David Turner, Robert Wilhelm, and Werner Lemberg.
#
# This file is part of the FreeType project, and may only be used, modified,
# and distributed under the terms of the FreeType project license,
# LICENSE.TXT.  By continuing to use, modify, or distribute this file you
# indicate that you have read the license and understand and accept it
# fully.


CFLAGS=$(COMP_FLAGS)$(DEBUG)/include=([--.builds.vms],[--.include],[--.src.base])
.ifdef X86
CXXFLAGS=$(CXXCOMP_FLAGS) -I[] -I[--.include] -I[--.src.base]
.endif

.ifdef X86
.c.obj :
	clang $(CXXFLAGS) -o $(MMS$TARGET_NAME)_cxx.obj $(MMS$TARGET_NAME).c
	cc$(CFLAGS)/warn=noinfo/point=32/list/show=all $(MMS$TARGET_NAME).c
	pipe link/map/full/exec=nl: $(MMS$TARGET_NAME).obj | copy sys$input nl:
	mc sys$library:vms_auto64 $(MMS$TARGET_NAME).map
	cc$(CFLAGS)/warn=(noinfo,disable=(MAYLOSEDATA3))/point=64/obj=$(MMS$TARGET_NAME)_64.obj\
	$(MMS$TARGET_NAME)_64.c
	clang $(CXXFLAGS) -o $(MMS$TARGET_NAME)_64_cxx.obj $(MMS$TARGET_NAME)_64.c
	delete $(MMS$TARGET_NAME)_64.c;*
.else
.c.obj :
	cc$(CFLAGS)/warn=noinfo/point=32/list/show=all $(MMS$TARGET_NAME).c
	pipe link/map/full/exec=nl: $(MMS$TARGET_NAME).obj | copy sys$input nl:
	mc sys$library:vms_auto64 $(MMS$TARGET_NAME).map
	cc$(CFLAGS)/warn=(noinfo,disable=(MAYLOSEDATA3))/point=64/obj=$(MMS$TARGET_NAME)_64.obj\
	$(MMS$TARGET_NAME)_64.c
	delete $(MMS$TARGET_NAME)_64.c;*
.endif

OBJS=ftbase.obj,\
     ftbbox.obj,\
     ftbdf.obj,\
     ftbitmap.obj,\
     ftcid.obj,\
     ftdebug.obj,\
     ftfstype.obj,\
     ftgasp.obj,\
     ftglyph.obj,\
     ftinit.obj,\
     ftmm.obj,\
     ftpfr.obj,\
     ftstroke.obj,\
     ftsynth.obj,\
     fttype1.obj,\
     ftwinfnt.obj,ftpatent.obj,ftgxval.obj,ftotval.obj

OBJS64=ftbase_64.obj,\
     ftbbox_64.obj,\
     ftbdf_64.obj,\
     ftbitmap_64.obj,\
     ftcid_64.obj,\
     ftdebug_64.obj,\
     ftfstype_64.obj,\
     ftgasp_64.obj,\
     ftglyph_64.obj,\
     ftinit_64.obj,\
     ftmm_64.obj,\
     ftpfr_64.obj,\
     ftstroke_64.obj,\
     ftsynth_64.obj,\
     fttype1_64.obj,\
     ftwinfnt_64.obj,ftpatent_64.obj,ftgxval_64.obj,ftotval_64.obj

OBJSCXX=ftbase_cxx.obj,\
     ftbbox_cxx.obj,\
     ftbdf_cxx.obj,\
     ftbitmap_cxx.obj,\
     ftcid_cxx.obj,\
     ftdebug_cxx.obj,\
     ftfstype_cxx.obj,\
     ftgasp_cxx.obj,\
     ftglyph_cxx.obj,\
     ftinit_cxx.obj,\
     ftmm_cxx.obj,\
     ftpfr_cxx.obj,\
     ftstroke_cxx.obj,\
     ftsynth_cxx.obj,\
     fttype1_cxx.obj,\
     ftwinfnt_cxx.obj,ftpatent_cxx.obj,ftgxval_cxx.obj,ftotval_cxx.obj

all : $(OBJS)
	library [--.lib]freetype.olb $(OBJS)
	library [--.lib]freetype.olb $(OBJS64)
.ifdef X86
	library [--.lib]freetype_cxx.olb $(OBJSCXX)
	library [--.lib]freetype_cxx.olb $(OBJS64)
.endif

ftbase.obj : ftbase.c ftadvanc.c ftcalc.c ftcolor.c ftdbgmem.c fterrors.c\
	ftfntfmt.c ftgloadr.c fthash.c ftlcdfil.c ftmac.c ftobjs.c ftoutln.c\
	ftpsprop.c ftrfork.c ftsnames.c ftstream.c fttrigon.c ftutil.c


# EOF
$ eod
$ close out
$ write sys$output "... [.src.bdf] directory"
$ create [.src.bdf]descrip.mms
$ open/append out [.src.bdf]descrip.mms
$ copy sys$input: out
$ deck
#
# FreeType 2 BDF driver compilation rules for VMS
#


# Copyright 2002-2019 by
# David Turner, Robert Wilhelm, and Werner Lemberg.
#
# This file is part of the FreeType project, and may only be used, modified,
# and distributed under the terms of the FreeType project license,
# LICENSE.TXT.  By continuing to use, modify, or distribute this file you
# indicate that you have read the license and understand and accept it
# fully.


CFLAGS=$(COMP_FLAGS)$(DEBUG)/include=([--.include],[--.src.bdf])
.ifdef X86
CXXFLAGS=$(CXXCOMP_FLAGS) -I[] -I[--.include] -I[--.src.base])
.endif

.ifdef X86
.c.obj :
	clang $(CXXFLAGS) -o $(MMS$TARGET_NAME)_cxx.obj $(MMS$TARGET_NAME).c
	cc$(CFLAGS)/warn=noinfo/point=32/list/show=all $(MMS$TARGET_NAME).c
	pipe link/map/full/exec=nl: $(MMS$TARGET_NAME).obj | copy sys$input nl:
	mc sys$library:vms_auto64 $(MMS$TARGET_NAME).map
	cc$(CFLAGS)/warn=(noinfo,disable=(MAYLOSEDATA3))/point=64/obj=$(MMS$TARGET_NAME)_64.obj\
	$(MMS$TARGET_NAME)_64.c
	clang $(CXXFLAGS) -o $(MMS$TARGET_NAME)_64_cxx.obj $(MMS$TARGET_NAME)_64.c
	delete $(MMS$TARGET_NAME)_64.c;*
.else
.c.obj :
	cc$(CFLAGS)/warn=noinfo/point=32/list/show=all $(MMS$TARGET_NAME).c
	pipe link/map/full/exec=nl: $(MMS$TARGET_NAME).obj | copy sys$input nl:
	mc sys$library:vms_auto64 $(MMS$TARGET_NAME).map
	cc$(CFLAGS)/warn=(noinfo,disable=(MAYLOSEDATA3))/point=64/obj=$(MMS$TARGET_NAME)_64.obj\
	$(MMS$TARGET_NAME)_64.c
	delete $(MMS$TARGET_NAME)_64.c;*
.endif

OBJS=bdf.obj

OBJS64=bdf_64.obj

OBJSCXX=bdf_cxx.obj

all : $(OBJS)
	library [--.lib]freetype.olb $(OBJS)
	library [--.lib]freetype.olb $(OBJS64)
.ifdef X86
	library [--.lib]freetype_cxx.olb $(OBJSCXX)
	library [--.lib]freetype_cxx.olb $(OBJS64)
.endif

# EOF
$ eod
$ close out
$ write sys$output "... [.src.cache] directory"
$ create [.src.cache]descrip.mms
$ open/append out [.src.cache]descrip.mms
$ copy sys$input: out
$ deck
#
# FreeType 2 Cache compilation rules for VMS
#


# Copyright 2001-2019 by
# David Turner, Robert Wilhelm, and Werner Lemberg.
#
# This file is part of the FreeType project, and may only be used, modified,
# and distributed under the terms of the FreeType project license,
# LICENSE.TXT.  By continuing to use, modify, or distribute this file you
# indicate that you have read the license and understand and accept it
# fully.


CFLAGS=$(COMP_FLAGS)$(DEBUG)/include=([--.include],[--.src.cache])/nowarn
.ifdef X86
CXXFLAGS=$(CXXCOMP_FLAGS) -I[] -I[--.include] -I[--.src.base]
.endif

.ifdef X86
.c.obj :
	clang $(CXXFLAGS) -o $(MMS$TARGET_NAME)_cxx.obj $(MMS$TARGET_NAME).c
	cc$(CFLAGS)/warn=noinfo/point=32/list/show=all $(MMS$TARGET_NAME).c
	pipe link/map/full/exec=nl: $(MMS$TARGET_NAME).obj | copy sys$input nl:
	mc sys$library:vms_auto64 $(MMS$TARGET_NAME).map
	cc$(CFLAGS)/warn=(noinfo,disable=(MAYLOSEDATA3))/point=64/obj=$(MMS$TARGET_NAME)_64.obj\
	$(MMS$TARGET_NAME)_64.c
	clang $(CXXFLAGS) -o $(MMS$TARGET_NAME)_64_cxx.obj $(MMS$TARGET_NAME)_64.c
	delete $(MMS$TARGET_NAME)_64.c;*
.else
.c.obj :
	cc$(CFLAGS)/warn=noinfo/point=32/list/show=all $(MMS$TARGET_NAME).c
	pipe link/map/full/exec=nl: $(MMS$TARGET_NAME).obj | copy sys$input nl:
	mc sys$library:vms_auto64 $(MMS$TARGET_NAME).map
	cc$(CFLAGS)/warn=(noinfo,disable=(MAYLOSEDATA3))/point=64/obj=$(MMS$TARGET_NAME)_64.obj\
	$(MMS$TARGET_NAME)_64.c
	delete $(MMS$TARGET_NAME)_64.c;*
.endif

OBJS=ftcache.obj

OBJS64=ftcache_64.obj

OBJSCXX=ftcache_cxx.obj

all : $(OBJS)
	library [--.lib]freetype.olb $(OBJS)
	library [--.lib]freetype.olb $(OBJS64)
.ifdef X86
	library [--.lib]freetype_cxx.olb $(OBJSCXX)
	library [--.lib]freetype_cxx.olb $(OBJS64)
.endif

ftcache.obj : ftcache.c ftcbasic.c ftccache.c ftccmap.c ftcglyph.c ftcimage.c \
	ftcmanag.c ftcmru.c ftcsbits.c

# EOF
$ eod
$ close out
$ write sys$output "... [.src.cff] directory"
$ create [.src.cff]descrip.mms
$ open/append out [.src.cff]descrip.mms
$ copy sys$input: out
$ deck
#
# FreeType 2 OpenType/CFF driver compilation rules for VMS
#


# Copyright 2001-2019 by
# David Turner, Robert Wilhelm, and Werner Lemberg.
#
# This file is part of the FreeType project, and may only be used, modified,
# and distributed under the terms of the FreeType project license,
# LICENSE.TXT.  By continuing to use, modify, or distribute this file you
# indicate that you have read the license and understand and accept it
# fully.


CFLAGS=$(COMP_FLAGS)$(DEBUG)/include=([--.include],[--.src.cff])
.ifdef X86
CXXFLAGS=$(CXXCOMP_FLAGS) -I[] -I[--.include] -I[--.src.base]
.endif

.ifdef X86
.c.obj :
	clang $(CXXFLAGS) -o $(MMS$TARGET_NAME)_cxx.obj $(MMS$TARGET_NAME).c
	cc$(CFLAGS)/warn=noinfo/point=32/list/show=all $(MMS$TARGET_NAME).c
	pipe link/map/full/exec=nl: $(MMS$TARGET_NAME).obj | copy sys$input nl:
	mc sys$library:vms_auto64 $(MMS$TARGET_NAME).map
	cc$(CFLAGS)/warn=(noinfo,disable=(MAYLOSEDATA3))/point=64/obj=$(MMS$TARGET_NAME)_64.obj\
	$(MMS$TARGET_NAME)_64.c
	clang $(CXXFLAGS) -o $(MMS$TARGET_NAME)_64_cxx.obj $(MMS$TARGET_NAME)_64.c
	delete $(MMS$TARGET_NAME)_64.c;*
.else
.c.obj :
	cc$(CFLAGS)/warn=noinfo/point=32/list/show=all $(MMS$TARGET_NAME).c
	pipe link/map/full/exec=nl: $(MMS$TARGET_NAME).obj | copy sys$input nl:
	mc sys$library:vms_auto64 $(MMS$TARGET_NAME).map
	cc$(CFLAGS)/warn=(noinfo,disable=(MAYLOSEDATA3))/point=64/obj=$(MMS$TARGET_NAME)_64.obj\
	$(MMS$TARGET_NAME)_64.c
	delete $(MMS$TARGET_NAME)_64.c;*
.endif

OBJS=cff.obj

OBJS64=cff_64.obj

OBJSCXX=cff_cxx.obj

all : $(OBJS)
	library [--.lib]freetype.olb $(OBJS)
	library [--.lib]freetype.olb $(OBJS64)
.ifdef X86
	library [--.lib]freetype_cxx.olb $(OBJSCXX)
	library [--.lib]freetype_cxx.olb $(OBJS64)
.endif

# EOF
$ eod
$ close out
$ write sys$output "... [.src.cid] directory"
$ create [.src.cid]descrip.mms
$ open/append out [.src.cid]descrip.mms
$ copy sys$input: out
$ deck
#
# FreeType 2 CID driver compilation rules for VMS
#


# Copyright 2001-2019 by
# David Turner, Robert Wilhelm, and Werner Lemberg.
#
# This file is part of the FreeType project, and may only be used, modified,
# and distributed under the terms of the FreeType project license,
# LICENSE.TXT.  By continuing to use, modify, or distribute this file you
# indicate that you have read the license and understand and accept it
# fully.


CFLAGS=$(COMP_FLAGS)$(DEBUG)/include=([--.include],[--.src.cid])
.ifdef X86
CXXFLAGS=$(CXXCOMP_FLAGS) -I[] -I[--.include] -I[--.src.base]
.endif

.ifdef X86
.c.obj :
	clang $(CXXFLAGS) -o $(MMS$TARGET_NAME)_cxx.obj $(MMS$TARGET_NAME).c
	cc$(CFLAGS)/warn=noinfo/point=32/list/show=all $(MMS$TARGET_NAME).c
	pipe link/map/full/exec=nl: $(MMS$TARGET_NAME).obj | copy sys$input nl:
	mc sys$library:vms_auto64 $(MMS$TARGET_NAME).map
	cc$(CFLAGS)/warn=(noinfo,disable=(MAYLOSEDATA3))/point=64/obj=$(MMS$TARGET_NAME)_64.obj\
	$(MMS$TARGET_NAME)_64.c
	clang $(CXXFLAGS) -o $(MMS$TARGET_NAME)_64_cxx.obj $(MMS$TARGET_NAME)_64.c
	delete $(MMS$TARGET_NAME)_64.c;*
.else
.c.obj :
	cc$(CFLAGS)/warn=noinfo/point=32/list/show=all $(MMS$TARGET_NAME).c
	pipe link/map/full/exec=nl: $(MMS$TARGET_NAME).obj | copy sys$input nl:
	mc sys$library:vms_auto64 $(MMS$TARGET_NAME).map
	cc$(CFLAGS)/warn=(noinfo,disable=(MAYLOSEDATA3))/point=64/obj=$(MMS$TARGET_NAME)_64.obj\
	$(MMS$TARGET_NAME)_64.c
	delete $(MMS$TARGET_NAME)_64.c;*
.endif

OBJS=type1cid.obj

OBJS64=type1cid_64.obj

OBJSCXX=type1cid_cxx.obj

all : $(OBJS)
	library [--.lib]freetype.olb $(OBJS)
	library [--.lib]freetype.olb $(OBJS64)
.ifdef X86
	library [--.lib]freetype_cxx.olb $(OBJSCXX)
	library [--.lib]freetype_cxx.olb $(OBJS64)
.endif

# EOF
$ eod
$ close out
$ write sys$output "... [.src.gxvalid] directory"
$ create [.src.gxvalid]descrip.mms
$ open/append out [.src.gxvalid]descrip.mms
$ copy sys$input: out
$ deck
#
# FreeType 2 TrueTypeGX/AAT validation driver configuration rules for VMS
#


# Copyright 2004-2019 by
# David Turner, Robert Wilhelm, and Werner Lemberg.
#
# This file is part of the FreeType project, and may only be used, modified,
# and distributed under the terms of the FreeType project license,
# LICENSE.TXT.  By continuing to use, modify, or distribute this file you
# indicate that you have read the license and understand and accept it
# fully.


CFLAGS=$(COMP_FLAGS)$(DEBUG)/include=([--.include],[--.src.gxvalid])
.ifdef X86
CXXFLAGS=$(CXXCOMP_FLAGS) -I[] -I[--.include] -I[--.src.base]
.endif

.ifdef X86
.c.obj :
	clang $(CXXFLAGS) -o $(MMS$TARGET_NAME)_cxx.obj $(MMS$TARGET_NAME).c
	cc$(CFLAGS)/warn=noinfo/point=32/list/show=all $(MMS$TARGET_NAME).c
	pipe link/map/full/exec=nl: $(MMS$TARGET_NAME).obj | copy sys$input nl:
	mc sys$library:vms_auto64 $(MMS$TARGET_NAME).map
	cc$(CFLAGS)/warn=(noinfo,disable=(MAYLOSEDATA3))/point=64/obj=$(MMS$TARGET_NAME)_64.obj\
	$(MMS$TARGET_NAME)_64.c
	clang $(CXXFLAGS) -o $(MMS$TARGET_NAME)_64_cxx.obj $(MMS$TARGET_NAME)_64.c
	delete $(MMS$TARGET_NAME)_64.c;*
.else
.c.obj :
	cc$(CFLAGS)/warn=noinfo/point=32/list/show=all $(MMS$TARGET_NAME).c
	pipe link/map/full/exec=nl: $(MMS$TARGET_NAME).obj | copy sys$input nl:
	mc sys$library:vms_auto64 $(MMS$TARGET_NAME).map
	cc$(CFLAGS)/warn=(noinfo,disable=(MAYLOSEDATA3))/point=64/obj=$(MMS$TARGET_NAME)_64.obj\
	$(MMS$TARGET_NAME)_64.c
	delete $(MMS$TARGET_NAME)_64.c;*
.endif

OBJS=gxvalid.obj

OBJS64=gxvalid_64.obj

OBJSCXX=gxvalid_cxx.obj

all : $(OBJS)
	library [--.lib]freetype.olb $(OBJS)
	library [--.lib]freetype.olb $(OBJS64)
.ifdef X86
	library [--.lib]freetype_cxx.olb $(OBJSCXX)
	library [--.lib]freetype_cxx.olb $(OBJS64)
.endif

# EOF
$ eod
$ close out
$ write sys$output "... [.src.gzip] directory"
$ create [.src.gzip]descrip.mms
$ open/append out [.src.gzip]descrip.mms
$ copy sys$input: out
$ deck
#
# FreeType 2 GZip support compilation rules for VMS
#


# Copyright 2002-2019 by
# David Turner, Robert Wilhelm, and Werner Lemberg.
#
# This file is part of the FreeType project, and may only be used, modified,
# and distributed under the terms of the FreeType project license,
# LICENSE.TXT.  By continuing to use, modify, or distribute this file you
# indicate that you have read the license and understand and accept it
# fully.

CFLAGS=$(COMP_FLAGS)$(DEBUG)/include=([--.include],[--.src.gzip])
.ifdef X86
CXXFLAGS=$(CXXCOMP_FLAGS) -I[] -I[--.include] -I[--.src.base]
.endif

.ifdef X86
.c.obj :
	clang $(CXXFLAGS) -o $(MMS$TARGET_NAME)_cxx.obj $(MMS$TARGET_NAME).c
	cc$(CFLAGS)/warn=noinfo/point=32/list/show=all $(MMS$TARGET_NAME).c
	pipe link/map/full/exec=nl: $(MMS$TARGET_NAME).obj | copy sys$input nl:
	mc sys$library:vms_auto64 $(MMS$TARGET_NAME).map
	cc$(CFLAGS)/warn=(noinfo,disable=(MAYLOSEDATA3))/point=64/obj=$(MMS$TARGET_NAME)_64.obj\
	$(MMS$TARGET_NAME)_64.c
	clang $(CXXFLAGS) -o $(MMS$TARGET_NAME)_64_cxx.obj $(MMS$TARGET_NAME)_64.c
	delete $(MMS$TARGET_NAME)_64.c;*
.else
.c.obj :
	cc$(CFLAGS)/warn=noinfo/point=32/list/show=all $(MMS$TARGET_NAME).c
	pipe link/map/full/exec=nl: $(MMS$TARGET_NAME).obj | copy sys$input nl:
	mc sys$library:vms_auto64 $(MMS$TARGET_NAME).map
	cc$(CFLAGS)/warn=(noinfo,disable=(MAYLOSEDATA3))/point=64/obj=$(MMS$TARGET_NAME)_64.obj\
	$(MMS$TARGET_NAME)_64.c
	delete $(MMS$TARGET_NAME)_64.c;*
.endif

OBJS=ftgzip.obj

OBJS64=ftgzip_64.obj

OBJSCXX=ftgzip_cxx.obj

all : $(OBJS)
	library [--.lib]freetype.olb $(OBJS)
	library [--.lib]freetype.olb $(OBJS64)
.ifdef X86
	library [--.lib]freetype_cxx.olb $(OBJSCXX)
	library [--.lib]freetype_cxx.olb $(OBJS64)
.endif

# EOF
$ eod
$ close out
$ write sys$output "... [.src.bzip2] directory"
$ create [.src.bzip2]descrip.mms
$ open/append out [.src.bzip2]descrip.mms
$ copy sys$input: out
$ deck
#
# FreeType 2 BZIP2 support compilation rules for VMS
#


# Copyright 2010-2019 by
# Joel Klinghed.
#
# based on `src/lzw/rules.mk'
#
# This file is part of the FreeType project, and may only be used, modified,
# and distributed under the terms of the FreeType project license,
# LICENSE.TXT.  By continuing to use, modify, or distribute this file you
# indicate that you have read the license and understand and accept it
# fully.

CFLAGS=$(COMP_FLAGS)$(DEBUG)/include=([--.include],[--.src.bzip2])
.ifdef X86
CXXFLAGS=$(CXXCOMP_FLAGS) -I[] -I[--.include] -I[--.src.base] -Isys$library
.endif

.ifdef X86
.c.obj :
	clang $(CXXFLAGS) -o $(MMS$TARGET_NAME)_cxx.obj $(MMS$TARGET_NAME).c
	cc$(CFLAGS)/warn=noinfo/point=32/list/show=all $(MMS$TARGET_NAME).c
	pipe link/map/full/exec=nl: $(MMS$TARGET_NAME).obj | copy sys$input nl:
	mc sys$library:vms_auto64 $(MMS$TARGET_NAME).map
	cc$(CFLAGS)/warn=(noinfo,disable=(MAYLOSEDATA3))/point=64/obj=$(MMS$TARGET_NAME)_64.obj\
	$(MMS$TARGET_NAME)_64.c
	clang $(CXXFLAGS) -o $(MMS$TARGET_NAME)_64_cxx.obj $(MMS$TARGET_NAME)_64.c
	delete $(MMS$TARGET_NAME)_64.c;*
.else
.c.obj :
	cc$(CFLAGS)/warn=noinfo/point=32/list/show=all $(MMS$TARGET_NAME).c
	pipe link/map/full/exec=nl: $(MMS$TARGET_NAME).obj | copy sys$input nl:
	mc sys$library:vms_auto64 $(MMS$TARGET_NAME).map
	cc$(CFLAGS)/warn=(noinfo,disable=(MAYLOSEDATA3))/point=64/obj=$(MMS$TARGET_NAME)_64.obj\
	$(MMS$TARGET_NAME)_64.c
	delete $(MMS$TARGET_NAME)_64.c;*
.endif

OBJS=ftbzip2.obj

OBJS64=ftbzip2_64.obj

OBJSCXX=ftbzip2_cxx.obj

all : $(OBJS)
	library [--.lib]freetype.olb $(OBJS)
	library [--.lib]freetype.olb $(OBJS64)
.ifdef X86
	library [--.lib]freetype_cxx.olb $(OBJSCXX)
	library [--.lib]freetype_cxx.olb $(OBJS64)
.endif

# EOF
$ eod
$ close out
$ write sys$output "... [.src.lzw] directory"
$ create [.src.lzw]descrip.mms
$ open/append out [.src.lzw]descrip.mms
$ copy sys$input: out
$ deck
#
# FreeType 2 LZW support compilation rules for VMS
#


# Copyright 2004-2019 by
# David Turner, Robert Wilhelm, and Werner Lemberg.
#
# This file is part of the FreeType project, and may only be used, modified,
# and distributed under the terms of the FreeType project license,
# LICENSE.TXT.  By continuing to use, modify, or distribute this file you
# indicate that you have read the license and understand and accept it
# fully.

CFLAGS=$(COMP_FLAGS)$(DEBUG)/include=([--.include],[--.src.lzw])
.ifdef X86
CXXFLAGS=$(CXXCOMP_FLAGS) -I[] -I[--.include] -I[--.src.base]
.endif

.ifdef X86
.c.obj :
	clang $(CXXFLAGS) -o $(MMS$TARGET_NAME)_cxx.obj $(MMS$TARGET_NAME).c
	cc$(CFLAGS)/warn=noinfo/point=32/list/show=all $(MMS$TARGET_NAME).c
	pipe link/map/full/exec=nl: $(MMS$TARGET_NAME).obj | copy sys$input nl:
	mc sys$library:vms_auto64 $(MMS$TARGET_NAME).map
	cc$(CFLAGS)/warn=(noinfo,disable=(MAYLOSEDATA3))/point=64/obj=$(MMS$TARGET_NAME)_64.obj\
	$(MMS$TARGET_NAME)_64.c
	clang $(CXXFLAGS) -o $(MMS$TARGET_NAME)_64_cxx.obj $(MMS$TARGET_NAME)_64.c
	delete $(MMS$TARGET_NAME)_64.c;*
.else
.c.obj :
	cc$(CFLAGS)/warn=noinfo/point=32/list/show=all $(MMS$TARGET_NAME).c
	pipe link/map/full/exec=nl: $(MMS$TARGET_NAME).obj | copy sys$input nl:
	mc sys$library:vms_auto64 $(MMS$TARGET_NAME).map
	cc$(CFLAGS)/warn=(noinfo,disable=(MAYLOSEDATA3))/point=64/obj=$(MMS$TARGET_NAME)_64.obj\
	$(MMS$TARGET_NAME)_64.c
	delete $(MMS$TARGET_NAME)_64.c;*
.endif

OBJS=ftlzw.obj

OBJS64=ftlzw_64.obj

OBJSCXX=ftlzw_cxx.obj

all : $(OBJS)
	library [--.lib]freetype.olb $(OBJS)
	library [--.lib]freetype.olb $(OBJS64)
.ifdef X86
	library [--.lib]freetype_cxx.olb $(OBJSCXX)
	library [--.lib]freetype_cxx.olb $(OBJS64)
.endif

# EOF
$ eod
$ close out
$ write sys$output "... [.src.otvalid] directory"
$ create [.src.otvalid]descrip.mms
$ open/append out [.src.otvalid]descrip.mms
$ copy sys$input: out
$ deck
#
# FreeType 2 OpenType validation module compilation rules for VMS
#


# Copyright 2004-2019 by
# David Turner, Robert Wilhelm, and Werner Lemberg.
#
# This file is part of the FreeType project, and may only be used, modified,
# and distributed under the terms of the FreeType project license,
# LICENSE.TXT.  By continuing to use, modify, or distribute this file you
# indicate that you have read the license and understand and accept it
# fully.


CFLAGS=$(COMP_FLAGS)$(DEBUG)/include=([--.include],[--.src.otvalid])
.ifdef X86
CXXFLAGS=$(CXXCOMP_FLAGS) -I[] -I[--.include] -I[--.src.base]
.endif

.ifdef X86
.c.obj :
	clang $(CXXFLAGS) -o $(MMS$TARGET_NAME)_cxx.obj $(MMS$TARGET_NAME).c
	cc$(CFLAGS)/warn=noinfo/point=32/list/show=all $(MMS$TARGET_NAME).c
	pipe link/map/full/exec=nl: $(MMS$TARGET_NAME).obj | copy sys$input nl:
	mc sys$library:vms_auto64 $(MMS$TARGET_NAME).map
	cc$(CFLAGS)/warn=(noinfo,disable=(MAYLOSEDATA3))/point=64/obj=$(MMS$TARGET_NAME)_64.obj\
	$(MMS$TARGET_NAME)_64.c
	clang $(CXXFLAGS) -o $(MMS$TARGET_NAME)_64_cxx.obj $(MMS$TARGET_NAME)_64.c
	delete $(MMS$TARGET_NAME)_64.c;*
.else
.c.obj :
	cc$(CFLAGS)/warn=noinfo/point=32/list/show=all $(MMS$TARGET_NAME).c
	pipe link/map/full/exec=nl: $(MMS$TARGET_NAME).obj | copy sys$input nl:
	mc sys$library:vms_auto64 $(MMS$TARGET_NAME).map
	cc$(CFLAGS)/warn=(noinfo,disable=(MAYLOSEDATA3))/point=64/obj=$(MMS$TARGET_NAME)_64.obj\
	$(MMS$TARGET_NAME)_64.c
	delete $(MMS$TARGET_NAME)_64.c;*
.endif

OBJS=otvalid.obj

OBJS64=otvalid_64.obj

OBJSCXX=otvalid_cxx.obj

all : $(OBJS)
	library [--.lib]freetype.olb $(OBJS)
	library [--.lib]freetype.olb $(OBJS64)
.ifdef X86
	library [--.lib]freetype_cxx.olb $(OBJSCXX)
	library [--.lib]freetype_cxx.olb $(OBJS64)
.endif

# EOF
$ eod
$ close out
$ write sys$output "... [.src.pcf] directory"
$ create [.src.pcf]descrip.mms
$ open/append out [.src.pcf]descrip.mms
$ copy sys$input: out
$ deck
#
# FreeType 2 pcf driver compilation rules for VMS
#


# Copyright (C) 2001, 2002 by
# Francesco Zappa Nardelli
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.  IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
# THE SOFTWARE.


CFLAGS=$(COMP_FLAGS)$(DEBUG)/include=([--.include],[--.src.pcf])
.ifdef X86
CXXFLAGS=$(CXXCOMP_FLAGS) -I[] -I[--.include] -I[--.src.base]
.endif

.ifdef X86
.c.obj :
	clang $(CXXFLAGS) -o $(MMS$TARGET_NAME)_cxx.obj $(MMS$TARGET_NAME).c
	cc$(CFLAGS)/warn=noinfo/point=32/list/show=all $(MMS$TARGET_NAME).c
	pipe link/map/full/exec=nl: $(MMS$TARGET_NAME).obj | copy sys$input nl:
	mc sys$library:vms_auto64 $(MMS$TARGET_NAME).map
	cc$(CFLAGS)/warn=(noinfo,disable=(MAYLOSEDATA3))/point=64/obj=$(MMS$TARGET_NAME)_64.obj\
	$(MMS$TARGET_NAME)_64.c
	clang $(CXXFLAGS) -o $(MMS$TARGET_NAME)_64_cxx.obj $(MMS$TARGET_NAME)_64.c
	delete $(MMS$TARGET_NAME)_64.c;*
.else
.c.obj :
	cc$(CFLAGS)/warn=noinfo/point=32/list/show=all $(MMS$TARGET_NAME).c
	pipe link/map/full/exec=nl: $(MMS$TARGET_NAME).obj | copy sys$input nl:
	mc sys$library:vms_auto64 $(MMS$TARGET_NAME).map
	cc$(CFLAGS)/warn=(noinfo,disable=(MAYLOSEDATA3))/point=64/obj=$(MMS$TARGET_NAME)_64.obj\
	$(MMS$TARGET_NAME)_64.c
	delete $(MMS$TARGET_NAME)_64.c;*
.endif

OBJS=pcf.obj

OBJS64=pcf_64.obj

OBJSCXX=pcf_cxx.obj

all : $(OBJS)
	library [--.lib]freetype.olb $(OBJS)
	library [--.lib]freetype.olb $(OBJS64)
.ifdef X86
	library [--.lib]freetype_cxx.olb $(OBJSCXX)
	library [--.lib]freetype_cxx.olb $(OBJS64)
.endif

# EOF
$ eod
$ close out
$ write sys$output "... [.src.pfr] directory"
$ create [.src.pfr]descrip.mms
$ open/append out [.src.pfr]descrip.mms
$ copy sys$input: out
$ deck
#
# FreeType 2 PFR driver compilation rules for VMS
#


# Copyright 2002-2019 by
# David Turner, Robert Wilhelm, and Werner Lemberg.
#
# This file is part of the FreeType project, and may only be used, modified,
# and distributed under the terms of the FreeType project license,
# LICENSE.TXT.  By continuing to use, modify, or distribute this file you
# indicate that you have read the license and understand and accept it
# fully.


CFLAGS=$(COMP_FLAGS)$(DEBUG)/include=([--.include],[--.src.pfr])
.ifdef X86
CXXFLAGS=$(CXXCOMP_FLAGS) -I[] -I[--.include] -I[--.src.base]
.endif

.ifdef X86
.c.obj :
	clang $(CXXFLAGS) -o $(MMS$TARGET_NAME)_cxx.obj $(MMS$TARGET_NAME).c
	cc$(CFLAGS)/warn=noinfo/point=32/list/show=all $(MMS$TARGET_NAME).c
	pipe link/map/full/exec=nl: $(MMS$TARGET_NAME).obj | copy sys$input nl:
	mc sys$library:vms_auto64 $(MMS$TARGET_NAME).map
	cc$(CFLAGS)/warn=(noinfo,disable=(MAYLOSEDATA3))/point=64/obj=$(MMS$TARGET_NAME)_64.obj\
	$(MMS$TARGET_NAME)_64.c
	clang $(CXXFLAGS) -o $(MMS$TARGET_NAME)_64_cxx.obj $(MMS$TARGET_NAME)_64.c
	delete $(MMS$TARGET_NAME)_64.c;*
.else
.c.obj :
	cc$(CFLAGS)/warn=noinfo/point=32/list/show=all $(MMS$TARGET_NAME).c
	pipe link/map/full/exec=nl: $(MMS$TARGET_NAME).obj | copy sys$input nl:
	mc sys$library:vms_auto64 $(MMS$TARGET_NAME).map
	cc$(CFLAGS)/warn=(noinfo,disable=(MAYLOSEDATA3))/point=64/obj=$(MMS$TARGET_NAME)_64.obj\
	$(MMS$TARGET_NAME)_64.c
	delete $(MMS$TARGET_NAME)_64.c;*
.endif

OBJS=pfr.obj

OBJS64=pfr_64.obj

OBJSCXX=pfr_cxx.obj

all : $(OBJS)
	library [--.lib]freetype.olb $(OBJS)
	library [--.lib]freetype.olb $(OBJS64)
.ifdef X86
	library [--.lib]freetype_cxx.olb $(OBJSCXX)
	library [--.lib]freetype_cxx.olb $(OBJS64)
.endif

# EOF
$ eod
$ close out
$ write sys$output "... [.src.psaux] directory"
$ create [.src.psaux]descrip.mms
$ open/append out [.src.psaux]descrip.mms
$ copy sys$input: out
$ deck
#
# FreeType 2 PSaux driver compilation rules for VMS
#


# Copyright 2001-2019 by
# David Turner, Robert Wilhelm, and Werner Lemberg.
#
# This file is part of the FreeType project, and may only be used, modified,
# and distributed under the terms of the FreeType project license,
# LICENSE.TXT.  By continuing to use, modify, or distribute this file you
# indicate that you have read the license and understand and accept it
# fully.


CFLAGS=$(COMP_FLAGS)$(DEBUG)/include=([--.include],[--.src.psaux])
.ifdef X86
CXXFLAGS=$(CXXCOMP_FLAGS) -I[] -I[--.include] -I[--.src.base]
.endif

.ifdef X86
.c.obj :
	clang $(CXXFLAGS) -o $(MMS$TARGET_NAME)_cxx.obj $(MMS$TARGET_NAME).c
	cc$(CFLAGS)/warn=noinfo/point=32/list/show=all $(MMS$TARGET_NAME).c
	pipe link/map/full/exec=nl: $(MMS$TARGET_NAME).obj | copy sys$input nl:
	mc sys$library:vms_auto64 $(MMS$TARGET_NAME).map
	cc$(CFLAGS)/warn=(noinfo,disable=(MAYLOSEDATA3))/point=64/obj=$(MMS$TARGET_NAME)_64.obj\
	$(MMS$TARGET_NAME)_64.c
	clang $(CXXFLAGS) -o $(MMS$TARGET_NAME)_64_cxx.obj $(MMS$TARGET_NAME)_64.c
	delete $(MMS$TARGET_NAME)_64.c;*
.else
.c.obj :
	cc$(CFLAGS)/warn=noinfo/point=32/list/show=all $(MMS$TARGET_NAME).c
	pipe link/map/full/exec=nl: $(MMS$TARGET_NAME).obj | copy sys$input nl:
	mc sys$library:vms_auto64 $(MMS$TARGET_NAME).map
	cc$(CFLAGS)/warn=(noinfo,disable=(MAYLOSEDATA3))/point=64/obj=$(MMS$TARGET_NAME)_64.obj\
	$(MMS$TARGET_NAME)_64.c
	delete $(MMS$TARGET_NAME)_64.c;*
.endif

OBJS=psaux.obj

OBJS64=psaux_64.obj

OBJSCXX=psaux_cxx.obj

all : $(OBJS)
	library [--.lib]freetype.olb $(OBJS)
	library [--.lib]freetype.olb $(OBJS64)
.ifdef X86
	library [--.lib]freetype_cxx.olb $(OBJSCXX)
	library [--.lib]freetype_cxx.olb $(OBJS64)
.endif

# EOF
$ eod
$ close out
$ write sys$output "... [.src.pshinter] directory"
$ create [.src.pshinter]descrip.mms
$ open/append out [.src.pshinter]descrip.mms
$ copy sys$input: out
$ deck
#
# FreeType 2 PSHinter driver compilation rules for OpenVMS
#


# Copyright 2001-2019 by
# David Turner, Robert Wilhelm, and Werner Lemberg.
#
# This file is part of the FreeType project, and may only be used, modified,
# and distributed under the terms of the FreeType project license,
# LICENSE.TXT.  By continuing to use, modify, or distribute this file you
# indicate that you have read the license and understand and accept it
# fully.


CFLAGS=$(COMP_FLAGS)$(DEBUG)/include=([--.include],[--.src.psnames])
.ifdef X86
CXXFLAGS=$(CXXCOMP_FLAGS) -I[] -I[--.include] -I[--.src.base]
.endif

.ifdef X86
.c.obj :
	clang $(CXXFLAGS) -o $(MMS$TARGET_NAME)_cxx.obj $(MMS$TARGET_NAME).c
	cc$(CFLAGS)/warn=noinfo/point=32/list/show=all $(MMS$TARGET_NAME).c
	pipe link/map/full/exec=nl: $(MMS$TARGET_NAME).obj | copy sys$input nl:
	mc sys$library:vms_auto64 $(MMS$TARGET_NAME).map
	cc$(CFLAGS)/warn=(noinfo,disable=(MAYLOSEDATA3))/point=64/obj=$(MMS$TARGET_NAME)_64.obj\
	$(MMS$TARGET_NAME)_64.c
	clang $(CXXFLAGS) -o $(MMS$TARGET_NAME)_64_cxx.obj $(MMS$TARGET_NAME)_64.c
	delete $(MMS$TARGET_NAME)_64.c;*
.else
.c.obj :
	cc$(CFLAGS)/warn=noinfo/point=32/list/show=all $(MMS$TARGET_NAME).c
	pipe link/map/full/exec=nl: $(MMS$TARGET_NAME).obj | copy sys$input nl:
	mc sys$library:vms_auto64 $(MMS$TARGET_NAME).map
	cc$(CFLAGS)/warn=(noinfo,disable=(MAYLOSEDATA3))/point=64/obj=$(MMS$TARGET_NAME)_64.obj\
	$(MMS$TARGET_NAME)_64.c
	delete $(MMS$TARGET_NAME)_64.c;*
.endif

OBJS=pshinter.obj

OBJS64=pshinter_64.obj

OBJSCXX=pshinter_cxx.obj

all : $(OBJS)
	library [--.lib]freetype.olb $(OBJS)
	library [--.lib]freetype.olb $(OBJS64)
.ifdef X86
	library [--.lib]freetype_cxx.olb $(OBJSCXX)
	library [--.lib]freetype_cxx.olb $(OBJS64)
.endif

# EOF
$ eod
$ close out
$ write sys$output "... [.src.psnames] directory"
$ create [.src.psnames]descrip.mms
$ open/append out [.src.psnames]descrip.mms
$ copy sys$input: out
$ deck
#
# FreeType 2 psnames driver compilation rules for VMS
#


# Copyright 2001-2019 by
# David Turner, Robert Wilhelm, and Werner Lemberg.
#
# This file is part of the FreeType project, and may only be used, modified,
# and distributed under the terms of the FreeType project license,
# LICENSE.TXT.  By continuing to use, modify, or distribute this file you
# indicate that you have read the license and understand and accept it
# fully.


CFLAGS=$(COMP_FLAGS)$(DEBUG)/include=([--.include],[--.src.psnames])
.ifdef X86
CXXFLAGS=$(CXXCOMP_FLAGS) -I[] -I[--.include] -I[--.src.base]
.endif

.ifdef X86
.c.obj :
	clang $(CXXFLAGS) -o $(MMS$TARGET_NAME)_cxx.obj $(MMS$TARGET_NAME).c
	cc$(CFLAGS)/warn=noinfo/point=32/list/show=all $(MMS$TARGET_NAME).c
	pipe link/map/full/exec=nl: $(MMS$TARGET_NAME).obj | copy sys$input nl:
	mc sys$library:vms_auto64 $(MMS$TARGET_NAME).map
	cc$(CFLAGS)/warn=(noinfo,disable=(MAYLOSEDATA3))/point=64/obj=$(MMS$TARGET_NAME)_64.obj\
	$(MMS$TARGET_NAME)_64.c
	clang $(CXXFLAGS) -o $(MMS$TARGET_NAME)_64_cxx.obj $(MMS$TARGET_NAME)_64.c
	delete $(MMS$TARGET_NAME)_64.c;*
.else
.c.obj :
	cc$(CFLAGS)/warn=noinfo/point=32/list/show=all $(MMS$TARGET_NAME).c
	pipe link/map/full/exec=nl: $(MMS$TARGET_NAME).obj | copy sys$input nl:
	mc sys$library:vms_auto64 $(MMS$TARGET_NAME).map
	cc$(CFLAGS)/warn=(noinfo,disable=(MAYLOSEDATA3))/point=64/obj=$(MMS$TARGET_NAME)_64.obj\
	$(MMS$TARGET_NAME)_64.c
	delete $(MMS$TARGET_NAME)_64.c;*
.endif

OBJS=psnames.obj

OBJS64=psnames_64.obj

OBJSCXX=psnames_cxx.obj

all : $(OBJS)
	library [--.lib]freetype.olb $(OBJS)
	library [--.lib]freetype.olb $(OBJS64)
.ifdef X86
	library [--.lib]freetype_cxx.olb $(OBJSCXX)
	library [--.lib]freetype_cxx.olb $(OBJS64)
.endif

# EOF
$ eod
$ close out
$ write sys$output "... [.src.raster] directory"
$ create [.src.raster]descrip.mms
$ open/append out [.src.raster]descrip.mms
$ copy sys$input: out
$ deck
#
# FreeType 2 renderer module compilation rules for VMS
#


# Copyright 2001-2019 by
# David Turner, Robert Wilhelm, and Werner Lemberg.
#
# This file is part of the FreeType project, and may only be used, modified,
# and distributed under the terms of the FreeType project license,
# LICENSE.TXT.  By continuing to use, modify, or distribute this file you
# indicate that you have read the license and understand and accept it
# fully.


CFLAGS=$(COMP_FLAGS)$(DEBUG)/include=([--.include],[--.src.raster])
.ifdef X86
CXXFLAGS=$(CXXCOMP_FLAGS) -I[] -I[--.include] -I[--.src.base]
.endif

.ifdef X86
.c.obj :
	clang $(CXXFLAGS) -o $(MMS$TARGET_NAME)_cxx.obj $(MMS$TARGET_NAME).c
	cc$(CFLAGS)/warn=noinfo/point=32/list/show=all $(MMS$TARGET_NAME).c
	pipe link/map/full/exec=nl: $(MMS$TARGET_NAME).obj | copy sys$input nl:
	mc sys$library:vms_auto64 $(MMS$TARGET_NAME).map
	cc$(CFLAGS)/warn=(noinfo,disable=(MAYLOSEDATA3))/point=64/obj=$(MMS$TARGET_NAME)_64.obj\
	$(MMS$TARGET_NAME)_64.c
	clang $(CXXFLAGS) -o $(MMS$TARGET_NAME)_64_cxx.obj $(MMS$TARGET_NAME)_64.c
	delete $(MMS$TARGET_NAME)_64.c;*
.else
.c.obj :
	cc$(CFLAGS)/warn=noinfo/point=32/list/show=all $(MMS$TARGET_NAME).c
	pipe link/map/full/exec=nl: $(MMS$TARGET_NAME).obj | copy sys$input nl:
	mc sys$library:vms_auto64 $(MMS$TARGET_NAME).map
	cc$(CFLAGS)/warn=(noinfo,disable=(MAYLOSEDATA3))/point=64/obj=$(MMS$TARGET_NAME)_64.obj\
	$(MMS$TARGET_NAME)_64.c
	delete $(MMS$TARGET_NAME)_64.c;*
.endif

OBJS=raster.obj

OBJS64=raster_64.obj

OBJSCXX=raster_cxx.obj

all : $(OBJS)
	library [--.lib]freetype.olb $(OBJS)
	library [--.lib]freetype.olb $(OBJS64)
.ifdef X86
	library [--.lib]freetype_cxx.olb $(OBJSCXX)
	library [--.lib]freetype_cxx.olb $(OBJS64)
.endif

# EOF
$ eod
$ close out
$ write sys$output "... [.src.sfnt] directory"
$ create [.src.sfnt]descrip.mms
$ open/append out [.src.sfnt]descrip.mms
$ copy sys$input: out
$ deck
#
# FreeType 2 SFNT driver compilation rules for VMS
#


# Copyright 2001-2019 by
# David Turner, Robert Wilhelm, and Werner Lemberg.
#
# This file is part of the FreeType project, and may only be used, modified,
# and distributed under the terms of the FreeType project license,
# LICENSE.TXT.  By continuing to use, modify, or distribute this file you
# indicate that you have read the license and understand and accept it
# fully.


CFLAGS=$(COMP_FLAGS)$(DEBUG)/include=([--.include],[--.src.sfnt])
.ifdef X86
CXXFLAGS=$(CXXCOMP_FLAGS) -I[] -I[--.include] -I[--.src.base] -Isys$library\
         -Wno-incompatible-pointer-types
.endif

.ifdef X86
.c.obj :
	clang $(CXXFLAGS) -o $(MMS$TARGET_NAME)_cxx.obj $(MMS$TARGET_NAME).c
	cc$(CFLAGS)/warn=noinfo/point=32/list/show=all $(MMS$TARGET_NAME).c
	pipe link/map/full/exec=nl: $(MMS$TARGET_NAME).obj | copy sys$input nl:
	mc sys$library:vms_auto64 $(MMS$TARGET_NAME).map
	cc$(CFLAGS)/warn=(noinfo,disable=(MAYLOSEDATA3))/point=64/obj=$(MMS$TARGET_NAME)_64.obj\
	$(MMS$TARGET_NAME)_64.c
	clang $(CXXFLAGS) -o $(MMS$TARGET_NAME)_64_cxx.obj $(MMS$TARGET_NAME)_64.c
	delete $(MMS$TARGET_NAME)_64.c;*
.else
.c.obj :
	cc$(CFLAGS)/warn=noinfo/point=32/list/show=all $(MMS$TARGET_NAME).c
	pipe link/map/full/exec=nl: $(MMS$TARGET_NAME).obj | copy sys$input nl:
	mc sys$library:vms_auto64 $(MMS$TARGET_NAME).map
	cc$(CFLAGS)/warn=(noinfo,disable=(MAYLOSEDATA3))/point=64/obj=$(MMS$TARGET_NAME)_64.obj\
	$(MMS$TARGET_NAME)_64.c
	delete $(MMS$TARGET_NAME)_64.c;*
.endif

OBJS=sfnt.obj

OBJS64=sfnt_64.obj

OBJSCXX=sfnt_cxx.obj

all : $(OBJS)
	library [--.lib]freetype.olb $(OBJS)
	library [--.lib]freetype.olb $(OBJS64)
.ifdef X86
	library [--.lib]freetype_cxx.olb $(OBJSCXX)
	library [--.lib]freetype_cxx.olb $(OBJS64)
.endif

# EOF
$ eod
$ close out
$ write sys$output "... [.src.smooth] directory"
$ create [.src.smooth]descrip.mms
$ open/append out [.src.smooth]descrip.mms
$ copy sys$input: out
$ deck
#
# FreeType 2 smooth renderer module compilation rules for VMS
#


# Copyright 2001-2019 by
# David Turner, Robert Wilhelm, and Werner Lemberg.
#
# This file is part of the FreeType project, and may only be used, modified,
# and distributed under the terms of the FreeType project license,
# LICENSE.TXT.  By continuing to use, modify, or distribute this file you
# indicate that you have read the license and understand and accept it
# fully.


CFLAGS=$(COMP_FLAGS)$(DEBUG)/include=([--.include],[--.src.smooth])
.ifdef X86
CXXFLAGS=$(CXXCOMP_FLAGS) -I [] -I[--.include] -I[--.src.base]
.endif

.ifdef X86
.c.obj :
	clang $(CXXFLAGS) -o $(MMS$TARGET_NAME)_cxx.obj $(MMS$TARGET_NAME).c
	cc$(CFLAGS)/warn=noinfo/point=32/list/show=all $(MMS$TARGET_NAME).c
	pipe link/map/full/exec=nl: $(MMS$TARGET_NAME).obj | copy sys$input nl:
	mc sys$library:vms_auto64 $(MMS$TARGET_NAME).map
	cc$(CFLAGS)/warn=(noinfo,disable=(MAYLOSEDATA3))/point=64/obj=$(MMS$TARGET_NAME)_64.obj\
	$(MMS$TARGET_NAME)_64.c
	clang $(CXXFLAGS) -o $(MMS$TARGET_NAME)_64_cxx.obj $(MMS$TARGET_NAME)_64.c
	delete $(MMS$TARGET_NAME)_64.c;*
.else
.c.obj :
	cc$(CFLAGS)/warn=noinfo/point=32/list/show=all $(MMS$TARGET_NAME).c
	pipe link/map/full/exec=nl: $(MMS$TARGET_NAME).obj | copy sys$input nl:
	mc sys$library:vms_auto64 $(MMS$TARGET_NAME).map
	cc$(CFLAGS)/warn=(noinfo,disable=(MAYLOSEDATA3))/point=64/obj=$(MMS$TARGET_NAME)_64.obj\
	$(MMS$TARGET_NAME)_64.c
	delete $(MMS$TARGET_NAME)_64.c;*
.endif

OBJS=smooth.obj

OBJS64=smooth_64.obj

OBJSCXX=smooth_cxx.obj

all : $(OBJS)
	library [--.lib]freetype.olb $(OBJS)
	library [--.lib]freetype.olb $(OBJS64)
.ifdef X86
	library [--.lib]freetype_cxx.olb $(OBJSCXX)
	library [--.lib]freetype_cxx.olb $(OBJS64)
.endif

# EOF
$ eod
$ close out
$ write sys$output "... [.src.svg] directory"
$ create [.src.svg]descrip.mms
$ open/append out [.src.svg]descrip.mms
$ copy sys$input: out
$ deck
#
# FreeType 2 smooth renderer module compilation rules for VMS
#


# Copyright 2001-2019 by
# David Turner, Robert Wilhelm, and Werner Lemberg.
#
# This file is part of the FreeType project, and may only be used, modified,
# and distributed under the terms of the FreeType project license,
# LICENSE.TXT.  By continuing to use, modify, or distribute this file you
# indicate that you have read the license and understand and accept it
# fully.


CFLAGS=$(COMP_FLAGS)$(DEBUG)/include=([--.include],[--.src.svg])
.ifdef X86
CXXFLAGS=$(CXXCOMP_FLAGS) -I[] -I[--.include] -I[--.src.base]
.endif

.ifdef X86
.c.obj :
	clang $(CXXFLAGS) -o $(MMS$TARGET_NAME)_cxx.obj $(MMS$TARGET_NAME).c
	cc$(CFLAGS)/warn=noinfo/point=32/list/show=all $(MMS$TARGET_NAME).c
	pipe link/map/full/exec=nl: $(MMS$TARGET_NAME).obj | copy sys$input nl:
	mc sys$library:vms_auto64 $(MMS$TARGET_NAME).map
	cc$(CFLAGS)/warn=(noinfo,disable=(MAYLOSEDATA3))/point=64/obj=$(MMS$TARGET_NAME)_64.obj\
	$(MMS$TARGET_NAME)_64.c
	clang $(CXXFLAGS) -o $(MMS$TARGET_NAME)_64_cxx.obj $(MMS$TARGET_NAME)_64.c
	delete $(MMS$TARGET_NAME)_64.c;*
.else
.c.obj :
	cc$(CFLAGS)/warn=noinfo/point=32/list/show=all $(MMS$TARGET_NAME).c
	pipe link/map/full/exec=nl: $(MMS$TARGET_NAME).obj | copy sys$input nl:
	mc sys$library:vms_auto64 $(MMS$TARGET_NAME).map
	cc$(CFLAGS)/warn=(noinfo,disable=(MAYLOSEDATA3))/point=64/obj=$(MMS$TARGET_NAME)_64.obj\
	$(MMS$TARGET_NAME)_64.c
	delete $(MMS$TARGET_NAME)_64.c;*
.endif

OBJS=svg.obj

OBJS64=svg_64.obj

OBJSCXX=svg_cxx.obj

all : $(OBJS)
	library [--.lib]freetype.olb $(OBJS)
	library [--.lib]freetype.olb $(OBJS64)
.ifdef X86
	library [--.lib]freetype_cxx.olb $(OBJSCXX)
	library [--.lib]freetype_cxx.olb $(OBJS64)
.endif

# EOF
$ eod
$ close out
$ write sys$output "... [.src.truetype] directory"
$ create [.src.truetype]descrip.mms
$ open/append out [.src.truetype]descrip.mms
$ copy sys$input: out
$ deck
#
# FreeType 2 TrueType driver compilation rules for VMS
#


# Copyright 2001-2019 by
# David Turner, Robert Wilhelm, and Werner Lemberg.
#
# This file is part of the FreeType project, and may only be used, modified,
# and distributed under the terms of the FreeType project license,
# LICENSE.TXT.  By continuing to use, modify, or distribute this file you
# indicate that you have read the license and understand and accept it
# fully.


CFLAGS=$(COMP_FLAGS)$(DEBUG)/include=([--.include],[--.src.truetype])
.ifdef X86
CXXFLAGS=$(CXXCOMP_FLAGS) -I[] -I[--.include] -I[--.src.base]
.endif

.ifdef X86
.c.obj :
	clang $(CXXFLAGS) -o $(MMS$TARGET_NAME)_cxx.obj $(MMS$TARGET_NAME).c
	cc$(CFLAGS)/warn=noinfo/point=32/list/show=all $(MMS$TARGET_NAME).c
	pipe link/map/full/exec=nl: $(MMS$TARGET_NAME).obj | copy sys$input nl:
	mc sys$library:vms_auto64 $(MMS$TARGET_NAME).map
	cc$(CFLAGS)/warn=(noinfo,disable=(MAYLOSEDATA3))/point=64/obj=$(MMS$TARGET_NAME)_64.obj\
	$(MMS$TARGET_NAME)_64.c
	clang $(CXXFLAGS) -o $(MMS$TARGET_NAME)_64_cxx.obj $(MMS$TARGET_NAME)_64.c
	delete $(MMS$TARGET_NAME)_64.c;*
.else
.c.obj :
	cc$(CFLAGS)/warn=noinfo/point=32/list/show=all $(MMS$TARGET_NAME).c
	pipe link/map/full/exec=nl: $(MMS$TARGET_NAME).obj | copy sys$input nl:
	mc sys$library:vms_auto64 $(MMS$TARGET_NAME).map
	cc$(CFLAGS)/warn=(noinfo,disable=(MAYLOSEDATA3))/point=64/obj=$(MMS$TARGET_NAME)_64.obj\
	$(MMS$TARGET_NAME)_64.c
	delete $(MMS$TARGET_NAME)_64.c;*
.endif

OBJS=truetype.obj

OBJS64=truetype_64.obj

OBJSCXX=truetype_cxx.obj

all : $(OBJS)
	library [--.lib]freetype.olb $(OBJS)
	library [--.lib]freetype.olb $(OBJS64)
.ifdef X86
	library [--.lib]freetype_cxx.olb $(OBJSCXX)
	library [--.lib]freetype_cxx.olb $(OBJS64)
.endif

# EOF
$ eod
$ close out
$ write sys$output "... [.src.type1] directory"
$ create [.src.type1]descrip.mms
$ open/append out [.src.type1]descrip.mms
$ copy sys$input: out
$ deck
#
# FreeType 2 Type1 driver compilation rules for VMS
#


# Copyright 1996-2019 by
# David Turner, Robert Wilhelm, and Werner Lemberg.
#
# This file is part of the FreeType project, and may only be used, modified,
# and distributed under the terms of the FreeType project license,
# LICENSE.TXT.  By continuing to use, modify, or distribute this file you
# indicate that you have read the license and understand and accept it
# fully.


CFLAGS=$(COMP_FLAGS)$(DEBUG)/include=([--.include],[--.src.type1])
.ifdef X86
CXXFLAGS=$(CXXCOMP_FLAGS) -I[] -I[--.include] -I[--.src.base]
.endif

.ifdef X86
.c.obj :
	clang $(CXXFLAGS) -o $(MMS$TARGET_NAME)_cxx.obj $(MMS$TARGET_NAME).c
	cc$(CFLAGS)/warn=noinfo/point=32/list/show=all $(MMS$TARGET_NAME).c
	pipe link/map/full/exec=nl: $(MMS$TARGET_NAME).obj | copy sys$input nl:
	mc sys$library:vms_auto64 $(MMS$TARGET_NAME).map
	cc$(CFLAGS)/warn=(noinfo,disable=(MAYLOSEDATA3))/point=64/obj=$(MMS$TARGET_NAME)_64.obj\
	$(MMS$TARGET_NAME)_64.c
	clang $(CXXFLAGS) -o $(MMS$TARGET_NAME)_64_cxx.obj $(MMS$TARGET_NAME)_64.c
	delete $(MMS$TARGET_NAME)_64.c;*
.else
.c.obj :
	cc$(CFLAGS)/warn=noinfo/point=32/list/show=all $(MMS$TARGET_NAME).c
	pipe link/map/full/exec=nl: $(MMS$TARGET_NAME).obj | copy sys$input nl:
	mc sys$library:vms_auto64 $(MMS$TARGET_NAME).map
	cc$(CFLAGS)/warn=(noinfo,disable=(MAYLOSEDATA3))/point=64/obj=$(MMS$TARGET_NAME)_64.obj\
	$(MMS$TARGET_NAME)_64.c
	delete $(MMS$TARGET_NAME)_64.c;*
.endif

OBJS=type1.obj

OBJS64=type1_64.obj

OBJSCXX=type1_cxx.obj

all : $(OBJS)
	library [--.lib]freetype.olb $(OBJS)
	library [--.lib]freetype.olb $(OBJS64)
.ifdef X86
	library [--.lib]freetype_cxx.olb $(OBJSCXX)
	library [--.lib]freetype_cxx.olb $(OBJS64)
.endif

type1.obj : type1.c t1parse.c t1load.c t1objs.c t1driver.c t1gload.c t1afm.c

# EOF
$ eod
$ close out
$ write sys$output "... [.src.sdf] directory"
$ create [.src.sdf]descrip.mms
$ open/append out [.src.sdf]descrip.mms
$ copy sys$input: out
$ deck
#
# FreeType 2 sdf driver compilation rules for VMS
#


# Copyright 1996-2019 by
# David Turner, Robert Wilhelm, and Werner Lemberg.
#
# This file is part of the FreeType project, and may only be used, modified,
# and distributed under the terms of the FreeType project license,
# LICENSE.TXT.  By continuing to use, modify, or distribute this file you
# indicate that you have read the license and understand and accept it
# fully.


CFLAGS=$(COMP_FLAGS)$(DEBUG)/include=([--.include],[--.src.type1])
.ifdef X86
CXXFLAGS=$(CXXCOMP_FLAGS) -I[] -I[--.include] -I[--.src.base]
.endif

.ifdef X86
.c.obj :
	clang $(CXXFLAGS) -o $(MMS$TARGET_NAME)_cxx.obj $(MMS$TARGET_NAME).c
	cc$(CFLAGS)/warn=noinfo/point=32/list/show=all $(MMS$TARGET_NAME).c
	pipe link/map/full/exec=nl: $(MMS$TARGET_NAME).obj | copy sys$input nl:
	mc sys$library:vms_auto64 $(MMS$TARGET_NAME).map
	cc$(CFLAGS)/warn=(noinfo,disable=(MAYLOSEDATA3))/point=64/obj=$(MMS$TARGET_NAME)_64.obj\
	$(MMS$TARGET_NAME)_64.c
	clang $(CXXFLAGS) -o $(MMS$TARGET_NAME)_64_cxx.obj $(MMS$TARGET_NAME)_64.c
	delete $(MMS$TARGET_NAME)_64.c;*
.else
.c.obj :
	cc$(CFLAGS)/warn=noinfo/point=32/list/show=all $(MMS$TARGET_NAME).c
	pipe link/map/full/exec=nl: $(MMS$TARGET_NAME).obj | copy sys$input nl:
	mc sys$library:vms_auto64 $(MMS$TARGET_NAME).map
	cc$(CFLAGS)/warn=(noinfo,disable=(MAYLOSEDATA3))/point=64/obj=$(MMS$TARGET_NAME)_64.obj\
	$(MMS$TARGET_NAME)_64.c
	delete $(MMS$TARGET_NAME)_64.c;*
.endif

OBJS=sdf.obj

OBJS64=sdf_64.obj

OBJSCXX=sdf_cxx.obj

all : $(OBJS)
	library [--.lib]freetype.olb $(OBJS)
	library [--.lib]freetype.olb $(OBJS64)
.ifdef X86
	library [--.lib]freetype_cxx.olb $(OBJSCXX)
	library [--.lib]freetype_cxx.olb $(OBJS64)
.endif

sdf.obj : sdf.c ftbsdf.c ftsdf.c ftsdfcommon.c ftsdfrend.c

# EOF
$ eod
$ close out
$ write sys$output "... [.src.type42] directory"
$ create [.src.type42]descrip.mms
$ open/append out [.src.type42]descrip.mms
$ copy sys$input: out
$ deck
#
# FreeType 2 Type 42 driver compilation rules for VMS
#


# Copyright 2002-2019 by
# David Turner, Robert Wilhelm, and Werner Lemberg.
#
# This file is part of the FreeType project, and may only be used, modified,
# and distributed under the terms of the FreeType project license,
# LICENSE.TXT.  By continuing to use, modify, or distribute this file you
# indicate that you have read the license and understand and accept it
# fully.


CFLAGS=$(COMP_FLAGS)$(DEBUG)/include=([--.include],[--.src.type42])
.ifdef X86
CXXFLAGS=$(CXXCOMP_FLAGS) -I[] -I[--.include] -I[--.src.base]
.endif

.ifdef X86
.c.obj :
	clang $(CXXFLAGS) -o $(MMS$TARGET_NAME)_cxx.obj $(MMS$TARGET_NAME).c
	cc$(CFLAGS)/warn=noinfo/point=32/list/show=all $(MMS$TARGET_NAME).c
	pipe link/map/full/exec=nl: $(MMS$TARGET_NAME).obj | copy sys$input nl:
	mc sys$library:vms_auto64 $(MMS$TARGET_NAME).map
	cc$(CFLAGS)/warn=(noinfo,disable=(MAYLOSEDATA3))/point=64/obj=$(MMS$TARGET_NAME)_64.obj\
	$(MMS$TARGET_NAME)_64.c
	clang $(CXXFLAGS) -o $(MMS$TARGET_NAME)_64_cxx.obj $(MMS$TARGET_NAME)_64.c
	delete $(MMS$TARGET_NAME)_64.c;*
.else
.c.obj :
	cc$(CFLAGS)/warn=noinfo/point=32/list/show=all $(MMS$TARGET_NAME).c
	pipe link/map/full/exec=nl: $(MMS$TARGET_NAME).obj | copy sys$input nl:
	mc sys$library:vms_auto64 $(MMS$TARGET_NAME).map
	cc$(CFLAGS)/warn=(noinfo,disable=(MAYLOSEDATA3))/point=64/obj=$(MMS$TARGET_NAME)_64.obj\
	$(MMS$TARGET_NAME)_64.c
	delete $(MMS$TARGET_NAME)_64.c;*
.endif

OBJS=type42.obj

OBJS64=type42_64.obj

OBJSCXX=type42_cxx.obj

all : $(OBJS)
	library [--.lib]freetype.olb $(OBJS)
	library [--.lib]freetype.olb $(OBJS64)
.ifdef X86
	library [--.lib]freetype_cxx.olb $(OBJSCXX)
	library [--.lib]freetype_cxx.olb $(OBJS64)
.endif

# EOF
$ eod
$ close out
$ write sys$output "... [.src.winfonts] directory"
$ create [.src.winfonts]descrip.mms
$ open/append out [.src.winfonts]descrip.mms
$ copy sys$input: out
$ deck
#
# FreeType 2 Windows FNT/FON driver compilation rules for VMS
#


# Copyright 2001-2019 by
# David Turner, Robert Wilhelm, and Werner Lemberg.
#
# This file is part of the FreeType project, and may only be used, modified,
# and distributed under the terms of the FreeType project license,
# LICENSE.TXT.  By continuing to use, modify, or distribute this file you
# indicate that you have read the license and understand and accept it
# fully.


CFLAGS=$(COMP_FLAGS)$(DEBUG)/include=([--.include],[--.src.winfonts])
.ifdef X86
CXXFLAGS=$(CXXCOMP_FLAGS) -I[] -I[--.include] -I[--.src.base]
.endif

.ifdef X86
.c.obj :
	clang $(CXXFLAGS) -o $(MMS$TARGET_NAME)_cxx.obj $(MMS$TARGET_NAME).c
	cc$(CFLAGS)/warn=noinfo/point=32/list/show=all $(MMS$TARGET_NAME).c
	pipe link/map/full/exec=nl: $(MMS$TARGET_NAME).obj | copy sys$input nl:
	mc sys$library:vms_auto64 $(MMS$TARGET_NAME).map
	cc$(CFLAGS)/warn=(noinfo,disable=(MAYLOSEDATA3))/point=64/obj=$(MMS$TARGET_NAME)_64.obj\
	$(MMS$TARGET_NAME)_64.c
	clang $(CXXFLAGS) -o $(MMS$TARGET_NAME)_64_cxx.obj $(MMS$TARGET_NAME)_64.c
	delete $(MMS$TARGET_NAME)_64.c;*
.else
.c.obj :
	cc$(CFLAGS)/warn=noinfo/point=32/list/show=all $(MMS$TARGET_NAME).c
	pipe link/map/full/exec=nl: $(MMS$TARGET_NAME).obj | copy sys$input nl:
	mc sys$library:vms_auto64 $(MMS$TARGET_NAME).map
	cc$(CFLAGS)/warn=(noinfo,disable=(MAYLOSEDATA3))/point=64/obj=$(MMS$TARGET_NAME)_64.obj\
	$(MMS$TARGET_NAME)_64.c
	delete $(MMS$TARGET_NAME)_64.c;*
.endif

OBJS=winfnt.obj

OBJS64=winfnt_64.obj

OBJSCXX=winfnt_cxx.obj

all : $(OBJS)
	library [--.lib]freetype.olb $(OBJS)
	library [--.lib]freetype.olb $(OBJS64)
.ifdef X86
	library [--.lib]freetype_cxx.olb $(OBJSCXX)
	library [--.lib]freetype_cxx.olb $(OBJS64)
.endif

# EOF
$ eod
$ close out
$ return
$!------------------------------------------------------------------------------
$!
$! Check command line options and set symbols accordingly
$!
$ CHECK_OPTS:
$ i = 1
$ OPT_LOOP:
$ if i .lt. 9
$ then
$   cparm = f$edit(p'i',"upcase")
$   if cparm .eqs. "DEBUG"
$   then
$     ccopt = ccopt + "/noopt/deb"
$     lopts = lopts + "/deb"
$   endif
$   if f$locate("CCOPT=",cparm) .lt. f$length(cparm)
$   then
$     start = f$locate("=",cparm) + 1
$     len   = f$length(cparm) - start
$     ccopt = ccopt + f$extract(start,len,cparm)
$     if x86_64 then cxxopt = cxxopt + f$extract(start,len,cparm)
$   endif
$   if cparm .eqs. "LINK" then linkonly = true
$   if f$locate("LOPTS=",cparm) .lt. f$length(cparm)
$   then
$     start = f$locate("=",cparm) + 1
$     len   = f$length(cparm) - start
$     lopts = lopts + f$extract(start,len,cparm)
$   endif
$   if f$locate("CC=",cparm) .lt. f$length(cparm)
$   then
$     start  = f$locate("=",cparm) + 1
$     len    = f$length(cparm) - start
$     cc_com = f$extract(start,len,cparm)
      if (cc_com .nes. "DECC") .and. -
         (cc_com .nes. "VAXC") .and. -
         (cc_com .nes. "GNUC")
$     then
$       write sys$output "Unsupported compiler choice ''cc_com' ignored"
$       write sys$output "Use DECC, VAXC, or GNUC instead"
$     else
$     	if cc_com .eqs. "DECC" then its_decc = true
$     	if cc_com .eqs. "VAXC" then its_vaxc = true
$     	if cc_com .eqs. "GNUC" then its_gnuc = true
$     endif
$   endif
$   if f$locate("MAKE=",cparm) .lt. f$length(cparm)
$   then
$     start  = f$locate("=",cparm) + 1
$     len    = f$length(cparm) - start
$     mmks = f$extract(start,len,cparm)
$     if (mmks .eqs. "MMK") .or. (mmks .eqs. "MMS")
$     then
$       make = mmks
$     else
$       write sys$output "Unsupported make choice ''mmks' ignored"
$       write sys$output "Use MMK or MMS instead"
$     endif
$   endif
$   i = i + 1
$   goto opt_loop
$ endif
$ return
$!------------------------------------------------------------------------------
$!
$ endsubroutine
