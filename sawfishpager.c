/* pager.c -- The display program of sawfish.wm.ext.pager

   Copyright (C) 2009 Christopher Bratusek <zanghar@freenet.de>
   Copyright (C) 2007 Janek Kozicki <janek_listy@wp.pl>
   Copyright (C) 2002 Daniel Pfeiffer <occitan@esperanto.org>
   Copyright (C) 2000 Satyaki Das <satyaki@theforce.stanford.edu>
                      Hakon Alstadheim

   This file is part of sawfish.

   sawfish is free software; you can redistribute it and/or modify it
   under the terms of the GNU General Public License as published by
   the Free Software Foundation; either version 2, or (at your option)
   any later version.

   sawfish is distributed in the hope that it will be useful, but
   WITHOUT ANY WARRANTY; without even the implied warranty of
   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
   GNU General Public License for more details.

   You should have received a copy of the GNU General Public License
   along with sawfish; see the file COPYING.   If not, write to
   the Free Software Foundation, 675 Mass Ave, Cambridge, MA 02139, USA. */

#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <sys/time.h>
#include <sys/select.h>
#include <gtk/gtk.h>
#include <sawfish/libclient.h>
#include <sawfish/sawfish.h>
#include <gdk/gdkx.h>
#include <glib.h>

enum { bg, hilit_bg, win, focus_win, win_border, vp_divider, ws_divider, vp_frame };
int hatch = 0;
int xmark = 0;

GdkColor colors[ws_divider+1];
GdkGC *gc[vp_frame+1];
GdkColormap *cmap = NULL;
GdkPixmap *background = NULL;
GdkPixmap *pixmap = NULL;
GtkWidget *drawing_area;
GtkWidget *window;
GdkRectangle update_rect;

/* can read this many chars, truncate beyond */
#define MAXSTRING 2048
char bg_filename[MAXSTRING] = "";


/* can display this many, including all instances of stickies */
#define MAXWINDOWS 1024
struct {
  long id;
  GdkRectangle w, c;		/* window and clip area */
} windows[MAXWINDOWS], *lowest, *w, *dragged_window, *tooltip_window;

int vp_width, vp_height, ws_width, ws_height, width, height;
int offset_x, offset_y;
int show_all_ws, ws_x, ws_y, vp_x, vp_y;
long focus_id;
int mouse_x = -1;
int mouse_y = -1;

gint delete_event( GtkWidget *, GdkEvent *, gpointer );
gint destroy_event( GtkWidget *, GdkEvent *, gpointer );
gint configure_event( GtkWidget *, GdkEvent *, gpointer );
gint leave_notify_event( GtkWidget *, GdkEvent *, gpointer );
gint expose_event( GtkWidget *, GdkEventExpose *, gpointer );
gint button_press_event( GtkWidget *, GdkEventButton *, gpointer );
gint scroll_event( GtkWidget *, GdkEventScroll *, gpointer );
gint button_release_event( GtkWidget *, GdkEventButton *, gpointer );
gint motion_notify_event( GtkWidget *, GdkEventMotion *, gpointer );

gboolean wait_stdin( GIOChannel *source, GIOCondition condition, gpointer data );

void make_background( void );
void draw_pager( GtkWidget * );
gint draw_tooltip( void );
void parse_stdin( void );
void send_command( char *cmd );

static void wmspec_change_state( gboolean , GdkWindow *, GdkAtom , GdkAtom );

