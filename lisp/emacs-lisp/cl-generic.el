;;; cl-generic.el --- CLOS-style generic functions for Elisp  -*- lexical-binding: t; -*-

;; Copyright (C) 2015 Free Software Foundation, Inc.

;; Author: Stefan Monnier <monnier@iro.umontreal.ca>
;; Version: 1.0

;; This file is part of GNU Emacs.

;; GNU Emacs is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; GNU Emacs is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; This implements the most of CLOS's multiple-dispatch generic functions.
;; To use it you need either (require 'cl-generic) or (require 'cl-lib).
;; The main entry points are: `cl-defgeneric' and `cl-defmethod'.

;; Missing elements:
;; - We don't support make-method, call-method, define-method-combination.
;;   CLOS's define-method-combination is IMO overly complicated, and it suffers
;;   from a significant problem: the method-combination code returns a sexp
;;   that needs to be `eval'uated or compiled.  IOW it requires run-time
;;   code generation.  Given how rarely method-combinations are used,
;;   I just provided a cl-generic-combine-methods generic function, to which
;;   people can add methods if they are really desperate for such functionality.
;; - In defgeneric we don't support the options:
;;   declare, :method-combination, :generic-function-class, :method-class.
;; Added elements:
;; - We support aliases to generic functions.
;; - cl-generic-generalizers.  This generic function lets you extend the kind
;;   of thing on which to dispatch.  There is support in this file for
;;   dispatch on:
;;   - (eql <val>)
;;   - (head <val>) which checks that the arg is a cons with <val> as its head.
;;   - plain old types
;;   - type of CL structs
;;   eieio-core adds dispatch on:
;;   - class of eieio objects
;;   - actual class argument, using the syntax (subclass <class>).
;; - cl-generic-combine-methods (i.s.o define-method-combination and
;;   compute-effective-method).
;; - cl-generic-call-method (which replaces make-method and call-method).
;; - The standard method combination supports ":extra STRING" qualifiers
;;   which simply allows adding more methods for the same
;;   specializers&qualifiers.
;; - Methods can dispatch on the context.  For that, a method needs to specify
;;   context arguments, introduced by `&context' (which need to come right
;;   after the mandatory arguments and before anything like
;;   &optional/&rest/&key).  Each context argument is given as (EXP SPECIALIZER)
;;   which means that EXP is taken as an expression which computes some context
;;   and this value is then used to dispatch.
;;   E.g. (foo &context (major-mode (eql c-mode))) is an arglist specifying
;;   that this method will only be applicable when `major-mode' has value
;;   `c-mode'.

;; Efficiency considerations: overall, I've made an effort to make this fairly
;; efficient for the expected case (e.g. no constant redefinition of methods).
;; - Generic functions which do not dispatch on any argument are implemented
;;   optimally (just as efficient as plain old functions).
;; - Generic functions which only dispatch on one argument are fairly efficient
;;   (not a lot of room for improvement without changes to the byte-compiler,
;;   I think).
;; - Multiple dispatch is implemented rather naively.  There's an extra `apply'
;;   function call for every dispatch; we don't optimize each dispatch
;;   based on the set of candidate methods remaining; we don't optimize the
;;   order in which we performs the dispatches either;
;;   If/when this becomes a problem, we can try and optimize it.
;; - call-next-method could be made more efficient, but isn't too terrible.

;; TODO:
;;
;; - A generic "filter" generalizer (e.g. could be used to cleanly adds methods
;;   to cl-generic-combine-methods with a specializer that says it applies only
;;   when some particular qualifier is used).
;; - A way to dispatch on the context (e.g. the major-mode, some global
;;   variable, you name it).

;;; Code:

;; Note: For generic functions that dispatch on several arguments (i.e. those
;; which use the multiple-dispatch feature), we always use the same "tagcodes"
;; and the same set of arguments on which to dispatch.  This works, but is
;; often suboptimal since after one dispatch, the remaining dispatches can
;; usually be simplified, or even completely skipped.

