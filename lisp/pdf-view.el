;;; pdf-view.el --- View PDF documents. -*- lexical-binding:t -*-

;; Copyright (C) 2013  Andreas Politz

;; Author: Andreas Politz <politza@fh-trier.de>
;; Keywords: files, doc-view, pdf

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:
;; 
;;; Code:
;; 

(require 'pdf-util)
(require 'pdf-info)



;; * ================================================================== *
;; * Customizations
;; * ================================================================== *

(defgroup pdf-view nil
  "View PDF documents."
  :group 'pdf-tools)

(defcustom pdf-view-display-size 'fit-width
  "The desired size of displayed pages.

This may be one of `fit-height', `fit-width', `fit-page' or a
number as a scale factor applied to the document's size.  Any
other value behaves like `fit-width'."
  :group 'pdf-view
  :type '(choice number
                 (const fit-height)
                 (const fit-width)
                 (const fit-page)))

(defcustom pdf-view-resize-factor 1.25
  "Fractional amount of resizing of one resize command."
  :group 'pdf-view
  :type 'number)
  
(defcustom pdf-view-continuous t
  "In Continuous mode reaching the page edge advances to next/previous page.

When non-nil, scrolling a line upward at the bottom edge of the page
moves to the next page, and scrolling a line downward at the top edge
of the page moves to the previous page."
  :type 'boolean
  :group 'pdf-view)

(defcustom pdf-view-bounding-box-margin 0.05
  "Fractional margin used for slicing with the bounding-box."
  :group 'pdf-view
  :type 'number)

(defcustom pdf-view-use-imagemagick nil
  "Whether imagemagick should be used for rendering.

This variable has no effect, if imagemagick was not compiled into
Emacs. FIXME: Explain dis-/advantages of imagemagick and png."
  :group 'pdf-view
  :type 'boolean)

(defcustom pdf-view-use-scaling nil
  "Whether images should be allowed to be scaled down for rendering.

This variable has no effect, if imagemagick was not compiled into
Emacs or `pdf-view-use-imagemagick' is nil.  FIXME: Explain
dis-/advantages of imagemagick and png."
  :group 'pdf-view
  :type 'boolean)

(defcustom pdf-view-prefetch-delay 0.5
  "Idle time in seconds before prefetching images starts."
  :group 'pdf-view
  :type 'number)

(defcustom pdf-view-prefetch-pages-function
  'pdf-view-prefetch-pages-function-default
  "A function returning a list of pages to be prefetched.

It is called with no arguments in the PDF window and should
return a list of page-numbers, determining the pages that should
be prefetched and their order."
  :group 'pdf-view
  :type 'function)


;; * ================================================================== *
;; * Internal variables and macros
;; * ================================================================== *

(defvar-local pdf-view--buffer-file-name nil
  "Local copy of remote files or nil.")

(defvar-local pdf-view--next-page-timer nil
  "Timer used in `pdf-view-next-page-command'.")

(defvar-local pdf-view--prefetch-pages nil
  "Pages to be prefetched.")

(defvar-local pdf-view--prefetch-timer nil
  "Timer used for prefetching images.")

(defvar-local pdf-view--hotspot-functions nil
  "Alist of hotspot functions.")

(defmacro pdf-view-current-page (&optional window)
  `(image-mode-window-get 'page ,window))
(defmacro pdf-view-current-overlay (&optional window)
  `(image-mode-window-get 'overlay ,window))
(defmacro pdf-view-current-image (&optional window)
  `(image-mode-window-get 'image ,window))
(defmacro pdf-view-current-slice (&optional window)
  `(image-mode-window-get 'slice ,window))


;; * ================================================================== *
;; * Major Mode
;; * ================================================================== *

(defvar pdf-view-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map image-mode-map)
    ;; Navigation in the document
    (define-key map (kbd "n")         'pdf-view-next-page-command)
    (define-key map (kbd "p")         'pdf-view-previous-page-command)
    (define-key map (kbd "<next>")    'forward-page)
    (define-key map (kbd "<prior>")   'backward-page)
    (define-key map [remap forward-page]  'pdf-view-next-page-command)
    (define-key map [remap backward-page] 'pdf-view-previous-page-command)
    (define-key map (kbd "SPC")       'pdf-view-scroll-up-or-next-page)
    (define-key map (kbd "S-SPC")     'pdf-view-scroll-down-or-previous-page)
    (define-key map (kbd "DEL")       'pdf-view-scroll-down-or-previous-page)
    (define-key map (kbd "C-n")       'pdf-view-next-line-or-next-page)
    (define-key map (kbd "<down>")    'pdf-view-next-line-or-next-page)
    (define-key map (kbd "C-p")       'pdf-view-previous-line-or-previous-page)
    (define-key map (kbd "<up>")      'pdf-view-previous-line-or-previous-page)
    (define-key map (kbd "M-<")       'pdf-view-first-page)
    (define-key map (kbd "M->")       'pdf-view-last-page)
    (define-key map [remap goto-line] 'pdf-view-goto-page)
    (define-key map (kbd "RET")       'image-next-line)
    ;; Zoom in/out.
    (define-key map "+"               'pdf-view-enlarge)
    (define-key map "="               'pdf-view-enlarge)
    (define-key map "-"               'pdf-view-shrink)
    (define-key map "0"               'pdf-view-scale-reset)
    ;; Fit the image to the window
    (define-key map "W"               'pdf-view-fit-width-to-window)
    (define-key map "H"               'pdf-view-fit-height-to-window)
    (define-key map "P"               'pdf-view-fit-page-to-window)
    ;; Slicing the image
    (define-key map (kbd "s m")       'pdf-view-set-slice-using-mouse)
    (define-key map (kbd "s b")       'pdf-view-set-slice-from-bounding-box)
    (define-key map (kbd "s r")       'pdf-view-reset-slice)
    ;; Searching
    (define-key map (kbd "C-c C-c")   'doc-view-mode)
    ;; Open a new buffer with doc's text contents
    (define-key map (kbd "C-c C-t")   'pdf-view-open-text)
    ;; Reconvert the current document.  Don't just use revert-buffer
    ;; because that resets the scale factor, the page number, ...
    (define-key map (kbd "g")         'pdf-view-revert-buffer)
    (define-key map (kbd "r")         'pdf-view-revert-buffer)
    map)
  "Keymap used by `pdf-view-mode' when displaying a doc as a set of images.")

(defun pdf-view-mode ()
  "Major mode in PDF buffers.

PDFView Mode is an Emacs PDF viewer.  It displays PDF files as
PNG images in Emacs buffers.

\\{pdf-view-mode-map}"

  (interactive)
  (kill-all-local-variables)
  ;; Setup a local copy for remote files.
  (when (or jka-compr-really-do-compress
            (let ((file-name-handler-alist nil))
              (not (and buffer-file-name
                        (file-readable-p buffer-file-name)))))
    (let ((tempfile (make-temp-file "pdf-view" nil ".pdf")))
      ;; FIXME: Delete this file sometime. Better: Create in pdf-tools
      ;; directory for all temporary files.
      (set-file-modes tempfile #o0700)
      (write-region nil nil tempfile)
      (setq-local pdf-view--buffer-file-name tempfile)))

  ;; Setup scroll functions
  (if (boundp 'mwheel-scroll-up-function) ; not --without-x build
      (setq-local mwheel-scroll-up-function
                  #'pdf-view-scroll-up-or-next-page))
  (if (boundp 'mwheel-scroll-down-function)
      (setq-local mwheel-scroll-down-function
                  #'pdf-view-scroll-down-or-previous-page))

  ;; Clearing overlays
  (add-hook 'change-major-mode-hook
            (lambda ()
              (remove-overlays (point-min) (point-max) 'pdf-view t))
            nil t)
  (remove-overlays (point-min) (point-max) 'pdf-view t) ;Just in case.

  ;; Keep track of display info
  (add-hook 'image-mode-new-window-functions
            'pdf-view-new-window-function nil t)
  (image-mode-setup-winprops)

  ;; Setup other local variables.
  (setq-local mode-line-position
              '(" P" (:eval (number-to-string (pdf-view-current-page)))
                "/" (:eval (number-to-string (pdf-cache-number-of-pages)))))
  (setq-local auto-hscroll-mode nil)
  ;; High values of scroll-conservatively seem to trigger some display
  ;; bug in xdisp.c:try_scrolling .
  (setq-local scroll-conservatively 0)
  (setq-local cursor-type nil)
  (setq mode-name "PDFView"
        buffer-read-only t
        major-mode 'pdf-view-mode)
  (setq-local view-read-only nil)
  (use-local-map pdf-view-mode-map)
  (add-hook 'window-configuration-change-hook
            'pdf-view-maybe-redisplay-resized-windows nil t)
  
  ;; Setup initial page and start display
  (unless (pdf-view-current-page)
    (pdf-view-goto-page 1))

  (run-mode-hooks 'pdf-view-mode-hook))

(defun pdf-view-buffer-file-name ()
  "Return the local filename of the PDF in the current buffer.

This may be different from `buffer-file-name', when operating on
a local copy of a remote file."
  (or pdf-view--buffer-file-name
      (buffer-file-name)))


;; * ================================================================== *
;; * Scaling
;; * ================================================================== *

(defun pdf-view-fit-page-to-window ()
  (interactive)
  (setq pdf-view-display-size 'fit-page)
  (image-set-window-vscroll 0)
  (image-set-window-hscroll 0)
  (pdf-view-redisplay t))

(defun pdf-view-fit-height-to-window ()
  (interactive)
  (setq pdf-view-display-size 'fit-height)
  (image-set-window-vscroll 0)
  (pdf-view-redisplay t))

(defun pdf-view-fit-width-to-window ()
  (interactive)
  (setq pdf-view-display-size 'fit-width)
  (image-set-window-hscroll 0)
  (pdf-view-redisplay t))

(defun pdf-view-enlarge (factor)
  (interactive
   (list (float pdf-view-resize-factor)))
  (let* ((size (pdf-view-image-size))
         (pagesize (pdf-cache-pagesize
                    (pdf-view-current-page)))
         (scale (/ (float (car size))
                   (float (car pagesize)))))
    (setq pdf-view-display-size
          (* factor scale))
    (pdf-view-redisplay t)))

(defun pdf-view-shrink (factor)
  (interactive
   (list (float pdf-view-resize-factor)))
  (pdf-view-enlarge (/ 1.0 factor)))

(defun pdf-view-scale-reset ()
  (interactive)
  (setq pdf-view-display-size 1.0)
  (pdf-view-redisplay t))   



;; * ================================================================== *
;; * Moving by pages and scrolling
;; * ================================================================== *



(defcustom pdf-view-before-change-page-hook nil
  "Hook run before changing to another page."
  :group 'pdf-view
  :type 'hook)

(defcustom pdf-view-after-change-page-hook nil
  "Hook run after changing to another page."
  :group 'pdf-view
  :type 'hook)

(defun pdf-view-goto-page (page &optional window)
  (interactive
   (list (if current-prefix-arg
             (prefix-numeric-value current-prefix-arg)
           (read-number "Page: "))))
  (unless (and (>= page 1)
               (<= page (pdf-cache-number-of-pages)))
    (error "No such page: %d" page))
  (unless window
    (setq window
          (if (pdf-util-pdf-window-p)
              (selected-window)
            t)))
  (save-selected-window
    ;; Select the window for the hooks below.
    (when (window-live-p window)
      (select-window window))
    (let ((changing-p
           (not (eq page (pdf-view-current-page window)))))
      (when changing-p
        (run-hooks 'pdf-view-before-change-page-hook))
      (setf (pdf-view-current-page window) page)
      (when (window-live-p window)
        (pdf-view-redisplay window))
      (when changing-p
        (force-mode-line-update)
        (run-hooks 'pdf-view-after-change-page-hook))))
  nil)

(defun pdf-view-next-page (&optional n)
  (interactive "p")
  (pdf-view-goto-page (+ (pdf-view-current-page)
                         (or n 1))))

(defun pdf-view-previous-page (&optional n)
  (interactive "p")
  (pdf-view-next-page (- (or n 1))))

(defun pdf-view-next-page-command (&optional n)
  (declare (interactive-only pdf-view-next-page))
  (interactive "p")
  (unless n (setq n 1))
  (when (> (+ (pdf-view-current-page) n)
           (pdf-cache-number-of-pages))
    (user-error "Last page"))
  (when (< (+ (pdf-view-current-page) n) 1)
    (user-error "First page"))
  (let ((pdf-view-inhibit-redisplay t))
    (pdf-view-goto-page
     (+ (pdf-view-current-page) n)))
  (force-mode-line-update)
  (sit-for 0)
  (when pdf-view--next-page-timer
    (cancel-timer pdf-view--next-page-timer)
    (setq pdf-view--next-page-timer nil))
  (if (or (not (input-pending-p))
          (and (> n 0)
               (= (pdf-view-current-page)
                  (pdf-cache-number-of-pages)))
          (and (< n 0)
               (= (pdf-view-current-page) 1)))
      (pdf-view-redisplay)
    (setq pdf-view--next-page-timer
          (run-with-idle-timer 0.001 nil 'pdf-view-redisplay (selected-window)))))

(defun pdf-view-previous-page-command (&optional n)
  (declare (interactive-only pdf-view-previous-page))
  (interactive "p")
  (with-no-warnings
    (pdf-view-next-page-command (- (or n 1)))))

(defun pdf-view-first-page ()
  "View the first page."
  (interactive)
  (pdf-view-goto-page 1))

(defun pdf-view-last-page ()
  "View the last page."
  (interactive)
  (pdf-view-goto-page (pdf-cache-number-of-pages)))

(defun pdf-view-scroll-up-or-next-page (&optional arg)
  "Scroll page up ARG lines if possible, else goto next page.
When `pdf-view-continuous' is non-nil, scrolling upward
at the bottom edge of the page moves to the next page.
Otherwise, goto next page only on typing SPC (ARG is nil)."
  (interactive "P")
  (if (or pdf-view-continuous (null arg))
      (let ((hscroll (window-hscroll))
	    (cur-page (pdf-view-current-page)))
	(when (= (window-vscroll) (image-scroll-up arg))
	  (pdf-view-next-page)
	  (when (/= cur-page (pdf-view-current-page))
	    (image-bob)
	    (image-bol 1))
	  (set-window-hscroll (selected-window) hscroll)))
    (image-scroll-up arg)))

(defun pdf-view-scroll-down-or-previous-page (&optional arg)
  "Scroll page down ARG lines if possible, else goto previous page.
When `pdf-view-continuous' is non-nil, scrolling downward
at the top edge of the page moves to the previous page.
Otherwise, goto previous page only on typing DEL (ARG is nil)."
  (interactive "P")
  (if (or pdf-view-continuous (null arg))
      (let ((hscroll (window-hscroll))
	    (cur-page (pdf-view-current-page)))
	(when (= (window-vscroll) (image-scroll-down arg))
	  (pdf-view-previous-page)
	  (when (/= cur-page (pdf-view-current-page))
	    (image-eob)
	    (image-bol 1))
	  (set-window-hscroll (selected-window) hscroll)))
    (image-scroll-down arg)))

(defun pdf-view-next-line-or-next-page (&optional arg)
  "Scroll upward by ARG lines if possible, else goto next page.
When `pdf-view-continuous' is non-nil, scrolling a line upward
at the bottom edge of the page moves to the next page."
  (interactive "p")
  (if pdf-view-continuous
      (let ((hscroll (window-hscroll))
	    (cur-page (pdf-view-current-page)))
	(when (= (window-vscroll) (image-next-line arg))
	  (pdf-view-next-page)
	  (when (/= cur-page (pdf-view-current-page))
	    (image-bob)
	    (image-bol 1))
	  (set-window-hscroll (selected-window) hscroll)))
    (image-next-line 1)))

(defun pdf-view-previous-line-or-previous-page (&optional arg)
  "Scroll downward by ARG lines if possible, else goto previous page.
When `pdf-view-continuous' is non-nil, scrolling a line downward
at the top edge of the page moves to the previous page."
  (interactive "p")
  (if pdf-view-continuous
      (let ((hscroll (window-hscroll))
	    (cur-page (pdf-view-current-page)))
	(when (= (window-vscroll) (image-previous-line arg))
	  (pdf-view-previous-page)
	  (when (/= cur-page (pdf-view-current-page))
	    (image-eob)
	    (image-bol 1))
	  (set-window-hscroll (selected-window) hscroll)))
    (image-previous-line arg)))


;; * ================================================================== *
;; * Slicing
;; * ================================================================== *

(defun pdf-view-set-slice (x y width height &optional window)
  "Set the slice of the pages that should be displayed.

X, Y, WIDTH and HEIGHT should be relative coordinates, i.e. in
\[0;1\].  To reset the slice use `pdf-view-reset-slice'."
  (unless (equal (pdf-view-current-slice window)
                 (list x y width height))
    (setf (pdf-view-current-slice window)
          (mapcar (lambda (v)
                    (max 0 (min 1 v)))
                  (list x y width height)))
    (pdf-view-redisplay window)))

(defun pdf-view-set-slice-using-mouse ()
  "Set the slice of the images that should be displayed.
You set the slice by pressing mouse-1 at its top-left corner and
dragging it to its bottom-right corner.  See also
`pdf-view-set-slice' and `pdf-view-reset-slice'."
  (interactive)
  (let ((size (pdf-view-image-size))
        x y w h done)
    (while (not done)
      (let ((e (read-event
		(concat "Press mouse-1 at the top-left corner and "
			"drag it to the bottom-right corner!"))))
	(when (eq (car e) 'drag-mouse-1)
	  (setq x (car (posn-object-x-y (event-start e))))
	  (setq y (cdr (posn-object-x-y (event-start e))))
	  (setq w (- (car (posn-object-x-y (event-end e))) x))
	  (setq h (- (cdr (posn-object-x-y (event-end e))) y))
	  (setq done t))))
    (apply 'pdf-view-set-slice
           (pdf-util-scale-edges
            (list x y w h)
            (cons (/ 1.0 (float (car size)))
                  (/ 1.0 (float (cdr size))))))))

(defun pdf-view-set-slice-from-bounding-box (&optional window)
  "Set the slice from the page's bounding-box.

The result is that the margins are almost completely cropped,
much more accurate than could be done manually using
`pdf-view-set-slice-using-mouse'.

See also `pdf-view-bounding-box-margin'."
  (interactive)
  (let* ((bb (pdf-cache-boundingbox (pdf-view-current-page window)))
         (margin (max 0 (or pdf-view-bounding-box-margin 0)))
         (slice (list (- (nth 0 bb)
                         (/ margin 2.0))
                      (- (nth 1 bb)
                         (/ margin 2.0))
                      (+ (- (nth 2 bb) (nth 0 bb))
                         margin)
                      (+ (- (nth 3 bb) (nth 1 bb))
                         margin))))
    (apply 'pdf-view-set-slice
           (append slice (and window (list window))))))

(defun pdf-view-reset-slice (&optional window)
  "Reset the current slice.

After calling this function the whole page will be visible
again."
  (interactive)
  (when (pdf-view-current-slice window)
    (setf (pdf-view-current-slice window) nil)
    (pdf-view-redisplay window))
  nil)



;; * ================================================================== *
;; * Display
;; * ================================================================== *

(defvar pdf-view-inhibit-redisplay nil)

(defun pdf-view-image-type ()
  "Return the image-type which should be used.

The return value is either imagemagick (if available and wanted)
or png."
  (if (and pdf-view-use-imagemagick
           (fboundp 'imagemagick-types))
      'imagemagick
    'png))

(defun pdf-view-use-scaling-p ()
  (and (eq 'imagemagick
           (pdf-view-image-type))
       pdf-view-use-scaling))

(defmacro pdf-view-create-image (data &rest props)
  "Like `create-image', but with set DATA-P and TYPE arguments."
  (declare (indent 1) (debug t))
  `(create-image ,data (pdf-view-image-type) t ,@props))

(defun pdf-view-create-page (page &optional window inhibit-hotspots-p)
  "Create an image of PAGE for display on WINDOW."
  (let* ((size (pdf-view-desired-image-size page window))
         (data (pdf-cache-renderpage
                page (car size)
                (if (not (pdf-view-use-scaling-p))
                    (car size)
                  (* 2 (car size)))))
         (hotspots (unless inhibit-hotspots-p
                     (pdf-view-apply-hotspot-functions
                      window page size))))
    (pdf-view-create-image data 
      :width (car size)
      :map hotspots
      :pointer 'arrow)))

(defun pdf-view-image-size (&optional displayed-p window)
  "Return the size in pixel of the current image.

If DISPLAYED-P is non-nil, returned the size of the displayed
image.  These may be different, if slicing is in use."
  (if displayed-p
      (with-selected-window (or window (selected-window))
        (image-display-size
         (image-get-display-property) t))
    (image-size (pdf-view-current-image window) t)))

(defalias 'pdf-util-image-size 'pdf-view-image-size)

(defun pdf-view-image-offset (&optional window)
  "Return the offset of the current image.

It is equal to \(LEFT . TOP\) of the current slice in pixel."

  (let* ((slice (pdf-view-current-slice window)))
    (cond
     (slice
      (pdf-util-scale-relative-to-pixel
       (cons (nth 0 slice) (nth 1 slice))
       window))
     (t
      (cons 0 0)))))

(defun pdf-view-display-page (page &optional window inhibit-hotspots-p)
  "Display page PAGE in WINDOW."
  (pdf-view-display-image
   (pdf-view-create-page page window inhibit-hotspots-p)
   window))

(defun pdf-view-display-image (image &optional window inhibit-slice-p)
  (let ((ol (pdf-view-current-overlay window)))
    (when (window-live-p (overlay-get ol 'window))
      (let* ((size (image-size image t))
             (slice (if (not inhibit-slice-p)
                        (pdf-view-current-slice window)))
             (displayed-width (floor
                               (if slice
                                   (* (nth 2 slice)
                                      (car (image-size image)))
                                 (car (image-size image))))))
        (setf (pdf-view-current-image window) image)
        (move-overlay ol (point-min) (point-max))
        ;; In case the window is wider than the image, center the image
        ;; horizontally.
        (overlay-put ol 'before-string
                     (when (> (window-width window)
                              displayed-width)
                       (propertize " " 'display
                                   `(space :align-to
                                           ,(/ (- (window-width window)
                                                  displayed-width) 2)))))
        (overlay-put ol 'display
                     (if slice
                         (list (cons 'slice
                                     (pdf-util-scale-edges slice size))
                               image)
                       image))
        (let* ((win (overlay-get ol 'window))
               (hscroll (image-mode-window-get 'hscroll win))
               (vscroll (image-mode-window-get 'vscroll win)))
          ;; Reset scroll settings, in case they were changed.
          (if hscroll (set-window-hscroll win hscroll))
          (if vscroll (set-window-vscroll win vscroll)))))))

(defun pdf-view-redisplay (&optional window)
  "Redisplay page in WINDOW.

If WINDOW is t, redisplay pages in all windows."
  (unless pdf-view-inhibit-redisplay
    (let ((windows
           (cond ((eq t window)
                  (get-buffer-window-list nil nil t))
                 ((null window)
                  (list (selected-window)))
                 (t (list window)))))
      (dolist (win windows)
        (pdf-view-display-page
         (pdf-view-current-page win)
         win)))))

(defun pdf-view-maybe-redisplay-resized-windows ()
  (unless (numberp pdf-view-display-size)
    (dolist (window (get-buffer-window-list nil nil t))
      (let ((stored (window-parameter window 'pdf-view-window-size))
            (size (cons (window-width window)
                        (window-height window))))
        (unless (equal size stored)
          (set-window-parameter window 'pdf-view-window-size size)
          (pdf-view-redisplay window))))))

(defun pdf-view-new-window-function (winprops)
  ;; (message "New window %s for buf %s" (car winprops) (current-buffer))
  (cl-assert (or (eq t (car winprops))
                 (eq (window-buffer (car winprops)) (current-buffer))))
  (let ((ol (image-mode-window-get 'overlay winprops)))
    (if ol
        (progn
          (setq ol (copy-overlay ol))
          ;; `ol' might actually be dead.
          (move-overlay ol (point-min) (point-max)))
      (setq ol (make-overlay (point-min) (point-max) nil t))
      (overlay-put ol 'pdf-view t))
    (overlay-put ol 'window (car winprops))
    (unless (windowp (car winprops))
      ;; It's a pseudo entry.  Let's make sure it's not displayed (the
      ;; `window' property is only effective if its value is a window).
      (cl-assert (eq t (car winprops)))
      (delete-overlay ol))
    (image-mode-window-put 'overlay ol winprops)
    ;; Clean up some overlays.
    (dolist (ov (overlays-in (point-min) (point-max)))
      (when (and (windowp (overlay-get ov 'window))
                 (not (window-live-p (overlay-get ov 'window))))
        (delete-overlay ov)))
    (when (and (windowp (car winprops))
               (null (pdf-view-current-image (car winprops))))
      ;; We're not displaying an image yet, so let's do so.  This happens when
      ;; the buffer is displayed for the first time.
      ;; Don't do it if there's a conversion is running, since in that case, it
      ;; will be done later.
      (with-selected-window (car winprops)
        (set-window-parameter
         nil
         'pdf-view-window-size (cons (window-width)
                                     (window-height)))
        (pdf-view-goto-page
         (or (image-mode-window-get 'page t) 1))))))

(defun pdf-view-desired-image-size (&optional page window)
  (let* ((pagesize (pdf-cache-pagesize
                    (or page (pdf-view-current-page window))))
         (slice (pdf-view-current-slice window))
         (width-scale (/ (/ (float (window-width window t))
                            (or (nth 2 slice) 1.0))
                         (float (car pagesize))))
         (height (- (nth 3 (window-inside-pixel-edges window))
                    (nth 1 (window-inside-pixel-edges window))
                    1))
         (height-scale (/ (/ (float height)
                             (or (nth 3 slice) 1.0))
                          (float (cdr pagesize))))
         (scale width-scale))
    (if (numberp pdf-view-display-size)
        (setq scale (float pdf-view-display-size))
      (cl-case pdf-view-display-size
        (fit-page
         (setq scale (min height-scale width-scale)))
        (fit-height
         (setq scale height-scale))
        (t
         (setq scale width-scale))))
    (cons (floor (max 1 (* (car pagesize) scale)))
          (floor (max 1 (* (cdr pagesize) scale))))))


;; * ================================================================== *
;; * Hotspot handling
;; * ================================================================== *

(defun pdf-view-add-hotspot-function (fn &optional layer)
  "Register FN as a hotspot function in the current buffer, using LAYER.

FN will be called in the PDF buffer with the page-number and the
image size \(WIDTH . HEIGHT\) as arguments.  It should return a
list of hotspots applicable to the the :map image-property.

LAYER determines the order: Functions in a higher LAYER will
supercede hotspots in lower ones."
  (push (cons (or layer 0) fn)
        pdf-view--hotspot-functions))

(defun pdf-view-remove-hotspot-function (fn)
  "Unregister FN as a hotspot function in the current buffer."
  (setq pdf-view--hotspot-functions
        (cl-remove fn pdf-view--hotspot-functions
                   :key 'cdr)))

(defun pdf-view-sorted-hotspot-functions ()
  (mapcar 'cdr (cl-sort (copy-sequence pdf-view--hotspot-functions)
                        '> :key 'car)))

(defun pdf-view-apply-hotspot-functions (window page image-size)
  (save-selected-window
    (when window (select-window window))
    (apply 'nconc
           (mapcar (lambda (fn)
                     (funcall fn page image-size))
                   (pdf-view-sorted-hotspot-functions)))))


;; * ================================================================== *
;; * Prefetching images
;; * ================================================================== *

(defun pdf-view-prefetch-pages-function-default ()
  (let ((page (pdf-view-current-page)))
    (cl-remove-duplicates
     (cl-remove-if-not
      (lambda (page)
        (and (>= page 1)
             (<= page (pdf-cache-number-of-pages))))
      (append
       ;; +1, -1, +2, -2, ...
       (let ((sign 1)
             (incr 1))
         (mapcar (lambda (i)
                   (setq page (+ page (* sign incr))
                         sign (- sign)
                         incr (1+ incr))
                   page)
                 (number-sequence 1 16)))
       ;; First and last
       (list 1 (pdf-cache-number-of-pages))
       ;; Links
       (mapcar
        'cadddr
        (cl-remove-if-not
         (lambda (link) (eq (cadr link) 'goto-dest))
         (pdf-cache-pagelinks
          (pdf-view-current-page)))))))))

(defun pdf-view--prefetch-pages (window image-width)
  (when (eq window (selected-window))
    (let ((page (pop pdf-view--prefetch-pages)))
      (while (and page
                  (pdf-cache-lookup-image
                   page
                   image-width
                   (if (not (pdf-view-use-scaling-p))
                       image-width
                     (* 2 image-width))))
        (setq page (pop pdf-view--prefetch-pages)))
      (if (null page)
          (pdf-tools-debug "Prefetching done.")
        (let ((pdf-info-asynchronous
               (lambda (status data)
                 (when (and (null status)
                            (eq window
                                (selected-window)))
                   (with-current-buffer (window-buffer)
                     (pdf-cache-put-image
                      page image-width data)
                     (image-size (pdf-view-create-page page))
                     (pdf-tools-debug "Prefetched Page %s." page)
                     ;; Avoid max-lisp-eval-depth
                     (run-with-timer
                         0.001 nil 'pdf-view--prefetch-pages window image-width))))))
          (pdf-info-renderpage page image-width))))))

(defun pdf-view--prefetch-start (buffer)
  "Start prefetching images in BUFFER."
  (when (and pdf-view-prefetch-mode
             (not isearch-mode)
             (null pdf-view--prefetch-pages)
             (eq (window-buffer) buffer)
             (fboundp pdf-view-prefetch-pages-function))
    (let ((pages (funcall pdf-view-prefetch-pages-function)))
      (setq pdf-view--prefetch-pages
            (butlast pages (max 0 (- (length pages)
                                     pdf-cache-image-limit))))
      (pdf-view--prefetch-pages
       (selected-window)
       (car (pdf-view-desired-image-size))))))

(defun pdf-view--prefetch-stop ()
  "Stop prefetching images in current buffer."
  (setq pdf-view--prefetch-pages nil))
  
(defun pdf-view--prefetch-cancel ()
  "Cancel prefetching images in current buffer."
  (pdf-view--prefetch-stop)
  (when pdf-view--prefetch-timer
    (cancel-timer pdf-view--prefetch-timer))
  (setq pdf-view--prefetch-timer nil))

(define-minor-mode pdf-view-prefetch-mode
  "Try to load images which will probably be needed in a while."
  nil nil t
  
  (pdf-view--prefetch-cancel)
  (add-hook 'after-change-major-mode-hook
            'pdf-view--prefetch-cancel nil t)            
  (cond
   (pdf-view-prefetch-mode
    (add-hook 'pre-command-hook 'pdf-view--prefetch-stop nil t)
    (setq pdf-view--prefetch-timer
          (run-with-idle-timer (or pdf-view-prefetch-delay 1)
              t 'pdf-view--prefetch-start (current-buffer))))
   (t
    (remove-hook 'pre-command-hook 'pdf-view--prefetch-stop t))))

(provide 'pdf-view)
;;; pdf-view.el ends here