int main( int argc, char *argv[] )
{
  GtkWidget *vbox;

  gtk_init( &argc, &argv );

  if( client_open( NULL ) )
    exit( 1 );
  atexit( client_close );

  window = argc == 2 ?
    gtk_plug_new( strtol( argv[1], NULL, 10 )) :
    gtk_window_new( GTK_WINDOW_TOPLEVEL );
  vbox = gtk_vbox_new( FALSE, 0 );
  gtk_container_add( GTK_CONTAINER( window ), vbox );
  drawing_area = gtk_drawing_area_new();

  /* Get the dimensions and colors of the pager and viewport and focus */
  parse_stdin();

  update_rect.x = update_rect.y = 0;

  gtk_drawing_area_size( GTK_DRAWING_AREA( drawing_area ), width, height );
  gtk_box_pack_start( GTK_BOX( vbox ), drawing_area, FALSE, FALSE, 0 );

  /* Signals to quit */
  g_signal_connect( GTK_OBJECT( window ), "delete_event",
		      G_CALLBACK( delete_event ), NULL );
  g_signal_connect( GTK_OBJECT( window ), "destroy",
		      G_CALLBACK( destroy_event ), NULL );

  /* Wait for input from standard input */
  GIOChannel* channel = g_io_channel_unix_new(0);
  g_io_add_watch(channel, (G_IO_IN | G_IO_HUP | G_IO_ERR), wait_stdin, drawing_area);
  g_io_channel_unref(channel);

  /* Change the viewport when a button is pressed */
  g_signal_connect( GTK_OBJECT( drawing_area ), "motion_notify_event",
		     (GCallback) motion_notify_event, NULL );
  g_signal_connect( GTK_OBJECT( drawing_area ), "button_press_event",
		     (GCallback) button_press_event, NULL );
  g_signal_connect( GTK_OBJECT( drawing_area ), "button_release_event",
		     (GCallback) button_release_event, NULL );
  g_signal_connect( GTK_OBJECT( drawing_area ), "leave_notify_event",
		     (GCallback) leave_notify_event, NULL );
  g_signal_connect ( GTK_OBJECT( drawing_area), "scroll_event",
                     (GCallback) scroll_event, NULL );
  gtk_widget_set_events( drawing_area, GDK_EXPOSURE_MASK
			            | GDK_LEAVE_NOTIFY_MASK
			            | GDK_BUTTON_PRESS_MASK
                                    | GDK_BUTTON_RELEASE_MASK
		                    | GDK_POINTER_MOTION_MASK
		                    | GDK_POINTER_MOTION_HINT_MASK
                                    | GDK_SCROLL_MASK );

  /* Initialize and draw the pixmap */
  g_signal_connect( GTK_OBJECT( drawing_area ), "expose_event",
		     (GCallback) expose_event, NULL );
  g_signal_connect( GTK_OBJECT( drawing_area ), "configure_event",
		     (GCallback) configure_event, NULL );

  gtk_widget_show( drawing_area );
  gtk_widget_show( vbox );

  wmspec_change_state(TRUE, window->window,
		  gdk_atom_intern( "_NET_WM_STATE_SKIP_PAGER", FALSE ),
		  gdk_atom_intern( "_NET_WM_STATE_SKIP_TASKBAR", FALSE ));

  gtk_window_set_type_hint( GTK_WINDOW(window), GDK_WINDOW_TYPE_HINT_DOCK);

  gtk_widget_show( window );
  gtk_main();
  return 0;
}

inline void send_command( char *cmd )
{
  int rv;
  client_eval( cmd, NULL, &rv );
}

inline gint find_w( int x, int y ) {
  for( w = windows; w <= lowest; w++ )
    if( w->w.x <= x && w->w.x + w->w.width > x &&
	w->w.y <= y && w->w.y + w->w.height > y )
      return TRUE;
  return FALSE;
}

inline void box( int color, gint filled,
		 gint x, gint y, gint width, gint height )
{
  gdk_draw_rectangle( pixmap, gc[color], filled, x, y, width, height );
}

inline void clipbox( int color, gint filled,
		     gint x, gint y, gint width, gint height,
		     GdkRectangle *c )
{
  if(width < 0 || height < 0)
    return;
  gdk_gc_set_clip_rectangle( gc[color], c );
  gdk_draw_rectangle( pixmap, gc[color], filled, x, y, width, height );
}


gint expose_event( GtkWidget *widget, GdkEventExpose *event, gpointer data )
{
  gdk_draw_drawable( widget->window,
		  widget->style->fg_gc[gtk_widget_get_state( widget )],
		  pixmap,
		  0, 0, 0, 0,
		  width, height );
  return TRUE;
}