(eval-when-compile (require 'cl-lib))
(eval-when-compile (require 'pcase))

(cl-defstruct (cl--generic-generalizer
               (:constructor nil)
               (:constructor cl-generic-make-generalizer
                (priority tagcode-function specializers-function)))
  (priority nil :type integer)
  tagcode-function
  specializers-function)

(defconst cl--generic-t-generalizer
  (cl-generic-make-generalizer
   0 (lambda (_name) nil) (lambda (_tag) '(t))))

(cl-defstruct (cl--generic-method
               (:constructor nil)
               (:constructor cl--generic-make-method
                (specializers qualifiers uses-cnm function))
               (:predicate nil))
  (specializers nil :read-only t :type list)
  (qualifiers   nil :read-only t :type (list-of atom))
  ;; USES-CNM is a boolean indicating if FUNCTION expects an extra argument
  ;; holding the next-method.
  (uses-cnm     nil :read-only t :type boolean)
  (function     nil :read-only t :type function))

(cl-defstruct (cl--generic
               (:constructor nil)
               (:constructor cl--generic-make (name))
               (:predicate nil))
  (name nil :type symbol :read-only t)  ;Pointer back to the symbol.
  ;; `dispatches' holds a list of (ARGNUM . TAGCODES) where ARGNUM is the index
  ;; of the corresponding argument and TAGCODES is a list of (PRIORITY . EXP)
  ;; where the EXPs are expressions (to be `or'd together) to compute the tag
  ;; on which to dispatch and PRIORITY is the priority of each expression to
  ;; decide in which order to sort them.
  ;; The most important dispatch is last in the list (and the least is first).
  (dispatches nil :type (list-of (cons natnum (list-of generalizers))))
  (method-table nil :type (list-of cl--generic-method))
  (options nil :type list))

(defun cl-generic-function-options (generic)
  "Return the options of the generic function GENERIC."
  (cl--generic-options generic))

(defmacro cl--generic (name)
  `(get ,name 'cl--generic))

(defun cl-generic-ensure-function (name)
  (let (generic
        (origname name))
    (while (and (null (setq generic (cl--generic name)))
                (fboundp name)
                (symbolp (symbol-function name)))
      (setq name (symbol-function name)))
    (unless (or (not (fboundp name))
                (autoloadp (symbol-function name))
                (and (functionp name) generic))
      (error "%s is already defined as something else than a generic function"
             origname))
    (if generic
        (cl-assert (eq name (cl--generic-name generic)))
      (setf (cl--generic name) (setq generic (cl--generic-make name)))
      (defalias name (cl--generic-make-function generic)))
    generic))

(defun cl--generic-setf-rewrite (name)
  (let* ((setter (intern (format "cl-generic-setter--%s" name)))
         (exp `(unless (eq ',setter (get ',name 'cl-generic-setter))
                 ;; (when (get ',name 'gv-expander)
                 ;;   (error "gv-expander conflicts with (setf %S)" ',name))
                 (setf (get ',name 'cl-generic-setter) ',setter)
                 (gv-define-setter ,name (val &rest args)
                   (cons ',setter (cons val args))))))
    ;; Make sure `setf' can be used right away, e.g. in the body of the method.
    (eval exp t)
    (cons setter exp)))

;;;###autoload
(defmacro cl-defgeneric (name args &rest options-and-methods)
  "Create a generic function NAME.
DOC-STRING is the base documentation for this class.  A generic
function has no body, as its purpose is to decide which method body
is appropriate to use.  Specific methods are defined with `cl-defmethod'.
With this implementation the ARGS are currently ignored.
OPTIONS-AND-METHODS currently understands:
- (:documentation DOCSTRING)
- (declare DECLARATIONS)
- (:argument-precedence-order &rest ARGS)
- (:method [QUALIFIERS...] ARGS &rest BODY)
BODY, if present, is used as the body of a default method.

\(fn NAME ARGS [DOC-STRING] [OPTIONS-AND-METHODS...] &rest BODY)"
  (declare (indent 2) (doc-string 3))
  (let* ((doc (if (stringp (car-safe options-and-methods))
                  (pop options-and-methods)))
         (declarations nil)
         (methods ())
         (options ())
         next-head)
    (while (progn (setq next-head (car-safe (car options-and-methods)))
                  (or (keywordp next-head)
                      (eq next-head 'declare)))
      (pcase next-head
        (`:documentation
         (when doc (error "Multiple doc strings for %S" name))
         (setq doc (cadr (pop options-and-methods))))
        (`declare
         (when declarations (error "Multiple `declare' for %S" name))
         (setq declarations (pop options-and-methods)))
        (`:method (push (cdr (pop options-and-methods)) methods))
        (_ (push (pop options-and-methods) options))))
    (when options-and-methods
      ;; Anything remaining is assumed to be a default method body.
      (push `(,args ,@options-and-methods) methods))
    `(progn
       ,(when (eq 'setf (car-safe name))
          (pcase-let ((`(,setter . ,code) (cl--generic-setf-rewrite
                                           (cadr name))))
            (setq name setter)
            code))
       ,@(mapcar (lambda (declaration)
                   (let ((f (cdr (assq (car declaration)
                                       defun-declarations-alist))))
                     (cond
                      (f (apply (car f) name args (cdr declaration)))
                      (t (message "Warning: Unknown defun property `%S' in %S"
                                  (car declaration) name)
                         nil))))
                 (cdr declarations))
       (defalias ',name
         (cl-generic-define ',name ',args ',(nreverse options))
         ,(help-add-fundoc-usage doc args))
       ,@(mapcar (lambda (method) `(cl-defmethod ,name ,@method))
                 (nreverse methods)))))

;;;###autoload
(defun cl-generic-define (name args options)
  (pcase-let* ((generic (cl-generic-ensure-function name))
               (`(,spec-args . ,_) (cl--generic-split-args args))
               (mandatory (mapcar #'car spec-args))
               (apo (assq :argument-precedence-order options)))
    (unless (fboundp name)
      ;; If the generic function was fmakunbound, throw away previous methods.
      (setf (cl--generic-dispatches generic) nil)
      (setf (cl--generic-method-table generic) nil))
    (when apo
      (dolist (arg (cdr apo))
        (let ((pos (memq arg mandatory)))
          (unless pos (error "%S is not a mandatory argument" arg))
          (let* ((argno (- (length mandatory) (length pos)))
                 (dispatches (cl--generic-dispatches generic))
                 (dispatch (or (assq argno dispatches) (list argno))))
            (setf (cl--generic-dispatches generic)
                  (cons dispatch (delq dispatch dispatches)))))))
    (setf (cl--generic-options generic) options)
    (cl--generic-make-function generic)))

(defmacro cl-generic-current-method-specializers ()
  "List of (VAR . TYPE) where TYPE is var's specializer.
This macro can only be used within the lexical scope of a cl-generic method."
  (error "cl-generic-current-method-specializers used outside of a method"))

(eval-and-compile         ;Needed while compiling the cl-defmethod calls below!
  (defun cl--generic-fgrep (vars sexp)    ;Copied from pcase.el.
    "Check which of the symbols VARS appear in SEXP."
    (let ((res '()))
      (while (consp sexp)
        (dolist (var (cl--generic-fgrep vars (pop sexp)))
          (unless (memq var res) (push var res))))
      (and (memq sexp vars) (not (memq sexp res)) (push sexp res))
      res))

  (defun cl--generic-split-args (args)
    "Return (SPEC-ARGS . PLAIN-ARGS)."
    (let ((plain-args ())
          (specializers nil)
          (mandatory t))
      (dolist (arg args)
        (push (pcase arg
                ((or '&optional '&rest '&key) (setq mandatory nil) arg)
                ('&context
                 (unless mandatory
                   (error "&context not immediately after mandatory args"))
                 (setq mandatory 'context) nil)
                ((let 'nil mandatory) arg)
                ((let 'context mandatory)
                 (unless (consp arg)
                   (error "Invalid &context arg: %S" arg))
                 (push `((&context . ,(car arg)) . ,(cadr arg)) specializers)
                 nil)
                (`(,name . ,type)
                 (push (cons name (car type)) specializers)
                 name)
                (_
                 (push (cons arg t) specializers)
                 arg))
              plain-args))
      (cons (nreverse specializers)
            (nreverse (delq nil plain-args)))))

  (defun cl--generic-lambda (args body)
    "Make the lambda expression for a method with ARGS and BODY."
    (pcase-let* ((`(,spec-args . ,plain-args)
                  (cl--generic-split-args args))
                 (fun `(cl-function (lambda ,plain-args ,@body)))
                 (macroenv (cons `(cl-generic-current-method-specializers
                                   . ,(lambda () spec-args))
                                 macroexpand-all-environment)))
      (require 'cl-lib)        ;Needed to expand `cl-flet' and `cl-function'.
      ;; First macroexpand away the cl-function stuff (e.g. &key and
      ;; destructuring args, `declare' and whatnot).
      (pcase (macroexpand fun macroenv)
        (`#'(lambda ,args . ,body)
         (let* ((parsed-body (macroexp-parse-body body))
                (cnm (make-symbol "cl--cnm"))
                (nmp (make-symbol "cl--nmp"))
                (nbody (macroexpand-all
                        `(cl-flet ((cl-call-next-method ,cnm)
                                   (cl-next-method-p ,nmp))
                           ,@(cdr parsed-body))
                        macroenv))
                ;; FIXME: Rather than `grep' after the fact, the
                ;; macroexpansion should directly set some flag when cnm
                ;; is used.
                ;; FIXME: Also, optimize the case where call-next-method is
                ;; only called with explicit arguments.
                (uses-cnm (cl--generic-fgrep (list cnm nmp) nbody)))
           (cons (not (not uses-cnm))
                 `#'(lambda (,@(if uses-cnm (list cnm)) ,@args)
                      ,@(car parsed-body)
                      ,(if (not (memq nmp uses-cnm))
                           nbody
                         `(let ((,nmp (lambda ()
                                        (cl--generic-isnot-nnm-p ,cnm))))
                            ,nbody))))))
        (f (error "Unexpected macroexpansion result: %S" f))))))


;;;###autoload
(defmacro cl-defmethod (name args &rest body)
  "Define a new method for generic function NAME.
I.e. it defines the implementation of NAME to use for invocations where the
value of the dispatch argument matches the specified TYPE.
The dispatch argument has to be one of the mandatory arguments, and
all methods of NAME have to use the same argument for dispatch.
The dispatch argument and TYPE are specified in ARGS where the corresponding
formal argument appears as (VAR TYPE) rather than just VAR.

The optional second argument QUALIFIER is a specifier that
modifies how the method is combined with other methods, including:
   :before  - Method will be called before the primary
   :after   - Method will be called after the primary
   :around  - Method will be called around everything else
The absence of QUALIFIER means this is a \"primary\" method.

Other than a type, TYPE can also be of the form `(eql VAL)' in
which case this method will be invoked when the argument is `eql' to VAL.

\(fn NAME [QUALIFIER] ARGS &rest [DOCSTRING] BODY)"
  (declare (doc-string 3) (indent 2)
           (debug
            (&define                    ; this means we are defining something
             [&or name ("setf" :name setf name)]
             ;; ^^ This is the methods symbol
             [ &optional keywordp ]     ; this is key :before etc
             list                       ; arguments
             [ &optional stringp ]      ; documentation string
             def-body)))                ; part to be debugged
  (let ((qualifiers nil)
        (setfizer (if (eq 'setf (car-safe name))
                      ;; Call it before we call cl--generic-lambda.
                      (cl--generic-setf-rewrite (cadr name)))))
    (while (not (listp args))
      (push args qualifiers)
      (setq args (pop body)))
    (pcase-let* ((`(,uses-cnm . ,fun) (cl--generic-lambda args body)))
      `(progn
         ,(when setfizer
            (setq name (car setfizer))
            (cdr setfizer))
         ,(and (get name 'byte-obsolete-info)
               (or (not (fboundp 'byte-compile-warning-enabled-p))
                   (byte-compile-warning-enabled-p 'obsolete))
               (let* ((obsolete (get name 'byte-obsolete-info)))
                 (macroexp--warn-and-return
                  (macroexp--obsolete-warning name obsolete "generic function")
                  nil)))
         ;; You could argue that `defmethod' modifies rather than defines the
         ;; function, so warnings like "not known to be defined" are fair game.
         ;; But in practice, it's common to use `cl-defmethod'
         ;; without a previous `cl-defgeneric'.
         (declare-function ,name "")
         (cl-generic-define-method ',name ',(nreverse qualifiers) ',args
                                   ,uses-cnm ,fun)))))

(defun cl--generic-member-method (specializers qualifiers methods)
  (while
      (and methods
           (let ((m (car methods)))
             (not (and (equal (cl--generic-method-specializers m) specializers)
                       (equal (cl--generic-method-qualifiers m) qualifiers)))))
    (setq methods (cdr methods)))
  methods)

;;;###autoload
(defun cl-generic-define-method (name qualifiers args uses-cnm function)
  (pcase-let*
      ((generic (cl-generic-ensure-function name))
       (`(,spec-args . ,_) (cl--generic-split-args args))
       (specializers (mapcar (lambda (spec-arg)
                               (if (eq '&context (car-safe (car spec-arg)))
                                   spec-arg (cdr spec-arg)))
                             spec-args))
       (method (cl--generic-make-method
                specializers qualifiers uses-cnm function))
       (mt (cl--generic-method-table generic))
       (me (cl--generic-member-method specializers qualifiers mt))
       (dispatches (cl--generic-dispatches generic))
       (i 0))
    (dolist (spec-arg spec-args)
      (let* ((key (if (eq '&context (car-safe (car spec-arg)))
                      (car spec-arg) i))
             (generalizers (cl-generic-generalizers (cdr spec-arg)))
             (x (assoc key dispatches)))
        (unless x
          (setq x (cons key (cl-generic-generalizers t)))
          (setf (cl--generic-dispatches generic)
                (setq dispatches (cons x dispatches))))
        (dolist (generalizer generalizers)
          (unless (member generalizer (cdr x))
            (setf (cdr x)
                  (sort (cons generalizer (cdr x))
                        (lambda (x y)
                          (> (cl--generic-generalizer-priority x)
                             (cl--generic-generalizer-priority y)))))))
        (setq i (1+ i))))
    ;; We used to (setcar me method), but that can cause false positives in
    ;; the hash-consing table of the method-builder (bug#20644).
    ;; See the related FIXME in cl--generic-build-combined-method.
    (setf (cl--generic-method-table generic) (cons method (delq (car me) mt)))
    (cl-pushnew `(cl-defmethod . (,(cl--generic-name generic) . ,specializers))
                current-load-list :test #'equal)
    ;; FIXME: Try to avoid re-constructing a new function if the old one
    ;; is still valid (e.g. still empty method cache)?
    (let ((gfun (cl--generic-make-function generic))
          ;; Prevent `defalias' from recording this as the definition site of
          ;; the generic function.
          current-load-list)
      ;; For aliases, cl--generic-name gives us the actual name.
      (let ((purify-flag
             ;; BEWARE!  Don't purify this function definition, since that leads
             ;; to memory corruption if the hash-tables it holds are modified
             ;; (the GC doesn't trace those pointers).
             nil))
        ;; But do use `defalias', so that it interacts properly with nadvice,
        ;; e.g. for tracing/debug-on-entry.
        (defalias (cl--generic-name generic) gfun)))))

(defmacro cl--generic-with-memoization (place &rest code)
  (declare (indent 1) (debug t))
  (gv-letplace (getter setter) place
    `(or ,getter
         ,(macroexp-let2 nil val (macroexp-progn code)
            `(progn
               ,(funcall setter val)
               ,val)))))

(defvar cl--generic-dispatchers (make-hash-table :test #'equal))

(defun cl--generic-get-dispatcher (dispatch)
  (cl--generic-with-memoization
      (gethash dispatch cl--generic-dispatchers)
    ;; (message "cl--generic-get-dispatcher (%S)" dispatch)
    (let* ((dispatch-arg (car dispatch))
           (generalizers (cdr dispatch))
           (lexical-binding t)
           (tagcodes
            (mapcar (lambda (generalizer)
                      (funcall (cl--generic-generalizer-tagcode-function
                                generalizer)
                               'arg))
                    generalizers))
           (typescodes
            (mapcar
             (lambda (generalizer)
               `(funcall ',(cl--generic-generalizer-specializers-function
                            generalizer)
                         ,(funcall (cl--generic-generalizer-tagcode-function
                                    generalizer)
                                   'arg)))
             generalizers))
           (tag-exp
            ;; Minor optimization: since this tag-exp is
            ;; only used to lookup the method-cache, it
            ;; doesn't matter if the default value is some
            ;; constant or nil.
            `(or ,@(if (macroexp-const-p (car (last tagcodes)))
                       (butlast tagcodes)
                     tagcodes)))
           (fixedargs '(arg))
           (dispatch-idx dispatch-arg)
           (bindings nil))
      (when (eq '&context (car-safe dispatch-arg))
        (setq bindings `((arg ,(cdr dispatch-arg))))
        (setq fixedargs nil)
        (setq dispatch-idx 0))
      (dotimes (i dispatch-idx)
        (push (make-symbol (format "arg%d" (- dispatch-idx i 1))) fixedargs))
      ;; FIXME: For generic functions with a single method (or with 2 methods,
      ;; one of which always matches), using a tagcode + hash-table is
      ;; overkill: better just use a `cl-typep' test.
      (byte-compile
       `(lambda (generic dispatches-left methods)
          (let ((method-cache (make-hash-table :test #'eql)))
            (lambda (,@fixedargs &rest args)
              (let ,bindings
                (apply (cl--generic-with-memoization
                        (gethash ,tag-exp method-cache)
                        (cl--generic-cache-miss
                         generic ',dispatch-arg dispatches-left methods
                         ,(if (cdr typescodes)
                              `(append ,@typescodes) (car typescodes))))
                       ,@fixedargs args)))))))))

(defun cl--generic-make-function (generic)
  (cl--generic-make-next-function generic
                                  (cl--generic-dispatches generic)
                                  (cl--generic-method-table generic)))

(defun cl--generic-make-next-function (generic dispatches methods)
  (let* ((dispatch
          (progn
            (while (and dispatches
                        (let ((x (nth 1 (car dispatches))))
                          ;; No need to dispatch for t specializers.
                          (or (null x) (equal x cl--generic-t-generalizer))))
              (setq dispatches (cdr dispatches)))
            (pop dispatches))))
    (if (not (and dispatch
                  ;; If there's no method left, there's no point checking
                  ;; further arguments.
                  methods))
        (cl--generic-build-combined-method generic methods)
      (let ((dispatcher (cl--generic-get-dispatcher dispatch)))
        (funcall dispatcher generic dispatches methods)))))

(defvar cl--generic-combined-method-memoization
  (make-hash-table :test #'equal :weakness 'value)
  "Table storing previously built combined-methods.
This is particularly useful when many different tags select the same set
of methods, since this table then allows us to share a single combined-method
for all those different tags in the method-cache.")

(define-error 'cl--generic-cyclic-definition "Cyclic definition: %S")

(defun cl--generic-build-combined-method (generic methods)
  (if (null methods)
      ;; Special case needed to fix a circularity during bootstrap.
      (cl--generic-standard-method-combination generic methods)
    (let ((f
           (cl--generic-with-memoization
               ;; FIXME: Since the fields of `generic' are modified, this
               ;; hash-table won't work right, because the hashes will change!
               ;; It's not terribly serious, but reduces the effectiveness of
               ;; the table.
               (gethash (cons generic methods)
                        cl--generic-combined-method-memoization)
             (puthash (cons generic methods) :cl--generic--under-construction
                      cl--generic-combined-method-memoization)
             (condition-case nil
                 (cl-generic-combine-methods generic methods)
               ;; Special case needed to fix a circularity during bootstrap.
               (cl--generic-cyclic-definition
                (cl--generic-standard-method-combination generic methods))))))
      (if (eq f :cl--generic--under-construction)
          (signal 'cl--generic-cyclic-definition
                  (list (cl--generic-name generic)))
        f))))

(defun cl--generic-no-next-method-function (generic method)
  (lambda (&rest args)
    (apply #'cl-no-next-method generic method args)))

(defun cl-generic-call-method (generic method &optional fun)
  "Return a function that calls METHOD.
FUN is the function that should be called when METHOD calls
`call-next-method'."
  (if (not (cl--generic-method-uses-cnm method))
      (cl--generic-method-function method)
    (let ((met-fun (cl--generic-method-function method))
          (next (or fun (cl--generic-no-next-method-function
                         generic method))))
      (lambda (&rest args)
        (apply met-fun
               ;; FIXME: This sucks: passing just `next' would
               ;; be a lot more efficient than the lambda+apply
               ;; quasi-η, but we need this to implement the
               ;; "if call-next-method is called with no
               ;; arguments, then use the previous arguments".
               (lambda (&rest cnm-args)
                 (apply next (or cnm-args args)))
               args)))))

;; Standard CLOS name.
(defalias 'cl-method-qualifiers #'cl--generic-method-qualifiers)

(defun cl--generic-standard-method-combination (generic methods)
  (let ((mets-by-qual ()))
    (dolist (method methods)
      (let ((qualifiers (cl-method-qualifiers method)))
        (if (eq (car qualifiers) :extra) (setq qualifiers (cddr qualifiers)))
        (unless (member qualifiers '(() (:after) (:before) (:around)))
          (error "Unsupported qualifiers in function %S: %S"
                 (cl--generic-name generic) qualifiers))
        (push method (alist-get (car qualifiers) mets-by-qual))))
    (cond
     ((null mets-by-qual)
      (lambda (&rest args)
        (apply #'cl-no-applicable-method generic args)))
     ((null (alist-get nil mets-by-qual))
      (lambda (&rest args)
        (apply #'cl-no-primary-method generic args)))
     (t
      (let* ((fun nil)
             (ab-call (lambda (m) (cl-generic-call-method generic m)))
             (before
              (mapcar ab-call (reverse (cdr (assoc :before mets-by-qual)))))
             (after (mapcar ab-call (cdr (assoc :after mets-by-qual)))))
        (dolist (method (cdr (assoc nil mets-by-qual)))
          (setq fun (cl-generic-call-method generic method fun)))
        (when (or after before)
          (let ((next fun))
            (setq fun (lambda (&rest args)
                        (dolist (bf before)
                          (apply bf args))
                        (prog1
                            (apply next args)
                          (dolist (af after)
                            (apply af args)))))))
        (dolist (method (cdr (assoc :around mets-by-qual)))
          (setq fun (cl-generic-call-method generic method fun)))
        fun)))))

(defun cl--generic-cache-miss (generic
                               dispatch-arg dispatches-left methods-left types)
  (let ((methods '()))
    (dolist (method methods-left)
      (let* ((specializer (or (if (integerp dispatch-arg)
                                  (nth dispatch-arg
                                       (cl--generic-method-specializers method))
                                (cdr (assoc dispatch-arg
                                            (cl--generic-method-specializers method))))
                              t))
             (m (member specializer types)))
        (when m
          (push (cons (length m) method) methods))))
    ;; Sort the methods, most specific first.
    ;; It would be tempting to sort them once and for all in the method-table
    ;; rather than here, but the order might depend on the actual argument
    ;; (e.g. for multiple inheritance with defclass).
    (setq methods (nreverse (mapcar #'cdr (sort methods #'car-less-than-car))))
    (cl--generic-make-next-function generic dispatches-left methods)))

(cl-defgeneric cl-generic-generalizers (specializer)
  "Return a list of generalizers for a given SPECIALIZER.
To each kind of `specializer', corresponds a `generalizer' which describes
how to extract a \"tag\" from an object which will then let us check if this
object matches the specializer.  A typical example of a \"tag\" would be the
type of an object.  It's called a `generalizer' because it
takes a specific object and returns a more general approximation,
denoting a set of objects to which it belongs.
A generalizer gives us the chunk of code which the
dispatch function needs to use to extract the \"tag\" of an object, as well
as a function which turns this tag into an ordered list of
`specializers' that this object matches.
The code which extracts the tag should be as fast as possible.
The tags should be chosen according to the following rules:
- The tags should not be too specific: similar objects which match the
  same list of specializers should ideally use the same (`eql') tag.
  This insures that the cached computation of the applicable
  methods for one object can be reused for other objects.
- Corollary: objects which don't match any of the relevant specializers
  should ideally all use the same tag (typically nil).
  This insures that this cache does not grow unnecessarily large.
- Two different generalizers G1 and G2 should not use the same tag
  unless they use it for the same set of objects.  IOW, if G1.tag(X1) =
  G2.tag(X2) then G1.tag(X1) = G2.tag(X1) = G1.tag(X2) = G2.tag(X2).
- If G1.priority > G2.priority and G1.tag(X1) = G1.tag(X2) and this tag is
  non-nil, then you have to make sure that the G2.tag(X1) = G2.tag(X2).
  This is because the method-cache is only indexed with the first non-nil
  tag (by order of decreasing priority).")


(cl-defgeneric cl-generic-combine-methods (generic methods)
  "Build the effective method made of METHODS.
It should return a function that expects the same arguments as the methods, and
 calls those methods in some appropriate order.
GENERIC is the generic function (mostly used for its name).
METHODS is the list of the selected methods.
The METHODS list is sorted from most specific first to most generic last.
The function can use `cl-generic-call-method' to create functions that call those
methods.")

;; Temporary definition to let the next defmethod succeed.
(fset 'cl-generic-generalizers
      (lambda (_specializer) (list cl--generic-t-generalizer)))
(fset 'cl-generic-combine-methods
      #'cl--generic-standard-method-combination)

(cl-defmethod cl-generic-generalizers (specializer)
  "Support for the catch-all t specializer."
  (if (eq specializer t) (list cl--generic-t-generalizer)
    (error "Unknown specializer %S" specializer)))

(eval-when-compile
  ;; This macro is brittle and only really important in order to be
  ;; able to preload cl-generic without also preloading the byte-compiler,
  ;; So we use `eval-when-compile' so as not keep it available longer than
  ;; strictly needed.
(defmacro cl--generic-prefill-dispatchers (arg-or-context specializer)
  (unless (integerp arg-or-context)
    (setq arg-or-context `(&context . ,arg-or-context)))
  (unless (fboundp 'cl--generic-get-dispatcher)
    (require 'cl-generic))
  (let ((fun (cl--generic-get-dispatcher
              `(,arg-or-context ,@(cl-generic-generalizers specializer)
                                ,cl--generic-t-generalizer))))
    ;; Recompute dispatch at run-time, since the generalizers may be slightly
    ;; different (e.g. byte-compiled rather than interpreted).
    ;; FIXME: There is a risk that the run-time generalizer is not equivalent
    ;; to the compile-time one, in which case `fun' may not be correct
    ;; any more!
    `(let ((dispatch `(,',arg-or-context
                       ,@(cl-generic-generalizers ',specializer)
                       ,cl--generic-t-generalizer)))
       ;; (message "Prefilling for %S with \n%S" dispatch ',fun)
       (puthash dispatch ',fun cl--generic-dispatchers)))))

(cl-defmethod cl-generic-combine-methods (generic methods)
  "Standard support for :after, :before, :around, and `:extra NAME' qualifiers."
  (cl--generic-standard-method-combination generic methods))

(defconst cl--generic-nnm-sample (cl--generic-no-next-method-function t t))
(defconst cl--generic-cnm-sample
  (funcall (cl--generic-build-combined-method
            nil (list (cl--generic-make-method () () t #'identity)))))

(defun cl--generic-isnot-nnm-p (cnm)
  "Return non-nil if CNM is the function that calls `cl-no-next-method'."
  ;; ¡Big Gross Ugly Hack!
  ;; `next-method-p' just sucks, we should let it die.  But EIEIO did support
  ;; it, and some packages use it, so we need to support it.
  (catch 'found
    (cl-assert (function-equal cnm cl--generic-cnm-sample))
    (if (byte-code-function-p cnm)
        (let ((cnm-constants (aref cnm 2))
              (sample-constants (aref cl--generic-cnm-sample 2)))
          (dotimes (i (length sample-constants))
            (when (function-equal (aref sample-constants i)
                                  cl--generic-nnm-sample)
              (throw 'found
                     (not (function-equal (aref cnm-constants i)
                                          cl--generic-nnm-sample))))))
      (cl-assert (eq 'closure (car-safe cl--generic-cnm-sample)))
      (let ((cnm-env (cadr cnm)))
        (dolist (vb (cadr cl--generic-cnm-sample))
          (when (function-equal (cdr vb) cl--generic-nnm-sample)
            (throw 'found
                   (not (function-equal (cdar cnm-env)
                                        cl--generic-nnm-sample))))
          (setq cnm-env (cdr cnm-env)))))
    (error "Haven't found no-next-method-sample in cnm-sample")))

;;; Define some pre-defined generic functions, used internally.

(define-error 'cl-no-method "No method for %S")
(define-error 'cl-no-next-method "No next method for %S" 'cl-no-method)
(define-error 'cl-no-primary-method "No primary method for %S" 'cl-no-method)
(define-error 'cl-no-applicable-method "No applicable method for %S"
  'cl-no-method)

(cl-defgeneric cl-no-next-method (generic method &rest args)
  "Function called when `cl-call-next-method' finds no next method."
  (signal 'cl-no-next-method `(,(cl--generic-name generic) ,method ,@args)))

(cl-defgeneric cl-no-applicable-method (generic &rest args)
  "Function called when a method call finds no applicable method."
  (signal 'cl-no-applicable-method `(,(cl--generic-name generic) ,@args)))

(cl-defgeneric cl-no-primary-method (generic &rest args)
  "Function called when a method call finds no primary method."
  (signal 'cl-no-primary-method `(,(cl--generic-name generic) ,@args)))

(defun cl-call-next-method (&rest _args)
  "Function to call the next applicable method.
Can only be used from within the lexical body of a primary or around method."
  (error "cl-call-next-method only allowed inside primary and around methods"))

(defun cl-next-method-p ()
  "Return non-nil if there is a next method.
Can only be used from within the lexical body of a primary or around method."
  (declare (obsolete "make sure there's always a next method, or catch `cl-no-next-method' instead" "25.1"))
  (error "cl-next-method-p only allowed inside primary and around methods"))

;;;###autoload
(defun cl-find-method (generic qualifiers specializers)
  (car (cl--generic-member-method
        specializers qualifiers
        (cl--generic-method-table (cl--generic generic)))))

;;; Add support for describe-function

(defun cl--generic-search-method (met-name)
  (let ((base-re (concat "(\\(?:cl-\\)?defmethod[ \t]+"
                         (regexp-quote (format "%s" (car met-name)))
			 "\\_>")))
    (or
     (re-search-forward
      (concat base-re "[^&\"\n]*"
              (mapconcat (lambda (specializer)
                           (regexp-quote
                            (format "%S" (if (consp specializer)
                                             (nth 1 specializer) specializer))))
                         (remq t (cdr met-name))
                         "[ \t\n]*)[^&\"\n]*"))
      nil t)
     (re-search-forward base-re nil t))))


(with-eval-after-load 'find-func
  (defvar find-function-regexp-alist)
  (add-to-list 'find-function-regexp-alist
               `(cl-defmethod . ,#'cl--generic-search-method)))

(defun cl--generic-method-info (method)
  (let* ((specializers (cl--generic-method-specializers method))
         (qualifiers   (cl--generic-method-qualifiers method))
         (uses-cnm     (cl--generic-method-uses-cnm method))
         (function     (cl--generic-method-function method))
         (args (help-function-arglist function 'names))
         (docstring (documentation function))
         (qual-string
          (if (null qualifiers) ""
            (cl-assert (consp qualifiers))
            (let ((s (prin1-to-string qualifiers)))
              (concat (substring s 1 -1) " "))))
         (doconly (if docstring
                      (let ((split (help-split-fundoc docstring nil)))
                        (if split (cdr split) docstring))))
         (combined-args ()))
    (if uses-cnm (setq args (cdr args)))
    (dolist (specializer specializers)
      (let ((arg (if (eq '&rest (car args))
                     (intern (format "arg%d" (length combined-args)))
                   (pop args))))
        (push (if (eq specializer t) arg (list arg specializer))
              combined-args)))
    (setq combined-args (append (nreverse combined-args) args))
    (list qual-string combined-args doconly)))

(add-hook 'help-fns-describe-function-functions #'cl--generic-describe)
(defun cl--generic-describe (function)
  ;; Supposedly this is called from help-fns, so help-fns should be loaded at
  ;; this point.
  (declare-function help-fns-short-filename "help-fns" (filename))
  (let ((generic (if (symbolp function) (cl--generic function))))
    (when generic
      (require 'help-mode)              ;Needed for `help-function-def' button!
      (save-excursion
        (insert "\n\nThis is a generic function.\n\n")
        (insert (propertize "Implementations:\n\n" 'face 'bold))
        ;; Loop over fanciful generics
        (dolist (method (cl--generic-method-table generic))
          (let* ((info (cl--generic-method-info method)))
            ;; FIXME: Add hyperlinks for the types as well.
            (insert (format "%s%S" (nth 0 info) (nth 1 info)))
            (let* ((met-name (cons function
                                   (cl--generic-method-specializers method)))
                   (file (find-lisp-object-file-name met-name 'cl-defmethod)))
              (when file
                (insert " in ‘")
                (help-insert-xref-button (help-fns-short-filename file)
                                         'help-function-def met-name file
                                         'cl-defmethod)
                (insert "’.\n")))
            (insert "\n" (or (nth 2 info) "Undocumented") "\n\n")))))))

;;; Support for (head <val>) specializers.

;; For both the `eql' and the `head' specializers, the dispatch
;; is unsatisfactory.  Basically, in the "common&fast case", we end up doing
;;
;;    (let ((tag (gethash value <tagcode-hashtable>)))
;;      (funcall (gethash tag <method-cache>)))
;;
;; whereas we'd like to just do
;;
;;      (funcall (gethash value <method-cache>)))
;;
;; but the problem is that the method-cache is normally "open ended", so
;; a nil means "not computed yet" and if we bump into it, we dutifully fill the
;; corresponding entry, whereas we'd want to just fallback on some default
;; effective method (so as not to fill the cache with lots of redundant
;; entries).

(defvar cl--generic-head-used (make-hash-table :test #'eql))

(defconst cl--generic-head-generalizer
  (cl-generic-make-generalizer
   80 (lambda (name) `(gethash (car-safe ,name) cl--generic-head-used))
   (lambda (tag) (if (eq (car-safe tag) 'head) (list tag)))))

(cl-defmethod cl-generic-generalizers :extra "head" (specializer)
  "Support for the `(head VAL)' specializers."
  ;; We have to implement `head' here using the :extra qualifier,
  ;; since we can't use the `head' specializer to implement itself.
  (if (not (eq (car-safe specializer) 'head))
      (cl-call-next-method)
    (cl--generic-with-memoization
        (gethash (cadr specializer) cl--generic-head-used) specializer)
    (list cl--generic-head-generalizer)))

(cl--generic-prefill-dispatchers 0 (head eql))

;;; Support for (eql <val>) specializers.

(defvar cl--generic-eql-used (make-hash-table :test #'eql))

(defconst cl--generic-eql-generalizer
  (cl-generic-make-generalizer
   100 (lambda (name) `(gethash ,name cl--generic-eql-used))
   (lambda (tag) (if (eq (car-safe tag) 'eql) (list tag)))))

(cl-defmethod cl-generic-generalizers ((specializer (head eql)))
  "Support for the `(eql VAL)' specializers."
  (puthash (cadr specializer) specializer cl--generic-eql-used)
  (list cl--generic-eql-generalizer))

(cl--generic-prefill-dispatchers 0 (eql nil))
(cl--generic-prefill-dispatchers window-system (eql nil))

;;; Support for cl-defstructs specializers.

(defun cl--generic-struct-tag (name)
  ;; It's tempting to use (and (vectorp ,name) (aref ,name 0))
  ;; but that would suffer from some problems:
  ;; - the vector may have size 0.
  ;; - when called on an actual vector (rather than an object), we'd
  ;;   end up returning an arbitrary value, possibly colliding with
  ;;   other tagcode's values.
  ;; - it can also result in returning all kinds of irrelevant
  ;;   values which would end up filling up the method-cache with
  ;;   lots of irrelevant/redundant entries.
  ;; FIXME: We could speed this up by introducing a dedicated
  ;; vector type at the C level, so we could do something like
  ;; (and (vector-objectp ,name) (aref ,name 0))
  `(and (vectorp ,name)
        (> (length ,name) 0)
        (let ((tag (aref ,name 0)))
          (if (eq (symbol-function tag) :quick-object-witness-check)
              tag))))

(defun cl--generic-struct-specializers (tag)
  (and (symbolp tag) (boundp tag)
       (let ((class (symbol-value tag)))
         (when (cl-typep class 'cl-structure-class)
           (let ((types ())
                 (classes (list class)))
             ;; BFS precedence.
             (while (let ((class (pop classes)))
                      (push (cl--class-name class) types)
                      (setq classes
                            (append classes
                                    (cl--class-parents class)))))
             (nreverse types))))))

(defconst cl--generic-struct-generalizer
  (cl-generic-make-generalizer
   50 #'cl--generic-struct-tag
   #'cl--generic-struct-specializers))

(cl-defmethod cl-generic-generalizers :extra "cl-struct" (type)
  "Support for dispatch on cl-struct types."
  (or
   (when (symbolp type)
     ;; Use the "cl--struct-class*" (inlinable) functions/macros rather than
     ;; the "cl-struct-*" variants which aren't inlined, so that dispatch can
     ;; take place without requiring cl-lib.
     (let ((class (cl--find-class type)))
       (and (cl-typep class 'cl-structure-class)
            (or (null (cl--struct-class-type class))
		(error "Can't dispatch on cl-struct %S: type is %S"
                     type (cl--struct-class-type class)))
            (progn (cl-assert (null (cl--struct-class-named class))) t)
            (list cl--generic-struct-generalizer))))
   (cl-call-next-method)))

(cl--generic-prefill-dispatchers 0 cl--generic-generalizer)

;;; Dispatch on "system types".

(defconst cl--generic-typeof-types
  ;; Hand made from the source code of `type-of'.
  '((integer number) (symbol) (string array sequence) (cons list sequence)
    ;; Markers aren't `numberp', yet they are accepted wherever integers are
    ;; accepted, pretty much.
    (marker) (overlay) (float number) (window-configuration)
    (process) (window) (subr) (compiled-function) (buffer)
    (char-table array sequence)
    (bool-vector array sequence)
    (frame) (hash-table) (font-spec) (font-entity) (font-object)
    (vector array sequence)
    ;; Plus, hand made:
    (null symbol list sequence)
    (list sequence)
    (array sequence)
    (sequence)
    (number)))

(defconst cl--generic-typeof-generalizer
  (cl-generic-make-generalizer
   ;; FIXME: We could also change `type-of' to return `null' for nil.
   10 (lambda (name) `(if ,name (type-of ,name) 'null))
   (lambda (tag) (and (symbolp tag) (assq tag cl--generic-typeof-types)))))

(cl-defmethod cl-generic-generalizers :extra "typeof" (type)
  "Support for dispatch on builtin types."
  ;; FIXME: Add support for other types accepted by `cl-typep' such
  ;; as `character', `atom', `face', `function', ...
  (or
   (and (assq type cl--generic-typeof-types)
        (progn
          (if (memq type '(vector array sequence))
              (message "`%S' also matches CL structs and EIEIO classes" type))
          (list cl--generic-typeof-generalizer)))
   (cl-call-next-method)))

(cl--generic-prefill-dispatchers 0 integer)

;; Local variables:
;; generated-autoload-file: "cl-loaddefs.el"
;; End:

(provide 'cl-generic)
;;; cl-generic.el ends here