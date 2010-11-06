#| sawfish.wm.ext.pager -- Code for communicating with C pager

   Copyright (C) 2009 Christopher Bratusek <zanghar@freenet.de>
   Copyright (C) 2007 Janek Kozicki <janek_listy@wp.pl>
   Copyright (C) 2002 Daniel Pfeiffer <occitan@esperanto.org>
   Copyright (C) 2000 Satyaki Das <satyaki@theforce.stanford.edu>
		      Ryan Lovett <ryan@ocf.Berkeley.EDU>
		      Andreas Buesching <crunchy@tzi.de>
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
   along with sawfish; see the file COPYING.  If not, write to
   the Free Software Foundation, 675 Mass Ave, Cambridge, MA 02139, USA.

|#

(define-structure sawfish.wm.ext.pager

    (export pager
	    send-background-file
	    pager-change-depth
	    pager-goto
	    pager-move-window
	    pager-tooltip
	    pager-select
	    pager-hide
	    pager-unhide)

    (open rep
	  rep.io.files
	  rep.io.timers
	  rep.io.processes
	  rep.structures
	  rep.system
	  sawfish.wm.colors
	  sawfish.wm.misc
	  sawfish.wm.custom
	  sawfish.wm.ext.tooltips
	  sawfish.wm.fonts
	  sawfish.wm.stacking
	  sawfish.wm.util.window-order
	  sawfish.wm.viewport
	  sawfish.wm.commands.viewport-extras
	  sawfish.wm.windows
	  sawfish.wm.windows.subrs
	  sawfish.wm.workspace)

;;; Customization code contributed by Ryan Lovett <ryan@ocf.Berkeley.EDU>
  (defgroup pager "Pager")

  ;; closures for out of scope call
  (let ((state (lambda () (send-windows)))
	(resize (lambda () (send-size t)))
	(color (lambda () (send-colors))))

    (defcustom pager-show-ignored-windows nil
      "Show ignored windows"
      :type boolean
      :group pager
      :after-set state)

    (defcustom pager-show-all-workspaces t
      "Show all workspaces"
      :type boolean
      :group pager
      :after-set resize)

    (defcustom pager-workspaces-per-column 1
      "The number of workspaces per column"
      :type number
      :range (1)
      :depends pager-show-all-workspaces
      :group pager
      :after-set resize)

    (defcustom pager-stickies-on-all-workspaces t
      "Show (workspace) sticky windows on all their workspaces"
      :type boolean
      :depends pager-show-all-workspaces
      :group pager
      :after-set state)

    (defcustom pager-stickies-on-all-viewports t
      "Show (viewport) sticky windows on all their viewports"
      :type boolean
      :group pager
      :after-set state)

    (defcustom pager-shrink-factor 32
      "Each length in the pager is this many times shorter than the original"
      :type number
      :group pager
      :after-set resize)

    (defcustom pager-focus t
      "Button1 focuses the clicked window"
      :type boolean
      :group pager)

    (defcustom pager-warp-cursor nil
      "Button1 warps the cursor to the clicked point"
      :type boolean
      :group pager)

    (defcustom pager-color-window (get-color "#8080d0")
      "Windows"
      :type color
      :group pager
      :after-set color)

    (defcustom pager-color-focus-window (get-color "#58a8ff")
      "Window with input focus"
      :type color
      :group pager
      :after-set color)

    (defcustom pager-color-window-border (get-color "#606060")
      "Window borders"
      :type color
      :group pager
      :after-set color)

    (defcustom pager-color-viewport (get-color "#f0f0f0")
      "Current viewport color"
      :type color
      :group pager
      :after-set color)

    (defcustom pager-background ""
      "Pager background, an XPM file"
      :type file-name
      :tooltip "Create this from a pager screenshot in a paint program."
      :group pager
      :after-set (lambda () (send-background-file)))

    (defcustom pager-color-background (get-color "#d8d8d8")
      "Pager background"
      :type color
      :group pager
      :after-set color)

    (defcustom pager-color-viewport-divider (get-color "#e8e8e8")
      "Lines separating viewports"
      :type color
      :group pager
      :after-set color)

    (defcustom pager-color-workspace-divider (get-color "#202020")
      "Lines separating workspaces"
      :type color
      :group pager
      :after-set color))

  (defcustom pager-hatch-windows nil
    "Draw windows using hatching"
    :type boolean
    :group pager
    :after-set (lambda () (send-hatching)))

  (defcustom pager-X-current-viewport nil
    "Use X to mark current viewport"
    :type boolean
    :group pager
    :after-set (lambda () (send-xmark)))

  (defcustom pager-tooltips-enabled t
    "When focused, show window name and pager usage."
    :type boolean
    :group pager)

  (defcustom pager-autohide-enable nil
    "Whether to autohide the pager and only show it, when
entering a new workspace."
    :type boolean
    :group pager
    :after-set (lambda () (pager-autounhide/workspace)))

  (defcustom pager-unhide-when-flip nil
    "Also unhide the pager when fliping edges or hitting the screen-border."
    :type boolean
    :group pager
    :after-set (lambda () (pager-autounhide/edge-flip)))

  (defcustom pager-unhide-time 5
    "How long (in seconds) to show the pager then autohiding it."
    :type number
    :range ( 3 . 60 )
    :group pager)

  (defcustom pager-select-type 'workspace
    "When scrolling with mouse on pager, select either next
workspace, viewport or none."
    :type (choice workspace viewport none)
    :group pager)

  (defvar pager-executable
    (if (file-exists-p "~/.sawfish/sawfishpager")
	(concat (user-home-directory) "/.sawfish/sawfishpager")
      (concat sawfish-exec-directory "/sawfishpager")))

  (defvar pager-output-stream nil
    "Pager's output stream.")

  ;; Remembers the number of workspaces...
  (define ws-limits)

  ;; Remembers the viewport dimensions...
  (define vp-rows)
  (define vp-columns)

  (define vp-width)
  (define vp-height)

  (define ws-width)
  (define ws-height)
  (define ws-list)

  (define pager-width)
  (define pager-height)

  (define process nil)
  (define hooks
    '((after-move-hook . send-window)
      (after-resize-hook . send-window)
      (after-restacking-hook . send-windows)
      (enter-workspace-hook . send-viewport)
      (destroy-notify-hook . send-windows)
      (focus-in-hook . send-focus)
      (focus-out-hook . send-focus)
      (map-notify-hook . send-windows)
      (unmap-notify-hook . send-windows)
      (viewport-moved-hook . send-viewport)
      (viewport-resized-hook . send-size)
      (window-moved-hook . send-window)
      (window-resized-hook . send-window)
      (window-state-change-hook . send-window)
      (workspace-state-change-hook . send-size)))

  (define cache)