gint leave_notify_event( GtkWidget *widget, GdkEvent *event, gpointer data )
{
  if( !dragged_window ) {
    mouse_x = width;
    mouse_y = height;

    draw_tooltip();
  }
  return TRUE;
}

gint button_press_event( GtkWidget *widget, GdkEventButton *event, gpointer d )
{
  char cmd[64];
  int x, y;

  mouse_x = x = (int) event->x;
  mouse_y = y = (int) event->y;

  if( !(x % ws_width) || !(y % ws_height) ) /* WS border */
    return TRUE;

  /* Button1 changes viewport */
  if( event->button == 1 ) {
    sprintf( cmd, "(pager-goto %ld %d %d)", find_w( x, y ) ? w->id : 0, x, y );
    send_command( cmd );
    draw_tooltip();
  }

  /* Button2 raises/lowers current window */
  else if( event->button == 2 && find_w( x, y ) ) {
    sprintf( cmd, "(pager-change-depth %ld)", w->id );
    send_command( cmd );
    draw_tooltip();
  }

  /* Button3 is for dragging the selected window */
  else if( event->button == 3 && find_w( x, y ) ) {
    draw_tooltip();
    dragged_window = w;

    /* Offset of top left from cursor */
    offset_x = x - w->w.x;
    offset_y = y - w->w.y;
  }

  return TRUE;

}

gint scroll_event( GtkWidget *widget, GdkEventScroll *event, gpointer d )
{
  char cmd[64];
  int x, y;

  mouse_x = x = (int) event->x;
  mouse_y = y = (int) event->y;

  if( !(x % ws_width) || !(y % ws_height) ) /* WS border */
    return TRUE;

  /* Button4 is for selecting the previous workspace */
  if( event->direction == GDK_SCROLL_UP ) {
    send_command( "(pager-select 'previous)" );

  }

  /* Button5 is for selecting the next workspace */
  else if( event->direction == GDK_SCROLL_DOWN ){
    send_command( "(pager-select 'next)" );
  }
  return TRUE;

}

gint motion_notify_event( GtkWidget *widget, GdkEventMotion *event, gpointer d )
{
  GdkModifierType state;

  if( event->is_hint )
    gdk_window_get_pointer( event->window, &mouse_x, &mouse_y, &state );
  else {
    mouse_x = event->x;
    mouse_y = event->y;
    state = event->state;
  }

  if( dragged_window && state & GDK_BUTTON3_MASK ) {
    char cmd[64];
    sprintf( cmd, "(pager-move-window %ld %d %d %d %d %d %d)",
	     dragged_window->id, mouse_x-offset_x, mouse_y-offset_y,
	     dragged_window->w.width, dragged_window->w.height,
	     mouse_x, mouse_y );
    send_command( cmd );
  } else
    draw_tooltip();

  return TRUE;
}

gint button_release_event( GtkWidget *widget, GdkEventButton *event, gpointer d )
{
  if( dragged_window && event->button == 3 ) {
    int x = (int) event->x;
    int y = (int) event->y;
    char cmd[64];
    sprintf( cmd, "(pager-move-window %ld %d %d %d %d %d %d)",
	     dragged_window->id, x-offset_x, y-offset_y,
	     dragged_window->w.width, dragged_window->w.height,
	     x, y );
    send_command( cmd );
    dragged_window = NULL;
  }
  return TRUE;
}


gint configure_event( GtkWidget *widget, GdkEvent *event, gpointer data )
{
  int i;

  if( pixmap ) {
    g_object_unref( pixmap );
    for( i = bg; i <= vp_frame; i++ )
      gdk_gc_unref( gc[i] );
  }

  pixmap = gdk_pixmap_new( widget->window, width, height, -1 );
  for( i = bg; i <= ws_divider; i++ )
    gdk_gc_set_foreground( gc[i] = gdk_gc_new( pixmap ), &colors[i] );

  /* wishing for a nicer line style, like 3 on, 5 off, making this alternate for neighbouring VPs */
  gdk_gc_set_line_attributes( gc[vp_divider], 1, GDK_LINE_ON_OFF_DASH,
			      GDK_CAP_ROUND, GDK_JOIN_ROUND );
  gdk_gc_set_foreground( gc[vp_frame] = gdk_gc_new( pixmap ), &colors[vp_divider] );
  gdk_gc_set_line_attributes( gc[vp_frame], 1, GDK_LINE_ON_OFF_DASH,
			      GDK_CAP_ROUND, GDK_JOIN_ROUND );
  /* wishing for Gimp-style functions -- GDK is just too primitive */
  /* gdk_gc_set_function( gc[vp_frame], GDK_XOR ); */

  make_background();
  draw_pager( widget );

  return TRUE;
}


