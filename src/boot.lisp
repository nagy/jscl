;;; -*- mode:lisp; coding:utf-8 -*-

;;; boot.lisp --- First forms to be cross compiled

;; Copyright (C) 2012, 2013 David Vazquez
;; Copyright (C) 2012 Raimon Grau

;; JSCL is free software: you can redistribute it and/or
;; modify it under the terms of the GNU General Public License as
;; published by the Free Software Foundation, either version 3 of the
;; License, or (at your option) any later version.
;;
;; JSCL is distributed in the hope that it will be useful, but
;; WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
;; General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with JSCL.  If not, see <http://www.gnu.org/licenses/>.

;;; This code is executed when JSCL compiles this file itself. The
;;; compiler provides compilation of some special forms, as well as
;;; funcalls and macroexpansion, but no functions. So, we define the
;;; Lisp world from scratch. This code has to define enough language
;;; to the compiler to be able to run.

(/debug "loading boot.lisp!")

(eval-when (:compile-toplevel)
  (let ((defmacro-macroexpander
         '#'(lambda (form)
              (destructuring-bind (name args &body body)
                  form
                (multiple-value-bind (body decls docstring)
                    (parse-body body :declarations t :docstring t)
                  (let* ((whole (gensym))
                         (expander `(function
                                     (lambda (,whole)
                                      ,docstring
                                      (block ,name
                                        (destructuring-bind ,args ,whole
                                          ,@decls
                                          ,@body))))))

                    ;; If we are bootstrapping JSCL, we need to quote the
                    ;; macroexpander, because the macroexpander will
                    ;; need to be dumped in the final environment
                    ;; somehow.
                    (when (find :jscl-xc *features*)
                      (setq expander `(quote ,expander)))

                    `(eval-when (:compile-toplevel :execute)
                       (%compile-defmacro ',name ,expander))

                    ))))))
    
    (%compile-defmacro 'defmacro defmacro-macroexpander)))

(defmacro declaim (&rest decls)
  `(eval-when (:compile-toplevel :execute)
     ,@(mapcar (lambda (decl) `(!proclaim ',decl)) decls)))

(defmacro defconstant (name value &optional docstring)
  `(progn
     (declaim (special ,name))
     (declaim (constant ,name))
     (setq ,name ,value)
     ,@(when (stringp docstring) `((oset ,docstring ',name "vardoc")))
     ',name))

(defconstant t 't)
(defconstant nil 'nil)
(%js-vset "nil" nil)
(%js-vset "t" t)

(defmacro lambda (args &body body)
  `(function (lambda ,args ,@body)))

(defmacro when (condition &body body)
  `(if ,condition (progn ,@body) nil))

(defmacro unless (condition &body body)
  `(if ,condition nil (progn ,@body)))

(defmacro defvar (name &optional (value nil value-p) docstring)
  `(progn
     (declaim (special ,name))
     ,@(when value-p `((unless (boundp ',name) (setq ,name ,value))))
     ,@(when (stringp docstring) `((oset ,docstring ',name "vardoc")))
     ',name))

(defmacro defparameter (name value &optional docstring)
  `(progn
     (declaim (special ,name))
     (setq ,name ,value)
     ,@(when (stringp docstring) `((oset ,docstring ',name "vardoc")))
     ',name))

;;; Basic DEFUN for regular function names (not SETF)
(defmacro %defun (name args &rest body)
  `(progn
     (eval-when (:compile-toplevel)
       (fn-info ',name :defined t))
     (fset ',name #'(named-lambda ,name ,args ,@body))
     ',name))

(eval-when (:compile-toplevel :load-toplevel :execute)
  (defmacro %defun-setf-symbol (name)
    `(intern
      (concat "(" (symbol-name (car ,name)) "_" (symbol-name (cadr ,name)) ")")
      (symbol-package (cadr ,name)))))

(defmacro defun (name args &rest body)
  (cond ((symbolp name)
         `(%defun ,name ,args ,@body))
        ((and (consp name) (eq (car name) 'setf))
         ;; HACK: This stores SETF functions within regular symbols,
         ;; built from using (SETF name) as a string. This of course
         ;; is incorrect, and (SETF name) functions should be stored
         ;; in a different place.
         ;;
         ;; Also, the SETF expansion could be defined on demand in
         ;; get-setf-expansion by consulting this register of SETF
         ;; definitions.
         (let ((sfn (%defun-setf-symbol name)))
           `(progn
              (%defun ,sfn ,args ,@body)
              (define-setf-expander ,(cadr name) (&rest arguments)
                (let ((g!args (mapcar (lambda (it)
                                        (declare (ignore it))
                                        (gensym))
                                      arguments))
                      (g!newvalue (gensym))
                      (g!setter ',sfn)
                      (g!getter ',(cadr name)))
                  (values 
                   (list g!args)
                   arguments
                   (list g!newvalue)
                   `(,g!setter ,g!newvalue ,@arguments)
                   `(,g!getter ,@arguments)))))))
        (t (error "defun ~a unknown function specifier" name))))

(defmacro return (&optional value)
  `(return-from nil ,value))

(defmacro while (condition &body body)
  `(block nil (%while ,condition ,@body)))

(defvar *gensym-counter* 0)
(defun gensym (&optional (prefix "G"))
  (setq *gensym-counter* (+ *gensym-counter* 1))
  (make-symbol (concat prefix (integer-to-string *gensym-counter*))))

(defun boundp (x)
  (boundp x))

(defun fboundp (x)
  (if (functionp x)
      (error "FBOUNDP - invalid function name ~a." x))
  (%fboundp x))

(defun eq (x y) (eq x y))
(defun eql (x y) (eq x y))

(defun not (x) (if x nil t))

(defun funcall (function &rest args)
  (apply function args))

(defun apply (function arg &rest args)
  (apply function (apply #'list* arg args)))

(defun symbol-name (x)
  (symbol-name x))

;; Basic macros

(defmacro dolist ((var list &optional result) &body body)
  (let ((g!list (gensym)))
    (unless (symbolp var) (error "`~S' is not a symbol." var))
    `(block nil
       (let ((,g!list ,list)
             (,var nil))
         (%while ,g!list
                 (setq ,var (car ,g!list))
                 (tagbody ,@body)
                 (setq ,g!list (cdr ,g!list)))
         ,result))))

(defmacro dotimes ((var count &optional result) &body body)
  (let ((g!count (gensym)))
    (unless (symbolp var) (error "`~S' is not a symbol." var))
    `(block nil
       (let ((,var 0)
             (,g!count ,count))
         (%while (< ,var ,g!count)
                 (tagbody ,@body)
                 (incf ,var))
         ,result))))

(defmacro cond (&rest clausules)
  (unless (null clausules)
    (destructuring-bind (condition &body body)
        (first clausules)
      (cond
        ((eq condition t)
         `(progn ,@body))
        ((null body)
         (let ((test-symbol (gensym)))
           `(let ((,test-symbol ,condition))
              (if ,test-symbol
                  ,test-symbol
                  (cond ,@(rest clausules))))))
        (t
         `(if ,condition
              (progn ,@body)
              (cond ,@(rest clausules))))))))

(defmacro case (form &rest clausules)
  (let ((!form (gensym)))
    `(let ((,!form ,form))
       (cond
         ,@(mapcar (lambda (clausule)
                     (destructuring-bind (keys &body body)
                         clausule
                       (if (or (eq keys 't) (eq keys 'otherwise))
                           `(t nil ,@body)
                           (let ((keys (if (listp keys) keys (list keys))))
                             `((or ,@(mapcar (lambda (key) `(eql ,!form ',key)) keys))
                               nil ,@body)))))
                   clausules)))))

(defmacro ecase (form &rest clausules)
  (let ((g!form (gensym)))
    `(let ((,g!form ,form))
       (case ,g!form
         ,@(append
            clausules
            `((t
               (error "ECASE expression failed for the object `~S'." ,g!form))))))))

(defmacro and (&rest forms)
  (cond
    ((null forms)
     t)
    ((null (cdr forms))
     (car forms))
    (t
     `(if ,(car forms)
          (and ,@(cdr forms))
          nil))))

(defmacro or (&rest forms)
  (cond
    ((null forms)
     nil)
    ((null (cdr forms))
     (car forms))
    (t
     (let ((g (gensym)))
       `(let ((,g ,(car forms)))
          (if ,g ,g (or ,@(cdr forms))))))))

(defmacro prog1 (form &body body)
  (let ((value (gensym)))
    `(let ((,value ,form))
       ,@body
       ,value)))

(defmacro prog2 (form1 result &body body)
  `(prog1 (progn ,form1 ,result) ,@body))

(defmacro prog (inits &rest body )
  (multiple-value-bind (forms decls docstring) (parse-body body)
    `(block nil
       (let ,inits
         ,@decls
         (tagbody ,@forms)))))

(defmacro psetq (&rest pairs)
  (let (;; For each pair, we store here a list of the form
        ;; (VARIABLE GENSYM VALUE).
        (assignments '()))
    (while t
      (cond
        ((null pairs) (return))
        ((null (cdr pairs))
         (error "Odd pairs in PSETQ"))
        (t
         (let ((variable (car pairs))
               (value (cadr pairs)))
           (push `(,variable ,(gensym) ,value)  assignments)
           (setq pairs (cddr pairs))))))
    (setq assignments (reverse assignments))
    ;;
    `(let ,(mapcar #'cdr assignments)
       (setq ,@(!reduce #'append (mapcar #'butlast assignments) nil)))))

(defmacro do (varlist endlist &body body)
  `(block nil
     (let ,(mapcar (lambda (x) (if (symbolp x)
                                   (list x nil)
                                 (list (first x) (second x)))) varlist)
       (while t
         (when ,(car endlist)
           (return (progn ,@(cdr endlist))))
         (tagbody ,@body)
         (psetq
          ,@(apply #'append
                   (mapcar (lambda (v)
                             (and (listp v)
                                  (consp (cddr v))
                                  (list (first v) (third v))))
                           varlist)))))))

(defmacro do* (varlist endlist &body body)
  `(block nil
     (let* ,(mapcar (lambda (x1) (if (symbolp x1)
                                     (list x1 nil)
                                   (list (first x1) (second x1)))) varlist)
       (while t
         (when ,(car endlist)
           (return (progn ,@(cdr endlist))))
         (tagbody ,@body)
         (setq
          ,@(apply #'append
                   (mapcar (lambda (v)
                             (and (listp v)
                                  (consp (cddr v))
                                  (list (first v) (third v))))
                           varlist)))))))

(defun identity (x) x)

(defun complement (x)
  (lambda (&rest args)
    (not (apply x args))))

(defun constantly (x)
  (lambda (&rest args)
    x))

(defun code-char (x)
  (code-char x))

(defun char-code (x)
  (char-code x))

(defun char= (x y)
  (eql x y))

(defun char< (x y)
  (< (char-code x) (char-code y)))

(defun atom (x)
  (not (consp x)))

(defun alpha-char-p (x)
  (or (<= (char-code #\a) (char-code x) (char-code #\z))
      (<= (char-code #\A) (char-code x) (char-code #\Z))))

(defun digit-char-p (x)
  (and (<= (char-code #\0) (char-code x) (char-code #\9))
       (- (char-code x) (char-code #\0))))

(defun digit-char (weight)
  (and (<= 0 weight 9)
       (char "0123456789" weight)))

(defun equal (x y)
  (cond
    ((eql x y) t)
    ((consp x)
     (and (consp y)
          (equal (car x) (car y))
          (equal (cdr x) (cdr y))))
    ((stringp x)
     (and (stringp y) (string= x y)))
    (t nil)))

(defun fdefinition (x)
  (cond
    ((functionp x)
     x)
    ((symbolp x)
     (symbol-function x))
    ((and (consp x) (eq (car x) 'setf))
      (symbol-function (%defun-setf-symbol x)))
    (t
      (error 'type-error :datum x :expected-type '(or functionp symbolp)))))

(defun disassemble (function)
  (write-line (lambda-code (fdefinition function)))
  nil)

(defmacro multiple-value-bind (variables value-from &body body)
  `(multiple-value-call (lambda (&optional ,@variables &rest ,(gensym))
                          ,@body)
     ,value-from))

(defmacro multiple-value-list (value-from)
  `(multiple-value-call #'list ,value-from))


(defmacro multiple-value-setq ((&rest vars) &rest form)
  (let ((gvars (mapcar (lambda (x) (gensym)) vars))
        (setqs '()))

    (do ((vars vars (cdr vars))
         (gvars gvars (cdr gvars)))
        ((or (null vars) (null gvars)))
      (push `(setq ,(car vars) ,(car gvars))
            setqs))
    (setq setqs (reverse setqs))

    `(multiple-value-call (lambda ,gvars ,@setqs)
       ,@form)))

(defun notany (fn seq)
  (not (some fn seq)))

(defconstant internal-time-units-per-second 1000)

(defun values-list (list)
  (values-array (list-to-vector list)))

(defun values (&rest args)
  (values-list args))

(defmacro nth-value (n form)
  `(multiple-value-call (lambda (&rest values)
                          (nth ,n values))
     ,form))

(defun constantp (x)
  ;; TODO: Consider quoted forms, &environment and many other
  ;; semantics of this function.
  (cond
    ((symbolp x)
     (cond
       ((eq x t) t)
       ((eq x nil) t)))
    ((atom x)
     t)
    (t
     nil)))

(defparameter *features* '(:jscl :common-lisp))

;;; symbol-function from compiler macro
(defun functionp (f) (functionp f))

;;; types family section

;;; tag's utils
(defun object-type-code (object) (oget object "dt_Name"))
(defun set-object-type-code (object tag) (oset tag object "dt_Name"))

;;; types predicate's
(defun mop-object-p (obj)
    (and (consp obj)
         (eql (object-type-code obj) :mop-object)
         (= (length obj) 5)))

(defun clos-object-p (object) (eql (object-type-code object) :clos_object))

;;; macro's
(defun %check-type-error (place value typespec string)
   (error "Check type error.~%The value of ~s is ~s, is not ~a ~a."
          place value typespec (if (null string) "" string)))

(defmacro %check-type (place typespec &optional (string ""))
  (let ((value (gensym)))
    (if (symbolp place)
        `(do ((,value ,place ,place))
             ((!typep ,value ',typespec))
           (setf ,place (%check-type-error ',place ,value ',typespec ,string)))
        (if (!typep place typespec)
            t
            (%check-type-error place place typespec string)))))

#+jscl
(defmacro check-type (place typespec &optional (string ""))
  `(%check-type ,place ,typespec ,string))

(eval-when (:compile-toplevel :load-toplevel :execute)
  (defmacro %push-end (thing place) `(setq ,place (append ,place (list ,thing))))

  (defparameter *basic-type-predicates*
    '((hash-table . hash-table-p) (package . packagep) (stream . streamp)
      (atom . atom) (structure . structure-p) (js-object . js-object-p)
      ;; todo: subtypep - remove mop-object from tables
      (clos-object . mop-object-p) (mop-object . mop-object-p) (character . characterp)
      (symbol . symbolp)  (keyword . keywordp)
      (function . functionp) 
      (number . numberp) (real . realp) (rational . rationalp) (float . floatp)
      (integer . integerp)
      (sequence .  sequencep) (list . listp) (cons . consp) (array . arrayp)
      (vector . vectorp) (string . stringp) (null . null)))

  (defun simple-base-predicate-p (expr)
    (if (symbolp expr)
        (let ((pair (assoc expr *basic-type-predicates*)))
          (if pair (cdr pair) nil))))

  (defun typecase-expander (object clausules)
    (let ((key)
          (body)
          (std-p)
          (g!x (gensym "TYPECASE"))
          (result '()))
      (dolist (it clausules (reverse result))
        (setq key (car it)
              body (cdr it)
              std-p (simple-base-predicate-p key))
        ;; (typecase keyform (type-spec form*))
        ;; when: type-spec is symbol in *basic-type-predicates*, its predicate
        ;;       -> (cond ((predicate keyform) form*))
        ;; otherwise: (cond ((typep keyform (type-spec form*))))
        (cond (std-p (%push-end `((,std-p ,g!x) ,@body) result))
              ((or (eq key 't) (eq key 'otherwise))
               (%push-end `(t ,@body) result))
              (t (%push-end `((!typep ,g!x ',key) ,@body) result))))
      `(let ((,g!x ,object))
         (cond ,@result))))
  )

(defmacro typecase (form &rest clausules)
  (typecase-expander `,form `,clausules))

(defmacro etypecase (x &rest clausules)
  `(typecase ,x
     ,@clausules
     (t (error "~S fell through etypecase expression." ,x))))


;;; it remains so. not all at once. with these - live...
(defun subtypep (type1 type2)
  (cond
    ((null type1)
     (values t t))
    ((eq type1 type2)
     (values t t))
    ((eq type2 'number)
     (values (and (member type1 '(fixnum integer)) t)
             t))
    (t
     (values nil nil))))

;;; Early error definition.
(defun %coerce-panic-arg (arg)
  (cond ((symbolp arg) (concat "symbol: " (symbol-name arg)))
        ((consp arg ) (concat "cons: " (car arg)))
        ((numberp arg) (concat "number:" arg))
        (t " @ ")))

(defun error (fmt &rest args)
  (if (fboundp 'format)
      (%throw (apply #'format nil fmt args))
    (%throw (lisp-to-js (concat "BOOT PANIC! "
                                (string fmt)
                                " "
                                (%coerce-panic-arg (car args)))))))

;;; print-unreadable-object
(defmacro !print-unreadable-object ((object stream &key type identity) &body body)
  (let ((g!stream (gensym))
        (g!object (gensym)))
    `(let ((,g!stream ,stream)
           (,g!object ,object))
       (simple-format ,g!stream "#<")
       ,(when type
          `(simple-format ,g!stream "~S" (type-of g!object)))
       ,(when (and type (or body identity))
          `(simple-format ,g!stream " "))
       ,@body
       ,(when (and identity body)
          `(simple-format ,g!stream " "))
       (simple-format ,g!stream ">")
       nil)))


#+jscl
(defmacro print-unreadable-object ((object stream &key type identity) &body body) 
    `(!print-unreadable-object (,object ,stream :type ,type :identity ,identity) ,@body))

;;; EOF
