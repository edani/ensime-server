;;; ensime-refactor.el
;;
;;;; License
;;
;;     Copyright (C) 2010 Aemon Cannon
;;
;;     This program is free software; you can redistribute it and/or
;;     modify it under the terms of the GNU General Public License as
;;     published by the Free Software Foundation; either version 2 of
;;     the License, or (at your option) any later version.
;;
;;     This program is distributed in the hope that it will be useful,
;;     but WITHOUT ANY WARRANTY; without even the implied warranty of
;;     MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
;;     GNU General Public License for more details.
;;
;;     You should have received a copy of the GNU General Public
;;     License along with this program; if not, write to the Free
;;     Software Foundation, Inc., 59 Temple Place - Suite 330, Boston,
;;     MA 02111-1307, USA.

(eval-when-compile (require 'cl))


(defvar ensime-search-mode nil
  "Enables the ensime-search minor mode.")

(defvar ensime-search-buffer-name "*ensime-search*"
  "Buffer to use for ensime-search.")

(defvar ensime-search-target-buffer-name "*ensime-search-results*"
  "Buffer name for target-buffer.")

(defvar ensime-search-target-buffer nil
  "Buffer to which the ensime-search is applied to.")

(defvar ensime-search-target-window nil
  "Window to which the ensime-search is applied to.")

(defvar ensime-search-window-config nil
  "Old window configuration.")

(defvar ensime-search-mode-string ""
  "String in mode line for additional info.")

(defvar ensime-search-current-results '()
  "The most recent ensime-search result list.")

(defvar ensime-search-current-selected-result '()
  "The currently selected ensime-search result.")

(defvar ensime-search-text ""
  "The active filter text.")

(defvar ensime-search-min-length 2
  "The minimum length a search must be
 before rpc call is placed..")

(defvar ensime-search-max-results 50
  "The max number of results to return per rpc call.")


(defvar ensime-search-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map "\C-c\C-q" 'ensime-search-quit)
    (define-key map "\C-n" 'ensime-search-next-match)
    (define-key map "\C-p" 'ensime-search-prev-match)
    (define-key map [(return)] 'ensime-search-choose-current-result)
    map)
  "Keymap used by ensime-search.")


(defstruct ensime-search-result
  "A ensime-search search result.

  * summary
     The full body of text presented in the results list,
     may contain leading and trailing text, in addition to the match.

  * metadata

  * match-file-name
    The filename of the buffer containing the match

  * match-start
    The point in buffer at which the match started

  * match-end
    The point in buffer at which the match ended

  * match-line
    The line number in buffer match started

  * match-summary-offset
    Within summary, the offset at which the match begins

  * match-length
    The length of the match

  * summary-start
    The offset at which summary begins in the results buffer.

  * data
  "
  (summary nil)
  (metadata nil)
  (match-file-name nil)
  (match-start nil)
  (match-end nil)
  (match-line nil)
  (match-summary-offset nil)
  (match-length nil)
  (summary-start 0)
  (data nil)
  )


(defun ensime-search ()
  "The main entrypoint for ensime-search-mode.
   Initiate an incremental search of all live buffers."
  (interactive)
  (ensime-with-conn-interactive
   conn
   (if (and (string= (buffer-name) ensime-search-buffer-name)
	    (memq major-mode '(ensime-search-mode)))

       (message "Already in ensime-search buffer")

     (setq ensime-search-target-buffer
	   (switch-to-buffer-other-window
	    (get-buffer-create ensime-search-target-buffer-name)))
     (setq ensime-search-target-window (selected-window))
     (setq ensime-search-window-config (current-window-configuration))
     (setq ensime-buffer-connection conn)

     (select-window (split-window (selected-window) (- (window-height) 4)))
     (switch-to-buffer (get-buffer-create ensime-search-buffer-name))
     (setq ensime-buffer-connection conn)
     (erase-buffer)
     (ensime-search-mode)
     (ensime-search-update-target-buffer)
     )))



(defun ensime-search-mode ()
  "Major mode for incrementally seaching through all open buffers."
  (interactive)
  (setq major-mode 'ensime-search-mode
        mode-name "ensime-search-mode")

  (use-local-map ensime-search-mode-map)

  (setq	ensime-search-mode-string  ""
	ensime-search-mode-valid-string ""
	mode-line-buffer-identification
	'(25 . ("%b" ensime-search-mode-string ensime-search-valid-string)))

  (ensime-search-update-modestring)
  (make-local-variable 'after-change-functions)
  (add-hook 'after-change-functions
	    'ensime-search-auto-update)
  (make-local-variable 'ensime-search-kill-buffer)
  (add-hook 'kill-buffer-hook 'ensime-search-kill-buffer nil t)
  )


(defun ensime-search-quit ()
  "Quit the ensime-search mode."
  (interactive)
  (kill-buffer ensime-search-buffer-name)
  (set-window-configuration ensime-search-window-config))


(defun ensime-search-choose-current-result ()
  "Jump to the target of the currently selected ensime-search-result."
  (interactive)
  (when (and (ensime-search-result-p ensime-search-current-selected-result)
	     (get-buffer ensime-search-buffer-name))
    (switch-to-buffer ensime-search-buffer-name)
    (let ((ensime-dispatching-connection ensime-buffer-connection))
      (kill-buffer-and-window)
      (let* ((r ensime-search-current-selected-result)
	     (item (ensime-search-result-data r)))

	;; If the chosen item has a source location,
	;; jump there..
	(let ((pos (ensime-search-sym-pos item)))
	  (let* ((file-name (ensime-pos-file pos))
		 (offset (+ (ensime-pos-offset pos) ensime-ch-fix)))
	    (if (and file-name
		     (integerp (string-match
				"\\.scala$\\|\\.java$"
				file-name)))
		(progn
		  (find-file file-name)
		  (goto-char offset))

	      ;; Otherwise, open the inspector
	      (let ((decl-as (ensime-search-sym-decl-as item)))
		(cond
		 ((or (equal decl-as 'method)
		      (equal decl-as 'field))
		  (ensime-inspect-by-path
		   (ensime-search-sym-owner-name item)))

		 (t (ensime-inspect-by-path
		     (ensime-search-sym-name item)))))
	      )))))))


(defun ensime-search-next-match ()
  "Go to next match in the ensime-search target window."
  (interactive)
  (if (and ensime-search-current-results
	   ensime-search-current-selected-result)
      (let* ((i (position ensime-search-current-selected-result
			  ensime-search-current-results))
	     (len (length ensime-search-current-results))
	     (next (if (< (+ i 1) len)
		       (nth (+ i 1) ensime-search-current-results)
		     (nth 0 ensime-search-current-results))))
	(setq ensime-search-current-selected-result next)
	(ensime-search-update-result-selection)
	)))


(defun ensime-search-prev-match ()
  "Go to previous match in the ensime-search target window."
  (interactive)
  (if (and ensime-search-current-results
	   ensime-search-current-selected-result)
      (let* ((i (position ensime-search-current-selected-result
			  ensime-search-current-results))
	     (len (length ensime-search-current-results))
	     (next (if (> i 0)
		       (nth (- i 1) ensime-search-current-results)
		     (nth (- len 1) ensime-search-current-results))))
	(setq ensime-search-current-selected-result next)
	(ensime-search-update-result-selection)
	)))


;;
;; Non-interactive functions below
;;



(defun ensime-search-update-result-selection ()
  "Move cursor to current result selection in target buffer."
  (if (ensime-search-result-p ensime-search-current-selected-result)
      (with-current-buffer ensime-search-target-buffer
	(let ((target-point (ensime-search-result-summary-start
			     ensime-search-current-selected-result)))
	  (set-window-point ensime-search-target-window target-point)
	  ))))

(defun ensime-search-is-case-sensitive ()
  "Is the active search case-sensitive?"
  (let ((case-fold-search nil))
    (and ensime-search-text
	 (integerp (string-match "[A-Z]" ensime-search-text)))))


(defun ensime-search-auto-update (beg end lenold &optional force)
  "Called from `after-update-functions' to update the display.
 BEG, END and LENOLD are passed in from the hook.
 An actual update is only done if the regexp has changed or if the
 optional fourth argument FORCE is non-nil."
  (let ((new-query (buffer-string)))
    (when (not (equal new-query ensime-search-text))
      (setq ensime-search-text new-query)
      (if (>= (length new-query) ensime-search-min-length)
	  (ensime-rpc-async-public-symbol-search
	   (list new-query)
	   ensime-search-max-results
	   (ensime-search-is-case-sensitive)
	   (lambda (info)
	     (when (buffer-live-p ensime-search-target-buffer)
	       (let ((results (ensime-search-make-results info)))
		 (setq ensime-search-current-results results)
		 (ensime-search-update-target-buffer)
		 ))))
	(with-current-buffer ensime-search-target-buffer
	  (setq ensime-search-current-results nil)
	  (ensime-search-update-target-buffer))
	))
    (force-mode-line-update)))


(defun ensime-search-assert-buffer-in-window ()
  "Assert that `ensime-search-target-buffer' is displayed in
 `ensime-search-target-window'."
  (if (not (eq ensime-search-target-buffer
	       (window-buffer ensime-search-target-window)))
      (set-window-buffer ensime-search-target-window
			 ensime-search-target-buffer)))

(defun ensime-search-update-modestring ()
  "Update the variable `ensime-search-mode-string' displayed in the mode line."
  (force-mode-line-update))

(defun ensime-search-kill-buffer ()
  "When the ensime-search buffer is killed, kill the target buffer."
  (remove-hook 'kill-buffer-hook 'ensime-search-kill-buffer)
  (if (buffer-live-p ensime-search-target-buffer)
      (kill-buffer ensime-search-target-buffer)))

(defun ensime-search-buffers-to-search ()
  "Return the list of buffers that are suitable for searching."
  (let ((all-buffers (buffer-list)))
    (remove-if
     (lambda (b)
       (let ((b-name (buffer-name b)))
	 (or (null (buffer-file-name b))
	     (equal b-name ensime-search-target-buffer-name)
	     (equal b-name ensime-search-buffer-name)
	     (equal b-name "*Messages*"))))
     all-buffers)))


(defun ensime-search-make-results (info)
  "Map the results of the rpc call into search result
 structures."
  (let ((items (car info)))
    (mapcar
     (lambda (item)
       (make-ensime-search-result
	:summary
	(ensime-search-sym-name item)

	:metadata
	(let ((decl-as (ensime-search-sym-decl-as item)))
	  (cond
	   ((or (equal decl-as 'method)
		(equal decl-as 'field))
	    (format "%s of %s" decl-as
		    (ensime-search-sym-owner-name item)))
	   (t
	    (format "%s" decl-as))))

	:match-file-name
	(when-let (pos (ensime-search-sym-pos item))
	  (ensime-pos-file pos))

	:match-start
	(when-let (pos (ensime-search-sym-pos item))
	  (+ (ensime-pos-offset pos) ensime-ch-fix))

	:match-end nil

	:match-line (when-let (pos (ensime-search-sym-pos item))
		      (ensime-pos-line pos))

	:match-summary-offset
	(let ((case-fold-search (not (ensime-search-is-case-sensitive))))
	  (or (string-match (replace-regexp-in-string
			     "\\$" "\\$"
			     ensime-search-text nil t)
			    (ensime-search-sym-name item)) 0))

	:match-length
	(length ensime-search-text)

	:data
	item

	)) items)))


(defun ensime-search-update-target-buffer ()
  "This is where the magic happens. Update the result list."
  (save-excursion
    (set-buffer ensime-search-target-buffer)
    (setq buffer-read-only nil)
    (goto-char (point-min))
    (erase-buffer)

    (ensime-insert-with-face
     (concat "Enter a type or method name. "
	     "Use C-n and C-p to navigate results. "
	     "RETURN to select.")
     'font-lock-constant-face)
    (insert "\n\n")

    (when ensime-search-current-results
      (setq ensime-search-current-selected-result
	    (first ensime-search-current-results)))

    (dolist (r ensime-search-current-results)

      ;; Save this for later use, for next/prev actions
      (setf (ensime-search-result-summary-start r) (point))

      (let ((p (point)))
	;; Insert the actual text, highlighting the matched substring
	(insert (format "%s  \n" (ensime-search-result-summary r)))
	(add-text-properties
	 (+ p (ensime-search-result-match-summary-offset r))
	 (+ p (ensime-search-result-match-summary-offset r)
	    (ensime-search-result-match-length r))
	 '(comment nil face font-lock-keyword-face)))

      ;; Insert metadata
      (when-let (m (ensime-search-result-metadata r))
	(ensime-insert-with-face
	 (format " %s\n" m)
	 'font-lock-comment-face))

      ;; Insert filename
      (when-let (f (ensime-search-result-match-file-name r))
	(ensime-insert-with-face (format " %s" f)
				 'font-lock-comment-face))

      (insert "\n\n")
      )

    (setq buffer-read-only t)
    (ensime-search-update-result-selection)
    ))



(provide 'ensime-search)



