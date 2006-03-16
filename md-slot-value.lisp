;; -*- mode: Lisp; Syntax: Common-Lisp; Package: cells; -*-
;;;
;;; Copyright (c) 1995,2003 by Kenneth William Tilton.
;;;
;;; Permission is hereby granted, free of charge, to any person obtaining a copy 
;;; of this software and associated documentation files (the "Software"), to deal 
;;; in the Software without restriction, including without limitation the rights 
;;; to use, copy, modify, merge, publish, distribute, sublicense, and/or sell 
;;; copies of the Software, and to permit persons to whom the Software is furnished 
;;; to do so, subject to the following conditions:
;;;
;;; The above copyright notice and this permission notice shall be included in 
;;; all copies or substantial portions of the Software.
;;;
;;; THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR 
;;; IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, 
;;; FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE 
;;; AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER 
;;; LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING 
;;; FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS 
;;; IN THE SOFTWARE.

(in-package :cells)

(defparameter *ide-app-hard-to-kill* nil)

(defun md-slot-value (self slot-name &aux (c (md-slot-cell self slot-name)))
  (tagbody
    retry
    (when *stop*
      (if *ide-app-hard-to-kill*
          (progn
            (princ #\.)
            (return-from md-slot-value))
        (restart-case
            (error "Cells is stopped due to a prior error.")
          (continue ()
            :report "Return a slot value of nil."
            (return-from md-slot-value nil))
          (reset-cells ()
            :report "Reset cells and retry getting the slot value."
            (cells-reset)
            (go retry))))))
  
  ;; (count-it :md-slot-value slot-name)
  (if c
      (prog1
          (with-integrity ()
            (c-value-ensure-current c :md-slot-value))
        (when (car *c-calculators*)
          (c-link-ex c)))
    (values (bd-slot-value self slot-name) nil)))
  
(defun c-value-ensure-current (c &optional (debug-id :anon-caller))
  (declare (ignorable debug-id))
  (count-it :c-value-ensure-current)
  (trc nil "c-value-ensure-current >" c)
  (cond
   ((c-currentp c)(trc nil "c-currentp" c)) ;; used to follow c-inputp, but I am toying with letting ephemerals (inputs) fall obsolete
   ;; and then get reset here (ie, ((c-input-p c) (c-ephemeral-reset c))). ie, do not assume inputs are never obsolete
   ;;
   ((c-inputp c)(trc nil "c-inputp" c)) ;; always current (for now; see above)

   ((or (not (c-validp c))
      (some (lambda (used)
              (c-value-ensure-current used :recursive-used)
              (trc nil "comparing pulses (user, used): " (c-pulse c)(c-pulse used))
              (when (and (c-changed used) (> (c-pulse used)(c-pulse c)))
                 (trc nil "used changed" c used)
                t))
        (cd-useds c)))
    (trc nil "ensuring current calc-set of" (c-slot-name c) debug-id)
    (c-calculate-and-set c))

   (t (c-pulse-update c :valid-uninfluenced)))

  (when (c-unboundp c)
    (error 'unbound-cell :instance (c-model c) :name (c-slot-name c)))

  (c-value c))

(defun c-calculate-and-set (c)
  (flet ((body ()
           (when (c-stopped)
             (princ #\.)
             (return-from c-calculate-and-set))
    
           (when (find c *c-calculators*) ;; circularity
             (trc "c-calculate-and-set breaking on circularity" c)
             (c-break ;; break is problem when testing cells on some CLs
              "cell ~a midst askers: ~a" c *c-calculators*))
           (trc nil "calcing, calcers" (c-slot-name c) (mapcar 'c-slot-name *c-calculators*))
           (count-it :c-calculate-and-set)
           ;;;  (count-it :c-calculate-and-set (type-of (c-model c))) ;; (c-slot-name c))
    
           (cd-usage-clear-all c)
    
           (multiple-value-bind (raw-value propagation-code)
               (let ((*c-calculators* (cons c *c-calculators*))
                     (*defer-changes* t))
                 (funcall (cr-rule c) c))
             (when (and *c-debug* (typep raw-value 'cell))
               (c-break "new value for cell ~s is itself a cell: ~s. probably nested (c? ... (c? ))"
                 c raw-value))
        
             (c-unlink-unused c)
             (trc nil "calc-set calling md-sv-assum" c propagation-code)
             (md-slot-value-assume c raw-value propagation-code))))
    (if nil ;; *dbg*
        (ukt::wtrc (0 100 "calcnset" c) (body))
      (body))))

;-------------------------------------------------------------

(defun md-slot-makunbound (self slot-name
                            &aux (c (md-slot-cell self slot-name)))
  (unless c
    (c-break ":md-slot-makunbound > cellular slot ~a of ~a cannot be unbound unless initialized as inputp"
      slot-name self))
  
  (when (c-unboundp c)
    (return-from md-slot-makunbound nil))

  (when *within-integrity* ;; 2006-02 oops, bad name
    (c-break "md-slot-makunbound of ~a must be deffered by wrapping code in with-integrity" c))
  
  ; 
  ; Big change here for Cells III: before, only the propagation was deferred. Man that seems
  ; wrong. So now the full makunbound processing gets deferred. Less controversially,
  ; by contrast the without-c-dependency wrapped everything, and while that is harmless,
  ; it is also unnecessary and could confuse people trying to follow the logic.
  ;
  (let ((causation *causation*))
    (with-integrity (:change c)
      (let ((*causation* causation))
        ; --- cell & slot maintenance ---
        (let ((prior-value (c-value c)))
          (setf (c-value-state c) :unbound
            (c-value c) nil
            (c-state c) :awake)
          (bd-slot-makunbound self slot-name)
          ;
          ; --- data flow propagation -----------
          ;
          (setf (c-changed c) t)
          (without-c-dependency
              (c-propagate c prior-value t)))))))

;;; --- setf md-slot-value --------------------------------------------------------
;;;

(defun (setf md-slot-value) (new-value self slot-name
                              &aux (c (md-slot-cell self slot-name)))
  
  (when *c-debug*
    (c-setting-debug self slot-name c new-value))
  
  (unless c
    (c-break "(setf md-slot-value)> cellular slot ~a of ~a cannot be setf unless initialized as inputp"
      slot-name self))

  (when *defer-changes*
    (c-break "SETF of ~a must be deferred by wrapping code in WITH-INTEGRITY" c))

  (with-integrity (:change)
    (md-slot-value-assume c new-value nil))

  new-value)
                    
(defmethod md-slot-value-assume (c raw-value propagation-code)
  (assert c)
  (without-c-dependency
      (let ((prior-state (c-value-state c))
            (prior-value (c-value c))
            (absorbed-value (c-absorb-value c raw-value)))
        
        ; --- slot maintenance ---
        (unless (c-synaptic c)
          (md-slot-value-store (c-model c) (c-slot-name c) absorbed-value))
        
        ; --- cell maintenance ---
        (c-pulse-update c :slotv-assume)
        (setf
         (c-value c) absorbed-value
         (c-value-state c) :valid
         (c-state c) :awake)
        
        (unless (typep c 'c-stream) ;; c-stream (actually a FNYI) needs to run out first stream at least
          (c-optimize-away?! c)) ;;; put optimize test here to avoid needless linking
        
        
        ; --- data flow propagation -----------
        ;
        (trc nil "md-sv comparing no-prop" c prior-state absorbed-value prior-value)
        (if (or (eq propagation-code :no-propagate) ;; possible if c is a cell serving as a synapse between two cells
              (and (null propagation-code)
                (eql prior-state :valid)
                (c-no-news c absorbed-value prior-value)))
            (progn
              (trc nil "(setf md-slot-value) >no news" prior-state (c-no-news c absorbed-value prior-value))
              (count-it :nonews))
          (progn
            (setf (c-changed c) t)
            (c-propagate c prior-value (eq prior-state :valid))))  ;; until 06-02-13 was (not (eq prior-state :unbound))
        
        absorbed-value)))


    