void make_background()
{
  if( background )
    g_object_unref( background );
  if( ! (*bg_filename &&
	 (background = gdk_pixmap_create_from_xpm( window->window, NULL, NULL, bg_filename ))) )
  {
    int i, j;
    background = gdk_pixmap_new( window->window, ws_width, ws_height, -1 );
    gdk_draw_rectangle( background, gc[bg], TRUE, 1, 1, ws_width, ws_height );

    /* draw the boundaries of the different viewports */
    if( vp_width < ws_width-1 || vp_height < ws_height-1 )
      for( i=1; i<ws_width; i+=vp_width )
	for( j=1; j<ws_height; j+=vp_height )
	  gdk_draw_rectangle( background, gc[vp_divider], FALSE,
			      i+1, j+1, vp_width-3, vp_height-3 );

    /* draw the workspace-boundary (repeated by tiling) */
    gdk_draw_line( background, gc[ws_divider], 0, 0, 0, ws_height );
    gdk_draw_line( background, gc[ws_divider], 1, 0, ws_width, 0 );
  }
  gdk_gc_set_fill( gc[bg], GDK_TILED );
  gdk_gc_set_tile( gc[bg], background );
}


void draw_pager( GtkWidget *widget )
{
  if( show_all_ws )
    box( bg, TRUE, 0, 0, width, height );
  else
    box( bg, TRUE, -ws_x, -ws_y, width+ws_x, height+ws_y );

  /* highlight the current viewport with color hilit background */
  if(xmark ==0)
    box( hilit_bg, TRUE, vp_x, vp_y, vp_width, vp_height );

  /* draw the windows */
  if(hatch == 0)
  {
    for( w = lowest; w >= windows; w-- ) {
      clipbox( (w->id == focus_id) ? focus_win : win, TRUE,
               w->w.x+1, w->w.y+1, w->w.width-2, w->w.height-2, &w->c );
      clipbox( win_border, FALSE,
               w->w.x, w->w.y, w->w.width-1, w->w.height-1, &w->c );
    }
  } else {
    for( w = lowest; w >= windows; w-- ) {
      int i;
      if(w->id == focus_id)
      {
        for(i=((w->w.width > w->w.height)?w->w.width:w->w.height)>>1; i>=1 ; i-=2)
          clipbox(focus_win, FALSE, w->w.x+i, w->w.y+1, w->w.width-1-(i<<1), w->w.height-1, &w->c );
      } else {
        for(i=((w->w.width > w->w.height)?w->w.width:w->w.height)>>1; i>=1 ; i-=2)
          clipbox(win,       FALSE, w->w.x+1, w->w.y+i, w->w.width-1, w->w.height-1-(i<<1), &w->c );
      }
/*      for(i=((w->w.width > w->w.height)?w->w.width:w->w.height)>>1; i>=1 ; i-=2)
        clipbox( (w->id == focus_id) ? focus_win : win, FALSE, w->w.x+i, w->w.y+i, w->w.width-1-(i<<1), w->w.height-1-(i<<1), &w->c );
        clipbox( (w->id == focus_id) ? focus_win : win, FALSE, w->w.x+1, w->w.y+1, w->w.width-3, w->w.height-3, &w->c );
        clipbox( (w->id == focus_id) ? focus_win : win, FALSE, w->w.x+2, w->w.y+2, w->w.width-5, w->w.height-5, &w->c );
        clipbox( (w->id == focus_id) ? focus_win : win, FALSE, w->w.x+3, w->w.y+3, w->w.width-7, w->w.height-7, &w->c ); */
        clipbox( win_border,                            FALSE, w->w.x, w->w.y, w->w.width-1, w->w.height-1, &w->c );
    }
  }

  /* frame the current viewport above all else in case it's covered */
  if( vp_width < ws_width-1 || vp_height < ws_height-1 )
  {
    if(xmark == 0)
    {
      box( vp_frame, FALSE, vp_x, vp_y, vp_width-1, vp_height-1 );
    } else
    {
   /*box( vp_frame, FALSE, vp_x+1, vp_y+1, vp_width-3, vp_height-3 ); */
      box( hilit_bg, FALSE, vp_x, vp_y, vp_width-1, vp_height-1 );
      gdk_draw_line(pixmap,gc[hilit_bg],vp_x    ,               vp_y + 2 , vp_width-1 + vp_x - 2, vp_height-1 + vp_y    );
      gdk_draw_line(pixmap,gc[hilit_bg],vp_x    , vp_height-1 + vp_y - 2 , vp_width-1 + vp_x - 2,               vp_y    );

      gdk_draw_line(pixmap,gc[hilit_bg],vp_x + 2,               vp_y     , vp_width-1 + vp_x    , vp_height-1 + vp_y - 2);
      gdk_draw_line(pixmap,gc[hilit_bg],vp_x + 2, vp_height-1 + vp_y     , vp_width-1 + vp_x    ,               vp_y + 2);
    }
  }

  gtk_widget_draw( widget, &update_rect );
}

