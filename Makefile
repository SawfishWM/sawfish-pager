# Makefile -- makefile for sawfish-pager
#
# Copyright (C) 2009-2010 Christopher Bratusek <zanghar@freenet.de>
# Copyright (C) 2007-2008 Janek Kozicki <janek_listy@wp.pl>
# Copyright (C) 2002      Daniel Pfeiffer <occitan@esperanto.org>
# Copyright (C) 2000      Satyaki Das <satyaki@theforce.stanford.edu>
#                         Hakon Alstadheim <hakon.alstadheim@oslo.mail.telia.com>
#                         Andreas Büsching <crunchy@tzi.de>
#
# This file is part of sawfish-pager.
#
# sawfish-pager is free software; you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2, or (at your option)
# any later version.
#
# sawfish-pager is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with sawfish-pager; see the file COPYING.   If not, write to
# the Free Software Foundation, 675 Mass Ave, Cambridge, MA 02139, USA.

SAWFISH_PC = $(shell pkg-config --exists sawfish ; echo $$?)

ifeq "$(SAWFISH_PC)" "0"
	SAWFISH_VERSION = $(shell pkg-config --modversion sawfish)
	SAWFISH_PREFIX = $(shell pkg-config --variable=prefix sawfish)
	SAWFISH_CLIENT_LIB_DIR = $(shell pkg-config --variable=repcommonexecdir librep)/sawfish
	SAWFISH_HOST_TYPE = $(shell pkg-config --variable=sawfishhosttype sawfish)
	SAWFISH_LIB_EXEC_DIR = $(shell pkg-config --variable=libdir sawfish)/sawfish/$(SAWFISH_VERSION)/$(SAWFISH_HOST_TYPE)
	SAWFISH_IMAGE_LOADER = $(shell pkg-config --variable=imageloader sawfish)
else
	printf "sawfish.pc not found"
	exit 1
endif

CFLAGS = $(shell pkg-config --cflags gtk+-2.0)
LDFLAGS = -Wl,-rpath $(SAWFISH_CLIENT_LIB_DIR) $(SAWFISH_CLIENT_LIB_DIR)/client.so $(shell pkg-config --libs gtk+-2.0)

ifeq "$(SAWFISH_IMAGE_LOADER)" "gdk-pixbuf-xlib"
	CFLAGS += $(shell pkg-config --cflags gdk-pixbuf-xlib-2.0) -DHAVE_GDK_PIXBUF
	LDFLAGS += $(shell pkg-config --libs gdk-pixbuf-xlib-2.0)
else
	CFLAGS += $(shell pkg-config --cflags imlib)
	LDFLAGS += $(shell pkg-config --libs imlib)
endif

all: pager pager.jlc

%.jlc: %.jl
	sawfish --batch --no-rc compiler -f compile-batch $^

private-install: all
	mkdir -p $(HOME)/.sawfish/lisp/sawfish/wm/ext/
	install -m644 pager.jl $(HOME)/.sawfish/lisp/sawfish/wm/ext/
	#install -m644 pager.jlc $(HOME)/.sawfish/lisp/sawfish/wm/ext/
	install -m755 pager $(HOME)/.sawfish/

private-uninstall:
	rm -f $(HOME)/.sawfish/lisp/sawfish/wm/ext/pager.jl
	#rm -f $(HOME)/.sawfish/lisp/sawfish/wm/ext/pager.jlc
	rm -f $(HOME)/.sawfish/pager

install: all
	mkdir -p  $(DESTDIR)$(SAWFISH_LIB_EXEC_DIR)/
	mkdir -p $(DESTDIR)$(SAWFISH_PREFIX)/share/sawfish/$(SAWFISH_VERSION)/lisp/sawfish/wm/ext/
	install -m644 pager.jl $(DESTDIR)$(SAWFISH_PREFIX)/share/sawfish/$(SAWFISH_VERSION)/lisp/sawfish/wm/ext/
	#install -m644 pager.jlc $(DESTDIR)$(SAWFISH_PREFIX)/share/sawfish/$(SAWFISH_VERSION)/lisp/sawfish/wm/ext/
	install -m755 pager $(DESTDIR)$(SAWFISH_LIB_EXEC_DIR)/

uninstall:
	rm -f $(DESTDIR)$(SAWFISH_PREFIX)/share/sawfish/$(SAWFISH_VERSION)/lisp/sawfish/wm/ext/pager.jl
	#rm -f $(DESTDIR)$(SAWFISH_PREFIX)/share/sawfish/$(SAWFISH_VERSION)/lisp/sawfish/wm/ext/pager.jlc
	rm -f $(DESTDIR)$(SAWFISH_LIB_EXEC_DIR)/pager

distclean: clean

clean:
	rm -f pager pager.jlc