;;; Internal utilities

  ;; This is just to scale the window co-ords and dimensions.
  (define-macro (scale val #!optional x up)
    (if x
	(if up
	    `(round (/ (* ,val (screen-width)) vp-width))
	  `(round (/ (* ,val vp-width) (screen-width))))
      (if up
	  `(round (/ (* ,val (screen-height)) vp-height))
	`(round (/ (* ,val vp-height) (screen-height))))))

  (define (get-window-info w)
    (if (or (not (window-id w))
	    (not (window-mapped-p w))
	    (window-get w 'iconified)
	    (window-get w 'desktop)
	    (get-x-property w '_NET_WM_STATE_SKIP_PAGER)
	    (window-get w 'window-list-skip)
	    (unless pager-show-ignored-windows (window-get w 'ignored)))
	0
      (let* ((x (car (window-position w)))
	     (y (cdr (window-position w)))
	     (dim (window-frame-dimensions w))
             ;; l1 is a list of elements for each workspace the window
             ;; is present in. These elements describe the location of
             ;; that workspace in the pager display.  Each one is a
             ;; list of six values; the first four values are the
             ;; left, top, right and bottom edges of the workspace.
             ;; The last two are the viewport-[x,y]-offset coordinates
             ;; for the currently active viewport in that workspace.
             ;; The first four values are scaled to the pager display,
             ;; the offset values are not (to minimize rounding
             ;; errors).
	     (l1 (if pager-show-all-workspaces
		     (or (mapcar
                          (lambda (ws)
                            (append
                             (nth (- ws (car ws-limits)) ws-list)
                             (if (eql ws current-workspace)
                                 `(,viewport-x-offset ,viewport-y-offset)
                               (let ((vp-data
                                      (assoc ws workspace-viewport-data)))
                                 (if vp-data
                                     `(,(nth 1 vp-data) ,(nth 2 vp-data))
                                   ;; No vp data yet for ws:
                                   '(0 0))))))
                          (if (and pager-stickies-on-all-workspaces
                                   (window-get w 'sticky))
                              ;; List every workspace:
                              (let ((limits (workspace-limits))
                                    (l))
                                (do ((i (cdr limits) (1- i)))
                                    ((< i (car limits)) l)
                                  (setq l (cons i l))))
                            (or (window-workspaces w)
                                (list (- current-workspace
                                         (car ws-limits)))))))
		   (list (append (car ws-list)
                                 `(,viewport-x-offset ,viewport-y-offset))))))
	(setq dim `(,(max 3 (scale (car dim) 'x)) ,(max 3 (scale (cdr dim)))))
	(if (and pager-stickies-on-all-viewports
                 (or (> vp-rows 1) (> vp-columns 1))
                 (window-get w 'sticky-viewport))
            (let* ((vxo (mod viewport-x-offset (screen-width)))
                   (vyo (mod viewport-y-offset (screen-height)))
                   (j1 (- vp-rows (if (> vyo 0) 2 1)))
                   (wh `(,vp-width ,vp-height)))
              (setq x (scale (+ x vxo) 'x)
                    y (scale (+ y vyo)))
              (let loop ((l l1)
                         (i (- vp-columns (if (> vxo 0) 2 1)))
                         (j j1)
                         r)
                (cond ((< i 0)
                       r)
                      ((< j 0)
                       (loop l (1- i) j1 r))
                      (l
                       (loop (cdr l) i j
                             `((,(window-id w)
                                ,(+ x (* i vp-width) (caar l))
                                ,(+ y (* j vp-height) (cadar l))
                                ,dim
                                ,(+ (scale vxo 'x) (* i vp-width) (caar l))
                                ,(+ (scale vyo) (* j vp-height) (cadar l))
                                ,@wh)
                               ,@r)))
                      ((loop l1 i (1- j) r)))))
          (mapcar (lambda (ws)
                    (let ((vp-x (nth 4 ws))
                          (vp-y (nth 5 ws)))
                      `(,(window-id w)
                        ,(+ (scale (+ x vp-x) 'x) (car ws))
                        ,(+ (scale (+ y vp-y)) (cadr ws))
                        ,dim
                        ,(car ws)
                        ,(nth 1 ws)
                        ,(nth 2 ws)
                        ,(nth 3 ws))))
                  l1)))))

;;; Functions that talk to the C program

  ;; do a bit of caching to save redundant commands
  (define-macro (send f #!rest args)
    `(when process
       (let ((s (format nil ,(concat f (if (stringp f) "\n" "%s\n")) ,@args))
	     (c (assq ,(char-downcase (if (stringp f) (aref f 0) f))
		      cache)))
	 (unless (equal (cdr c) s)
	   (write process (setcdr c s))))))

  ;; Tells the C program to change the colors
  (define (send-colors)
    (send ?c
	  (mapcar (lambda (color)
                    (let ((rgb (color-rgb color)))
                      (list (elt rgb 0)
                            (elt rgb 1)
                            (elt rgb 2))))
		  (list pager-color-background
			pager-color-viewport
			pager-color-window
			pager-color-focus-window
			pager-color-window-border
			pager-color-viewport-divider
			pager-color-workspace-divider))))

  (define (send-hatching)
    (send ?h (if pager-hatch-windows 1 0)))

  (define (send-xmark)
    (send ?x (if pager-X-current-viewport 1 0)))

  (define (send-background-file #!optional file)
    "Tells the C program to change the pager-background from FILE."
    (if file (setq pager-background file))
    (send ?b pager-background))

  ;; Sends window-id of focussed window (or 0 if none is focussed)
  (define (send-focus #!rest args)
    (declare (unused args))
    (send "f%d"
	  (if (input-focus)
	      (window-id (input-focus))
	    0)))

  ;; calculates all kinds of sizes and tells the pager
  (define (send-size #!optional force init)
    (let* ((wsl (workspace-limits))
	   (n (- (cdr wsl) (car wsl)))
           (vp-dims
            (if pager-show-all-workspaces
                ;; Maximum viewport dimensions, accross all workspaces:
                (let ((dims (cons viewport-dimensions
                                  (mapcar (lambda (e)
                                            (unless (eq (car e)
                                                        current-workspace)
                                              (nth 3 e)))
                                          workspace-viewport-data))))
                  (cons (apply max (mapcar car dims))
                        (apply max (mapcar cdr dims))))
              viewport-dimensions)))
      (unless (and (not force)
		   (equal wsl ws-limits)
		   (eql (car vp-dims) vp-columns)
		   (eql (cdr vp-dims) vp-rows))
	(setq ws-limits wsl
	      vp-columns (car vp-dims)
	      vp-rows (cdr vp-dims)
	      vp-width (quotient (screen-width) pager-shrink-factor)
	      vp-height (quotient (screen-height) pager-shrink-factor)
	      ws-width (1+ (* vp-columns vp-width))
	      ws-height (1+ (* vp-rows vp-height))
	      pager-width (if pager-show-all-workspaces
			      (* ws-width
				 (ceiling (/ (1+ n) pager-workspaces-per-column)))
			    ws-width)
	      pager-height (if pager-show-all-workspaces
			       (* ws-height
				  (min (1+ n) pager-workspaces-per-column))
			     ws-height))
	(let ((ws-w `(,(1- ws-width) ,(1- ws-height))))
	  (let loop ((i n)
		     r)
	    (if (< i 0)
		(setq ws-list r)
	      (loop (1- i)
		    (if pager-show-all-workspaces
			`((,(+ 1 (quotient i pager-workspaces-per-column)
			       (* vp-columns vp-width
				  (quotient i pager-workspaces-per-column)))
			   ,(+ 1 (mod i pager-workspaces-per-column)
			       (* vp-rows vp-height
				  (mod i pager-workspaces-per-column)))
			   ,@ws-w)
			  ,@r)
		      `((1 1 ,@ws-w) ,@r))))))
	(send "s%d %d %d %d %d %d %d"
	      (if pager-show-all-workspaces 1 0)
	      vp-width vp-height
	      ws-width ws-height
	      pager-width pager-height))
      (or init (send-windows))))

  ;; Send the viewport that is in focus.
  (define (send-viewport #!rest args)
    (setq args (nth (- current-workspace (car ws-limits)) ws-list))
    (send "v%d %d %d %d"
	  (car args) (cadr args)
	  (scale viewport-x-offset 'x)
	  (scale viewport-y-offset))
    ;; should send only stickies instead, and only depending on options
    (send-windows))

  ;; When only the size or shading of a window changes send only the data
  ;; pertaining to that window.
  (define (send-window w #!rest args)
    (if (or (memq (caar args) '(sticky iconified))
	    (if pager-show-all-workspaces
		(cdr (window-workspaces w)))
	    (if pager-stickies-on-all-viewports
		(window-get w 'sticky-viewport))
	    (and pager-show-all-workspaces
		 pager-stickies-on-all-workspaces
		 (window-get w 'sticky)))
	(send-windows)
      (send ?w (get-window-info w))))

  ;; Tell the C program what to display.  For each window we send five
  ;; integers: window id, position and dimensions.
  (define (send-windows #!rest args)
    (declare (unused args))
    (send ?W
	  (mapcar get-window-info
		  (if pager-show-all-workspaces
		      (stacking-order)
		    (filter (lambda (w)
			      (let ((ws (window-workspaces w)))
				(or (null ws)
				    (member current-workspace ws))))
			    (stacking-order))))))



  (define (pager #!optional plug-to stop)
    "This function (re)starts the pager.
Optional PLUG-TO, if set, must be the numerical X id of the window to try
to plug in to.
Optional STOP, if non-nil, stops the pager instead."
    (when process
      (kill-process process)
      (setq process nil))
    (unless stop
      (setq process
	    (make-process pager-output-stream
			  (lambda ()
			    (and process
				 (not (process-in-use-p process))
				 (setq process nil))))
	    cache
	    (mapcar list '(?w ?f ?v ?s ?c ?b ?h ?x)))
      (if plug-to
	  (set-process-args process (list (number->string plug-to))))
      (start-process process pager-executable)
      (send-colors)
      (send-hatching)
      (send-xmark)
      (send-background-file)
      (send-size t t)
      (send-viewport)
      (send-focus)
      (pager-autohide)
      (condition-case err-info
	(mapc (lambda (hook)
		(unless (in-hook-p (car hook) (symbol-value (cdr hook)))
		  (add-hook (car hook) (symbol-value (cdr hook)) t)))
	      hooks)
	(error
	 (format standard-error "pager: error adding hooks %s\n" err-info)))))

;;; Functions called from C program for 3 buttons and tooltips

  (define (pager-goto w x y)
    "Change to viewport and/or workspace where the user clicked on the pager."
    (let ((ws (if pager-show-all-workspaces
		  (+ (* pager-workspaces-per-column (quotient x ws-width))
		     (quotient y ws-height))
		current-workspace))
	  (x1 (scale (1- (mod x ws-width)) 'x 'up))
	  (y1 (scale (1- (mod y ws-height)) () 'up)))
      (setq x (quotient x1 (screen-width))
	    y (quotient y1 (screen-height)))
      (if (eql ws current-workspace)
	  (set-screen-viewport x y)
	(select-workspace-and-viewport ws x y))
      (if pager-warp-cursor
	  (warp-cursor (% x1 (screen-width))
		       (% y1 (screen-height))))
      (and pager-focus
	   (setq w (get-window-by-id w))
	   (set-input-focus w))))

  (define (pager-change-depth w)
    "Raise or lower the window clicked on in the pager."
    (if (setq w (get-window-by-id w))
	(raise-lower-window w)))

  (define-macro (bound lower var upper)
    `(setq ,var (if (< ,var ,lower)
		    ,lower
		  (if (> ,var ,upper)
		      ,upper
		    ,var))))

  (define (pager-move-window w x y width height mouse-x mouse-y)
    "Moves window with id ID to co-ordinates (X, Y) where (X, Y) is what the
pager thinks the position of the window is."
    (when (setq w (get-window-by-id w))
      (bound (- 4 width) x (- pager-width 4))
      (bound (- 4 height) y (- pager-height 4))
      (bound 1 mouse-x (1- pager-width))
      (bound 1 mouse-y (1- pager-height))
      (setq x (- (scale (- (% mouse-x ws-width) (- mouse-x x) 1) 'x 'up)
		 viewport-x-offset)
	    y (- (scale (- (% mouse-y ws-height) (- mouse-y y) 1) () 'up)
		 viewport-y-offset))
      (when (window-get w 'sticky-viewport)
	(setq x (% x (screen-width))
	      y (% y (screen-height))))
      (move-window-to w x y)
      (when pager-show-all-workspaces
	(let* ((ws (+ (* pager-workspaces-per-column (quotient mouse-x ws-width))
		      (quotient mouse-y ws-height)))
	       (cws (window-workspaces w))
	       (was-focused (eq (input-focus) w))
	       (orig-space (if (window-in-workspace-p w current-workspace)
			       current-workspace
			     (car cws)))
	       (new-space (workspace-id-from-logical ws)))
	  (and cws (null (cdr cws))
	       (not (eql ws (car cws)))
	       orig-space
	       (progn
		 (copy-window-to-workspace w orig-space new-space nil)
		 (if (eql orig-space current-workspace)
		     (delete-window-instance w))
		 (move-window-to-workspace w orig-space new-space was-focused)))))))

  (define (pager-tooltip #!optional id)
    "Show a tooltip for window ID, or remove it if no ID given."
    (when pager-tooltips-enabled
      (if (and id
	       (setq id (get-window-by-id id))
	       (setq id (window-name id)))
	  (let ((te tooltips-enabled)
		(tooltips-enabled t))
	    (display-tooltip-after-delay
	     (if te
		 (concat id "\n\n"
			 (_ "Button1-Click  select viewport (and optionally window)
Button2-Click  raise/lower window
Button3-Move   drag window"))
	       id)))
	(remove-tooltip))))

  (define (pager-select direction)
    (if (eq pager-select-type 'workspace)
        (progn
	  (if (eq direction 'previous)
	      (previous-workspace 1)
	    (next-workspace 1)))
      (if (eq direction 'previous)
	  (move-viewport-previous)
	(move-viewport-next))))

  (define (pager-autohide)
    (if pager-autohide-enable
        (progn (make-timer (lambda () (hide-window (get-window-by-class-re "Sawfishpager"))) 5)
	       (if pager-unhide-when-flip
		   (unless (in-hook-p 'enter-flipper-hook pager-unhide)
	             (add-hook 'enter-flipper-hook pager-unhide)))
	       (unless (in-hook-p 'enter-workspace-hook pager-unhide)
	         (add-hook 'enter-workspace-hook pager-unhide)))
	(make-timer (lambda () (pager-unhide #:permanent t)) 5)
	(if pager-unhide-when-flip
	    (if (in-hook-p 'enter-flipper-hook pager-unhide)
	      (remove-hook 'enter-flipper-hook pager-unhide)))
	(if (in-hook-p 'enter-workspace-hook pager-unhide)
	    (remove-hook 'enter-workspace-hook pager-unhide))))

  (define (pager-autounhide/workspace)
    (if pager-autohide-enable
        (progn (pager-hide)
	       (unless (in-hook-p 'enter-workspace-hook pager-unhide)
	         (add-hook 'enter-workspace-hook pager-unhide)))
      (pager-unhide #:permanent t)
      (if (in-hook-p 'enter-workspace-hook pager-unhide)
	  (remove-hook 'enter-workspace-hook pager-unhide))))

  (define (pager-autounhide/edge-flip)
    (if pager-unhide-when-flip
        (progn (pager-hide)
	       (unless (in-hook-p 'enter-flipper-hook pager-unhide)
		 (add-hook 'enter-flipper-hook pager-unhide))
      (pager-unhide)
      (if (in-hook-p 'enter-flipper-hook pager-unhide)
          (remove-hook 'enter-flipper-hook pager-unhide)))))

  (define (pager-hide)
    (hide-window (get-window-by-class-re "Sawfishpager")))

  (define (pager-unhide #!key permanent)
    (if permanent
        (show-window (get-window-by-class-re "Sawfishpager"))
    (show-window (get-window-by-class-re "Sawfishpager"))
    (make-timer (lambda () (hide-window (get-window-by-class-re "Sawfishpager"))) pager-unhide-time)))

  ;; Push this module into the module 'user'.
  ;; pager.c invokes functions in this module via client-eval which
  ;; lives in 'user'.
  (user-require (structure-name (current-structure)))
  )