gint draw_tooltip()
{
  if( find_w( mouse_x, mouse_y )) {
    if( w != tooltip_window ) {
      char cmd[64];
      tooltip_window = w;
      sprintf( cmd, "(pager-tooltip %ld)", w->id );
      send_command( cmd );
    }
    return TRUE;
  } else if( tooltip_window )
    send_command( "(pager-tooltip)" );
  tooltip_window = NULL;
  return FALSE;
}



char get_char( int must )
{
  static char buffer[MAXSTRING];
  static char *ptr = buffer;
  static int n = 0;

  if( ++ptr < buffer + n )
    return *ptr;
  else if( must ) {
    n = read( 0, buffer, MAXSTRING );
    if( n < 1 )
      exit( 1 );
    return *(ptr = buffer);
  } else {
    /* input waiting? */
    fd_set rfds;
    struct timeval tv;
    FD_ZERO( &rfds );
    FD_SET( 0, &rfds );
    tv.tv_sec = tv.tv_usec = 0;
    if( select( 1, &rfds, NULL, NULL, &tv ) ) {
      n = read( 0, buffer, MAXSTRING );
      if( n < 1 )
	exit( 1 );
      return *(ptr = buffer);
    } else
      return '\0';
  }
}

int last;
long get_number()
{
  char buffer;
  long number = 0;
  int sign = 1;
  while( (buffer = get_char( 1 )) ) {
    if( buffer >= '0' && buffer <= '9' )
      number = number * 10 + buffer - '0';
    else if( (last = (buffer == '\n')) || buffer == ' ' ) {
      if( sign == -1 )
	number = -number;
      break;
    } else if( buffer == '-' )
      sign = -1;
  }
  return number;
}

void get_string( char *buffer )
{
  char *ptr = buffer;
  while( (*ptr = get_char( 1 )) )
    if( *ptr == '\n' )
      break;
    else if( ptr < buffer + MAXSTRING - 1 )
      ptr++;
  *ptr = '\0';
}

void get_rect( GdkRectangle *r )
{
  r->x = get_number();
  r->y = get_number();
  r->width = get_number();
  r->height = get_number();
}

/* This reads and returns the type of the data:
 *	W - regular info about what to display
 *	s - size info to resize the window
 *	b - background image file
 *	c - color change
 *	w - info about one window
 *	f - focus change
 *      H - hatching
 *      X - draw X-es
 */
void parse_stdin()
{
  long i;
  int repeat, more = 0;

  while( 1 )
    switch( get_char( ! more++ ) ) {
    case 'f':
      focus_id = get_number();
      break;
    case 'v':
      ws_x = get_number();
      ws_y = get_number();
      vp_x = ws_x + get_number();
      vp_y = ws_y + get_number();
      break;
    case 'W':
      last = 0;
      lowest = windows - 1;
      while( !last ) {
	if( lowest >= windows + MAXWINDOWS )
	  get_number();		/* flush input in excess of MAXWINDOWS */
	else if( ((lowest+1)->id = get_number()) ) {
	  get_rect( &(++lowest)->w );
	  get_rect( &lowest->c );
	}
      }
      break;
    case 'w':
      /* should never get here for an unknown window */
      i = get_number();
      for( w = lowest; w >= windows; w-- ) {
	if( w->id == i ) {
	  get_rect( &w->w );
	  get_rect( &w->c );
	  break;
	}
      }
      break;
    case 'h':
      hatch = get_number(); // this number is a 0 or 1
      break;
    case 'x':
      xmark = get_number(); // this number is a 0 or 1
      break;
    case 's':
      show_all_ws = get_number();
      vp_width = get_number();
      vp_height = get_number();
      ws_width = get_number();
      ws_height = get_number();
      width = update_rect.width = get_number() + 1;
      height = update_rect.height = get_number() + 1;
      /* Initialize the picture */
      gdk_window_resize( window->window, width, height );
      gtk_drawing_area_size( GTK_DRAWING_AREA( drawing_area ), width, height );
      break;
    case 'b':
      get_string( bg_filename );
      if( pixmap )
	make_background();
      break;
    case 'c':
      repeat = (cmap != NULL);
      cmap = gdk_colormap_get_system();
      for( i = bg; i <= ws_divider; i++ ) {
	if( repeat )
	  gdk_colormap_free_colors( cmap, &colors[i], 1 );
	colors[i].red = get_number();
	colors[i].green = get_number();
	colors[i].blue = get_number();
	gdk_colormap_alloc_color( cmap, &colors[i], FALSE, TRUE );
      }
      break;
    case '\0':
      return;
    }
}

gboolean wait_stdin( GIOChannel *source, GIOCondition condition, gpointer data )
{
  parse_stdin();
  draw_pager( data );
  draw_tooltip();
}

gint delete_event( GtkWidget *widget, GdkEvent *event, gpointer data )
{
  return FALSE;
}

gint destroy_event( GtkWidget *widget, GdkEvent *event, gpointer data )
{
  gtk_main_quit();
  return FALSE;
}

/* This function is borrowed from galeon's source */
static void wmspec_change_state( gboolean add, GdkWindow *window,
				 GdkAtom state1, GdkAtom state2 )
{
  XEvent xev;
  #define _NET_WM_STATE_REMOVE        0    /* remove/unset property */
  #define _NET_WM_STATE_ADD           1    /* add/set property */
  #define _NET_WM_STATE_TOGGLE        2    /* toggle property  */
  xev.xclient.type = ClientMessage;
  xev.xclient.serial = 0;
  xev.xclient.send_event = True;
  xev.xclient.display = GDK_DISPLAY_XDISPLAY (gdk_display_get_default ());
  xev.xclient.window = GDK_WINDOW_XID (window);
  xev.xclient.message_type = gdk_x11_get_xatom_by_name ("_NET_WM_STATE");
  xev.xclient.format = 32;
  xev.xclient.data.l[0] = add ? _NET_WM_STATE_ADD : _NET_WM_STATE_REMOVE;
  xev.xclient.data.l[1] = gdk_x11_atom_to_xatom (state1);
  xev.xclient.data.l[2] = gdk_x11_atom_to_xatom (state2);
  XSendEvent(GDK_DISPLAY_XDISPLAY (gdk_display_get_default ()), GDK_WINDOW_XID (gdk_get_default_root_window ()),
		  False, SubstructureRedirectMask | SubstructureNotifyMask,
		  &xev);
}
