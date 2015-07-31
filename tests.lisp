;;;;  Copyright (c) 2007-2013 Nikodemus Siivola <nikodemus@random-state.net>
;;;;  Copyright (c) 2012-2015 Jan Moringen <jmoringe@techfak.uni-bielefeld.de>
;;;;
;;;;  Permission is hereby granted, free of charge, to any person
;;;;  obtaining a copy of this software and associated documentation files
;;;;  (the "Software"), to deal in the Software without restriction,
;;;;  including without limitation the rights to use, copy, modify, merge,
;;;;  publish, distribute, sublicense, and/or sell copies of the Software,
;;;;  and to permit persons to whom the Software is furnished to do so,
;;;;  subject to the following conditions:
;;;;
;;;;  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
;;;;  EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
;;;;  MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
;;;;  IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
;;;;  CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
;;;;  TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
;;;;  SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

(in-package :cl-user)

(defpackage :esrap-tests
  (:use :alexandria :cl :esrap :fiveam)
  (:shadowing-import-from :esrap "!")
  (:export #:run-tests))

(in-package :esrap-tests)

(def-suite esrap)
(in-suite esrap)

;;; Utilities

(defmacro with-silent-compilation-unit (() &body body)
  `(let ((*error-output* (make-broadcast-stream)))
     (with-compilation-unit (:override t)
       ,@body)))

(defun call-expecting-signals-esrap-error (thunk input position
                                           &optional messages)
  (signals (esrap-error) (funcall thunk))
  (handler-case (funcall thunk)
    (esrap-error (condition)
      (is (string= (esrap-error-text condition) input))
      (when position
        (is (= (esrap-error-position condition) position)))
      (let ((report (princ-to-string condition))
            (position 0))
        (mapc (lambda (message)
                (is (setf position (search message report
                                           :start2 position))))
              messages)))))

(eval-when (:compile-toplevel :load-toplevel :execute)
  (defmacro signals-esrap-error ((input position &optional messages) &body body)
    `(call-expecting-signals-esrap-error
      (lambda () ,@body) ,input ,position (list ,@(ensure-list messages)))))

;;; defrule tests

(test defrule.check-expression
  "Test expression checking in DEFRULE."
  (macrolet ((is-invalid-expr (expression)
               `(signals invalid-expression-error
                  (defrule foo ,expression))))
    (is-invalid-expr (~ 1))
    (is-invalid-expr (string))
    (is-invalid-expr (character-ranges 1))
    (is-invalid-expr (character-ranges (#\a)))
    (is-invalid-expr (character-ranges (#\a #\b #\c)))
    (is-invalid-expr (and (string)))
    (is-invalid-expr (not))
    (is-invalid-expr (foo))
    (is-invalid-expr (function))
    (is-invalid-expr (function foo bar))
    (is-invalid-expr (function 1))
    (is-invalid-expr (function (lambda (x) x)))))

(test defrule.ignore-declarations
  "Test ignore declarations generated by DEFRULE."
  (macrolet ((does-not-warn (condition-class &body body)
               `(finishes
                 (handler-case (compile nil '(lambda () ,@body))
                   (,condition-class (condition)
                     (fail "Signaled an unexpected warning: ~A." condition))))))
    (does-not-warn style-warning
      (defrule foo (and)
        (:function second)
        (:lambda (x) (declare (ignore x)))))))

(test defrule.conditions
  "Test signaling of errors for DEFRULE syntax errors."
  (flet ((test-case (form)
           (signals error (macroexpand form))))
    (test-case '(defrule multiple-guards "foo"
                  (:when foo)
                  (:when bar)))
    (test-case '(defrule multiple-expressions-in-when "foo"
                  (:when foo bar)))))

;;; A few semantic predicates

(defun not-doublequote (char)
  (not (eql #\" char)))

(defun not-digit (char)
  (when (find-if-not #'digit-char-p char)
    t))

(defun not-newline (char)
  (not (eql #\newline char)))

(defun not-space (char)
  (not (eql #\space char)))

;;; Utility rules

(defrule whitespace (+ (or #\space #\tab #\newline))
  (:text t))

(defrule empty-line #\newline
  (:constant ""))

(defrule non-empty-line (and (+ (not-newline character)) (? #\newline))
  (:destructure (text newline)
    (declare (ignore newline))
    (text text)))

(defrule line (or empty-line non-empty-line)
  (:identity t))

(defrule trimmed-line line
  (:lambda (line)
    (string-trim '(#\space #\tab) line)))

(defrule trimmed-lines (* trimmed-line)
  (:identity t))

(defrule digits (+ (digit-char-p character))
  (:text t))

(defrule integer (and (? whitespace)
                      digits
                      (and (? whitespace) (or (& #\,) (! character))))
  (:destructure (whitespace digits tail)
    (declare (ignore whitespace tail))
    (parse-integer digits)))

(defrule list-of-integers (+ (or (and integer #\, list-of-integers)
                                 integer))
  (:destructure (match)
    (if (integerp match)
        (list match)
        (destructuring-bind (int comma list) match
          (declare (ignore comma))
          (cons int list)))))

(test smoke
  (is (equal '(("1," "2," "" "3," "4.") nil t)
             (multiple-value-list
              (parse 'trimmed-lines "1,
                                     2,

                                     3,
                                     4."))))
  (is (equal '(123 nil t)
             (multiple-value-list (parse 'integer "  123"))))
  (is (equal '(123 nil t)
             (multiple-value-list (parse 'integer "  123  "))))
  (is (equal '(123 nil t)
             (multiple-value-list (parse 'integer "123  "))))
  (is (equal '((123 45 6789 0) nil t)
             (multiple-value-list
              (parse 'list-of-integers "123, 45  ,   6789, 0"))))
  (is (equal '((123 45 6789 0) nil t)
             (multiple-value-list
              (parse 'list-of-integers "  123 ,45,6789, 0  "))))

  ;; Ensure that parsing with :junk-allowed returns the correct
  ;; position.
  (is (equal '(nil 1)
             (multiple-value-list (parse 'list-of-integers " a"
                                         :start 1 :junk-allowed t))))

  ;; Test successful parse that does not consume input. This case can
  ;; only be detected by examining the third return value.
  (is (equal '(nil 1 t)
             (multiple-value-list
              (parse '(? list-of-integers) " a"
                     :start 1 :junk-allowed t))))

  ;; Handling of :raw (by the compiler-macro).
  (is (equal '(123 nil t)
             (multiple-value-list (parse 'integer "123" :raw nil))))
  (is (typep (parse 'integer "123" :raw t) 'esrap::result))
  (is (typep (parse 'integer "12a" :raw t) 'esrap::error-result)))

(defrule single-token/bounds.1 (+ (not-space character))
  (:lambda (result &bounds start end)
    (format nil "~A[~S-~S]" (text result) start end)))

(defrule single-token/bounds.2 (and (not-space character) (* (not-space character)))
  (:destructure (first &rest rest &bounds start end)
    (format nil "~C~A(~S-~S)" first (text rest) start end)))

(defrule tokens/bounds.1 (and (? whitespace)
                              (or (and single-token/bounds.1 whitespace tokens/bounds.1)
                                  single-token/bounds.1))
  (:destructure (whitespace match)
    (declare (ignore whitespace))
    (if (stringp match)
        (list match)
        (destructuring-bind (token whitespace list) match
          (declare (ignore whitespace))
          (cons token list)))))

(defrule tokens/bounds.2 (and (? whitespace)
                              (or (and single-token/bounds.2 whitespace tokens/bounds.2)
                                  single-token/bounds.2))
  (:destructure (whitespace match)
    (declare (ignore whitespace))
    (if (stringp match)
        (list match)
        (destructuring-bind (token whitespace list) match
          (declare (ignore whitespace))
          (cons token list)))))

(test bounds.1
  (is (equal '("foo[0-3]")
             (parse 'tokens/bounds.1 "foo")))
  (is (equal '("foo[0-3]" "bar[4-7]" "quux[11-15]")
             (parse 'tokens/bounds.1 "foo bar    quux"))))

(test bounds.2
  (is (equal '("foo(0-3)")
             (parse 'tokens/bounds.2 "foo")))
  (is (equal '("foo(0-3)" "bar(4-7)" "quux(11-15)")
             (parse 'tokens/bounds.2 "foo bar    quux"))))

;;; Function terminals

(defun parse-integer1 (text position end)
  (parse-integer text :start position :end end :junk-allowed t))

(defrule function-terminals.integer #'parse-integer1)

(test function-terminals.parse-integer
  "Test using the function PARSE-INTEGER1 as a terminal."
  (macrolet ((test-case (input expected
                         &optional
                         (expression ''function-terminals.integer))
               `(is (equal ,expected (parse ,expression ,input)))))
    (test-case "1"  1)
    (test-case " 1" 1)
    (test-case "-1" -1)
    (test-case "-1" '(-1 nil)
               '(and (? function-terminals.integer) (* character)))
    (test-case "a"  '(nil (#\a))
               '(and (? function-terminals.integer) (* character)))))

(defun parse-5-as (text position end)
  (let ((chars  '())
        (amount 0))
    (dotimes (i 5)
      (let ((char (when (< (+ position i) end)
                    (aref text (+ position i)))))
        (unless (eql char #\a)
          (return-from parse-5-as
            (values nil (+ position i) "Expected \"a\".")))
        (push char chars)
        (incf amount)))
    (values (nreverse chars) (+ position amount))))

(defrule function-terminals.parse-5-as #'parse-5-as)

(test function-terminals.parse-5-as.smoke
  "Test using PARSE-A as a terminal."
  (macrolet ((test-case (input expected
                         &optional (expression ''function-terminals.parse-5-as))
               `(is (equal ,expected (parse ,expression ,input)))))
    (test-case "aaaaa" '(#\a #\a #\a #\a #\a))
    (test-case "b" '(nil "b") '(and (? function-terminals.parse-5-as) #\b))
    (test-case "aaaaab" '((#\a #\a #\a #\a #\a) "b")
               '(and (? function-terminals.parse-5-as) #\b))))

(test function-terminals.parse-5-as.condition
  "Test using PARSE-A as a terminal."
  (handler-case
      (parse 'function-terminals.parse-5-as "aaaab")
    (esrap-error (condition)
      (is (eql 4 (esrap-error-position condition)))
      (is (search "Expected \"a\"." (princ-to-string condition))))))

(defun function-terminals.nested-parse (text position end)
  (parse '(and #\d function-terminals.nested-parse)
         text :start position :end end :junk-allowed t))

(defrule function-terminals.nested-parse
    (or (and #'function-terminals.nested-parse #\a)
        (and #\b #'function-terminals.nested-parse)
        #\c))

(test function-terminals.nested-parse
  "Test a function terminal which itself calls PARSE."
  (parse 'function-terminals.nested-parse "bddca"))

(test function-terminals.nested-parse.condition
  "Test propagation of failure information through function terminals."
  (signals esrap-error (parse 'function-terminals.nested-parse "bddxa")))

(defun function-terminals.without-consuming (text position end)
  (declare (ignore end))
  (if (char= (aref text position) #\a)
      (values :ok position t)
      (values nil position "\"a\" expected")))

(test function-terminals.without-consuming
  "Test that function terminals can succeed without consuming input."
  (is (equal '((:ok "a") nil t)
             (multiple-value-list
              (parse '(and #'function-terminals.without-consuming #\a) "a"))))

  (is (equal '(((:ok "a" :ok) (:ok "a" :ok)) 2 t)
             (multiple-value-list
              (parse '(+ (and #'function-terminals.without-consuming #\a
                              #'function-terminals.without-consuming))
                     "aaab" :junk-allowed t)))))

;;; Left recursion tests

(defun make-input-and-expected-result (size)
  (labels ((make-expected (size)
             (if (plusp size)
                 (list (make-expected (1- size)) "l")
                 "r")))
    (let ((expected (make-expected size)))
      (values (apply #'concatenate 'string (flatten expected)) expected))))

(defrule left-recursion.direct
    (or (and left-recursion.direct #\l) #\r))

(test left-recursion.direct.success
  "Test parsing with one left recursive rule for different inputs."
  (dotimes (i 20)
    (multiple-value-bind (input expected)
        (make-input-and-expected-result i)
      (is (equal expected (parse 'left-recursion.direct input))))))

(test left-recursion.direct.condition
  "Test signaling of `left-recursion' condition if requested."
  (let ((*on-left-recursion* :error))
    (signals (left-recursion)
      (parse 'left-recursion.direct "l"))
    (handler-case (parse 'left-recursion.direct "l")
      (left-recursion (condition)
        (is (string= (esrap-error-text condition) "l"))
        (is (= (esrap-error-position condition) 0))
        (is (eq (left-recursion-nonterminal condition)
                'left-recursion.direct))
        (is (equal (left-recursion-path condition)
                   '(left-recursion.direct
                     left-recursion.direct)))))))

(defrule left-recursion.indirect.1 left-recursion.indirect.2)

(defrule left-recursion.indirect.2 (or (and left-recursion.indirect.1 "l") "r"))

(test left-recursion.indirect.success
  "Test parsing with mutually left recursive rules for different
   inputs."
  (dotimes (i 20)
    (multiple-value-bind (input expected)
        (make-input-and-expected-result i)
      (is (equal expected (parse 'left-recursion.indirect.1 input)))
      (is (equal expected (parse 'left-recursion.indirect.2 input))))))

(test left-recursion.indirect.condition
  "Test signaling of `left-recursion' condition if requested."
  (let ((*on-left-recursion* :error))
    (signals (left-recursion)
      (parse 'left-recursion.indirect.1 "l"))
    (handler-case (parse 'left-recursion.indirect.1 "l")
      (left-recursion (condition)
        (is (string= (esrap-error-text condition) "l"))
        (is (= (esrap-error-position condition) 0))
        (is (eq (left-recursion-nonterminal condition)
                'left-recursion.indirect.1))
        (is (equal (left-recursion-path condition)
                   '(left-recursion.indirect.1
                     left-recursion.indirect.2
                     left-recursion.indirect.1)))))))

;;; Test conditions

(declaim (special *active*))

(defvar *active* nil)

(defrule condition.maybe-active "foo"
  (:when *active*))

(defrule condition.always-active "foo"
  (:when t))

(defrule condition.never-active "foo"
  (:when nil))

(test condition.maybe-active
  "Rule not active at toplevel."
  (flet ((do-it () (parse 'condition.maybe-active "foo"))) ; TODO avoid redundancy
    (signals esrap-error (do-it))
    (handler-case (do-it)
      (esrap-error (condition)
        (search "Rule CONDITION.MAYBE-ACTIVE not active"
                (princ-to-string condition)))))

  (finishes (let ((*active* t))
              (parse 'condition.maybe-active "foo")))

  (finishes (parse 'condition.always-active "foo"))

  (flet ((do-it () (parse 'condition.never-active "foo")))
    (signals esrap-error (do-it))
    (handler-case (do-it)
      (esrap-error (condition)
        (search "Rule CONDITION.NEVER-ACTIVE not active"
                (princ-to-string condition))))))

(defrule condition.undefined-dependency
    (and "foo" no-such-rule))

(test condition.undefined-rules
  "Test handling of undefined rules."
  (signals undefined-rule-error
    (parse 'no-such-rule "foo"))
  (signals undefined-rule-error
    (parse 'condition.undefined-dependency "foo")))

(test condition.invalid-argument-combinations
  "Test handling of invalid PARSE argument combinations."
  ;; Prevent the compiler-macro form recognizing the invalid argument
  ;; combination at compile-time.
  (locally (declare (notinline parse))
    (signals error (parse 'integer "1" :junk-allowed t :raw t)))
  ;; Compiler-macro should recognize the invalid argument combination
  ;; at compile-time. Relies on the implementation detecting invalid
  ;; keyword arguments at compile-time.
  (signals warning
    (with-silent-compilation-unit ()
      (compile nil '(lambda ()
                      (parse 'integer "1" :junk-allowed t :raw t))))))

(test condition.misc
  "Test signaling of `esrap-simple-parse-error' conditions for failed
   parses."
  ;; Rule does not allow empty string.
  (signals-esrap-error ("" 0 ("At end of input"
                              "^ (Line 1, Column 0, Position 0)"
                              "Could not parse subexpression"))
    (parse 'integer ""))

  ;; Junk at end of input.
  (signals-esrap-error ("123foo" 3 ("At" "^ (Line 1, Column 3, Position 3)"
                                         "Could not parse subexpression"))
    (parse 'integer "123foo"))

  ;; Whitespace not allowed.
  (signals-esrap-error ("1, " 1 ("At" "^ (Line 1, Column 1, Position 1)"
                                      "Incomplete parse."))
    (parse 'list-of-integers "1, "))

  ;; Multi-line input.
  (signals-esrap-error ("1,
2, " 4 ("At" "1," "^ (Line 2, Column 1, Position 4)" "Incomplete parse."))
    (parse 'list-of-integers "1,
2, "))

  ;; Rule not active at toplevel.
  (signals-esrap-error ("foo" nil ("Rule" "not active"))
    (parse 'condition.never-active "foo"))

  ;; Rule not active at subexpression-level.
  (signals-esrap-error ("ffoo" 1 ("At" "(Line 1, Column 1, Position 1)"
                                       "Could not parse subexpression"
                                       "(not active)"))
    (parse '(and "f" condition.never-active) "ffoo"))

  ;; Failing function terminal.
  (signals-esrap-error ("(1 2" 0 ("At" "(Line 1, Column 0, Position 0)"
                                       "FUNCTION-TERMINALS.INTEGER"))
    (parse 'function-terminals.integer "(1 2")))

(test parse.string
  "Test parsing an arbitrary string of a given length."
  (is (equal "" (parse '(string 0) "")))
  (is (equal "aa" (parse '(string 2) "aa")))
  (signals esrap-error (parse '(string 0) "a"))
  (signals esrap-error (parse '(string 2) "a"))
  (signals esrap-error (parse '(string 2) "aaa")))

(test parse.case-insensitive
  "Test parsing an arbitrary string of a given length."
  (dolist (input '("aabb" "AABB" "aAbB" "aaBB" "AAbb"))
    (unless (every #'lower-case-p input)
      (signals esrap-error (parse '(* (or #\a #\b)) input)))
    (is (equal "aabb" (text (parse '(* (or (~ #\a) (~ #\b))) input))))
    (is (equal "AABB" (text (parse '(* (or (~ #\A) (~ #\B))) input))))
    (is (equal "aaBB" (text (parse '(* (or (~ #\a) (~ #\B))) input))))))

(test parse.negation
  "Test negation in rules."
  (let* ((text "FooBazBar")
         (t1c (text (parse '(+ (not "Baz")) text :junk-allowed t)))
         (t1e (text (parse (identity '(+ (not "Baz"))) text :junk-allowed t)))
         (t2c (text (parse '(+ (not "Bar")) text :junk-allowed t)))
         (t2e (text (parse (identity '(+ (not "Bar"))) text :junk-allowed t)))
         (t3c (text (parse '(+ (not (or "Bar" "Baz"))) text :junk-allowed t)))
         (t3e (text (parse (identity '(+ (not (or "Bar" "Baz")))) text :junk-allowed t))))
    (is (equal "Foo" t1c))
    (is (equal "Foo" t1e))
    (is (equal "FooBaz" t2c))
    (is (equal "FooBaz" t2e))
    (is (equal "Foo" t3c))
    (is (equal "Foo" t3e))))

;;; Test around

(defvar *around.depth* nil)

(defrule around/inner
    (+ (alpha-char-p character))
  (:text t))

(defrule around.1
    (or around/inner (and #\{ around.1 #\}))
  (:lambda (thing)
    (if (stringp thing)
        (cons *around.depth* thing)
        (second thing)))
  (:around ()
    (let ((*around.depth*
           (if *around.depth*
               (cons (1+ (first *around.depth*)) *around.depth*)
               (list 0))))
      (call-transform))))

(defrule around.2
    (or around/inner (and #\{ around.2 #\}))
  (:lambda (thing)
    (if (stringp thing)
        (cons *around.depth* thing)
        (second thing)))
  (:around (&bounds start end)
    (let ((*around.depth*
           (if *around.depth*
               (cons (cons (1+ (car (first *around.depth*))) (cons start end))
                     *around.depth*)
               (list (cons 0 (cons start end))))))
      (call-transform))))

(test around.1
  "Test executing code around the transform of a rule."
  (macrolet ((test-case (input expected)
               `(is (equal ,expected (parse 'around.1 ,input)))))
    (test-case "foo"     '((0) . "foo"))
    (test-case "{bar}"   '((1 0) . "bar"))
    (test-case "{{baz}}" '((2 1 0) . "baz"))))

(test around.2
  "Test executing code around the transform of a rule."
  (macrolet ((test-case (input expected)
               `(is (equal ,expected (parse 'around.2 ,input)))))
    (test-case "foo"     '(((0 . (0 . 3)))
                           . "foo"))
    (test-case "{bar}"   '(((1 . (1 . 4))
                            (0 . (0 . 5)))
                           . "bar"))
    (test-case "{{baz}}" '(((2 . (2 . 5))
                            (1 . (1 . 6))
                            (0 . (0 . 7)))
                           . "baz"))))

;;; Test character ranges

(defrule character-range (character-ranges (#\a #\b) #\-))

(test character-range
  (is (equal '(#\a #\b) (parse '(* (character-ranges (#\a #\z) #\-)) "ab" :junk-allowed t)))
  (is (equal '(#\a #\b) (parse '(* (character-ranges (#\a #\z) #\-)) "ab1" :junk-allowed t)))
  (is (equal '(#\a #\b #\-) (parse '(* (character-ranges (#\a #\z) #\-)) "ab-" :junk-allowed t)))
  (is (not (parse '(* (character-ranges (#\a #\z) #\-)) "AB-" :junk-allowed t)))
  (is (not (parse '(* (character-ranges (#\a #\z) #\-)) "ZY-" :junk-allowed t)))
  (is (equal '(#\a #\b #\-) (parse '(* character-range) "ab-cd" :junk-allowed t))))

;;; Test multiple transforms

(defrule multiple-transforms.1
    (and #\a #\1 #\c)
  (:function second)
  (:text t)
  (:function parse-integer))

(test multiple-transforms.1
  "Apply composed transforms to parse result."
  (is (eql (parse 'multiple-transforms.1 "a1c") 1)))

(test multiple-transforms.invalid
  "Test DEFRULE's behavior for invalid transforms."
  (dolist (form '((defrule multiple-transforms.2 #\1
                    (:text t)
                    (:lambda (x &bounds start end)
                      (parse-integer x)))
                  (defrule multiple-transforms.3 #\1
                    (:text t)
                    (:lambda (x &bounds start)
                      (parse-integer x)))))
    (signals simple-error (macroexpand-1 form))))

;;; Test rule introspection

(defrule expression-start-terminals.1
    (or expression-start-terminals.2 #\a))

(defrule expression-start-terminals.2
    (or #\c (and (? #\b) expression-start-terminals.1)))

(test expression-start-terminals.smoke
  (macrolet
      ((test-case (expression expected)
         `(is (equal ',expected (expression-start-terminals ,expression)))))
    (test-case '(and)                              ())
    (test-case '(or)                               ())
    (test-case 'character                          (character))
    (test-case '(string 5)                         ((string 5)))
    (test-case #\A                                 (#\A))
    (test-case '(or #\B #\A)                       (#\A #\B))
    (test-case '(or character #\A)                 (#\A character))
    (test-case '(or #\A "foo")                     ("foo" #\A))
    (test-case "foo"                               ("foo"))
    (test-case '(or "foo" "bar")                   ("bar" "foo"))
    (test-case '(character-ranges (#\a #\z))       ((character-ranges (#\a #\z))))
    (test-case '(~ "foo")                          ((~ "foo")))
    (test-case '#'parse-integer                    (#'parse-integer))
    (test-case '(digit-char-p (and))               ())
    (test-case '(digit-char-p character)           ((digit-char-p (character))))
    (test-case '(or (digit-char-p character) #\a)  (#\a (digit-char-p (character))))
    (test-case 'expression-start-terminals.1       (#\a #\b #\c))
    (test-case 'expression-start-terminals.2       (#\a #\b #\c))
    (test-case 'left-recursion.direct              (#\l #\r))
    (test-case '(or #\b #\a)                       (#\a #\b))
    (test-case '(and #\a #\b)                      (#\a))
    (test-case '(and (or #\a #\b) #\c)             (#\a #\b))
    (test-case '(and (? #\a) #\b)                  (#\a #\b))
    (test-case '(and (? #\a) (? #\b) (or #\d #\c)) (#\a #\b #\c #\d))
    (test-case '(and (and) #\a)                    (#\a))
    (test-case '(not (or #\a #\b))                 ((not (#\a #\b))))
    (test-case '(not character)                    ((not (character))))
    (test-case '(! (or #\a #\b))                   ((! (#\a #\b))))
    (test-case '(! character)                      ((! (character))))
    (test-case '(& #\a)                            (#\a))
    (test-case '(* #\a)                            (#\a))
    (test-case '(+ #\a)                            (#\a))))

(test describe-terminal.smoke
  (macrolet
      ((test-case (terminal expected)
         `(is (string= ,expected (with-output-to-string (stream)
                                   (describe-terminal ,terminal stream))))))
    (test-case 'character  "any character")
    (test-case '(string 5) "a string of length 5")
    (test-case #\a         (format nil "the character a (~A)" (char-name #\a)))
    (test-case #\Space     "the character Space")
    (test-case '(~ #\a)    (format nil "the character a (~A), disregarding case"
                                   (char-name #\a)))
    (test-case "f"         (format nil "the character f (~A)" (char-name #\f)))
    (test-case "foo"       "the string \"foo\"")
    (test-case '(~ "foo")  "the string \"foo\", disregarding case")
    (test-case '(character-ranges (#\a #\z))
               "a character in [a-z]")
    (test-case '#'parse-integer
               "a string that can be parsed by the function PARSE-INTEGER")
    (test-case '(digit-char-p (character))
               "any character satisfying DIGIT-CHAR-P")
    (test-case '(digit-char-p ((~ "foo")))
               "the string \"foo\", disregarding case satisfying DIGIT-CHAR-P")
    (test-case '(not (#\a #\b))
               (format nil "anything but the character a (~A) and the ~
                            character b (~A)"
                       (char-name #\a) (char-name #\b)))
    (test-case '(not (character)) "<end of input>")
    (test-case '(! (#\a #\b))
               (format nil "anything but the character a (~A) and the ~
                            character b (~A)"
                       (char-name #\a) (char-name #\b)))))

(test describe-terminal.condition
  (signals error (describe-terminal '(and #\a #\b))))

(defrule describe-grammar.undefined-dependency
    describe-grammar.no-such-rule.1)

(test describe-grammar.smoke
  "Smoke test for DESCRIBE-GRAMMAR."
  (mapc
   (lambda (spec)
     (destructuring-bind (rule &rest expected) spec
       (let ((output (with-output-to-string (stream)
                       (describe-grammar rule stream))))
         (mapc (lambda (expected)
                 (is (search expected output)))
               (ensure-list expected)))))

   '((condition.maybe-active
      "Grammar CONDITION.MAYBE-ACTIVE"
      "MAYBE-ACTIVE" "<-" "\"foo\" : *ACTIVE*")
     (describe-grammar.undefined-dependency
      "Grammar DESCRIBE-GRAMMAR.UNDEFINED-DEPENDENCY"
      "Undefined nonterminal" "DESCRIBE-GRAMMAR.NO-SUCH-RULE.1")
     (describe-grammar.no-such-rule.1
      "Symbol DESCRIBE-GRAMMAR.NO-SUCH-RULE.1 is not a defined nonterminal.")
     (describe-grammar.no-such-rule.2
      "Symbol DESCRIBE-GRAMMAR.NO-SUCH-RULE.2 is not a defined nonterminal.")
     (around.1
      "Grammar AROUND.1"
      "AROUND.1" "<-" ": T" "AROUND/INNER" "<-" ": T")
     (around.2
      "Grammar AROUND.2"
      "AROUND.2" "<-" ": T" "AROUND/INNER" "<-" ": T")
     (character-range
      "Grammar CHARACTER-RANGE"
      "CHARACTER-RANGE" "<-" "(CHARACTER-RANGES (#\\a" ": T")
     (multiple-transforms.1
      "Grammar MULTIPLE-TRANSFORMS.1"
      "MULTIPLE-TRANSFORMS.1" "<-" "(AND #\\a #\\1" ": T"))))

;;; Test tracing

(test trace-rule.smoke
  "Smoke test for the rule (un)tracing functionality."
  (labels
      ((parse-with-trace (rule text)
         (with-output-to-string (*trace-output*)
           (parse rule text)))
       (test-case (trace-rule trace-args parse-rule text expected)
         ;; No trace output before tracing.
         (is (emptyp (parse-with-trace parse-rule text)))
         ;; Trace output.
         (apply #'trace-rule trace-rule trace-args)
         (is (string= expected (parse-with-trace parse-rule text)))
         ;; Back to no output.
         (apply #'untrace-rule trace-rule trace-args)
         (is (emptyp (parse-with-trace parse-rule text)))))

    ;; Smoke test 1.
    (test-case 'integer '() 'integer "123"
               "1: INTEGER 0?
1: INTEGER 0-3 -> 123
")

    ;; Smoke test 2.
    (test-case 'integer '(:recursive t) 'integer "12"
               "1: INTEGER 0?
 2: WHITESPACE 0?
 2: WHITESPACE -|
 2: DIGITS 0?
 2: DIGITS 0-2 -> \"12\"
 2: WHITESPACE 2?
 2: WHITESPACE -|
1: INTEGER 0-2 -> 12
")

    ;; Left-recursive rule - non-recursive tracing.
    (test-case 'left-recursion.direct '()
               'left-recursion.direct "rl"
               "1: LEFT-RECURSION.DIRECT 0?
 2: LEFT-RECURSION.DIRECT 0?
 2: LEFT-RECURSION.DIRECT -|
 2: LEFT-RECURSION.DIRECT 0?
 2: LEFT-RECURSION.DIRECT 0-1 -> \"r\"
 2: LEFT-RECURSION.DIRECT 0?
 2: LEFT-RECURSION.DIRECT 0-2 -> (\"r\" \"l\")
1: LEFT-RECURSION.DIRECT 0-2 -> (\"r\" \"l\")
")

    ;; Left-recursive rule - recursive tracing.
    (test-case 'left-recursion.direct '(:recursive t)
               'left-recursion.direct "rl"
               "1: LEFT-RECURSION.DIRECT 0?
 2: LEFT-RECURSION.DIRECT 0?
 2: LEFT-RECURSION.DIRECT -|
 2: LEFT-RECURSION.DIRECT 0?
 2: LEFT-RECURSION.DIRECT 0-1 -> \"r\"
 2: LEFT-RECURSION.DIRECT 0?
 2: LEFT-RECURSION.DIRECT 0-2 -> (\"r\" \"l\")
1: LEFT-RECURSION.DIRECT 0-2 -> (\"r\" \"l\")
")

    ;; Conditional tracing.
    (test-case 'digits `(:condition ,(lambda (symbol text position end)
                                       (declare (ignore symbol text end))
                                       (= position 0)))
               'list-of-integers "123, 123"
               "1: DIGITS 0?
1: DIGITS 0-3 -> \"123\"
")))

(test trace-rule.condition
  "Test conditions signaled by the rule (un)tracing functionality."
  ;; It is important for this test that no rule of the given name
  ;; exists - including as undefined dependency of another rule.
  (signals error (trace-rule 'trace-rule.condition.no-such-rule.1))
  (signals error (untrace-rule 'trace-rule.condition.no-such-rule.1)))

(defrule trace-rule.condition.recursive
    (and trace-rule.condition.no-such-rule.2))

(test trace-rule.condition.recursive+undefined-rule
  "Recursively tracing a rule with undefined dependencies should not
   signal an error."
  (finishes
    (trace-rule 'trace-rule.condition.recursive :recursive t)))

(defrule trace-rule.redefinition (and))

(test trace-rule.redefinition
  "Make sure that a traced rule can be redefined. This used to signal
   an error."
  (trace-rule 'trace-rule.redefinition)
  (change-rule 'trace-rule.redefinition '(and)))

;;; Test README examples

(test examples-from-readme.foo
  "README examples related to \"foo+\" rule."
  (is (equal '("foo" nil t)
             (multiple-value-list (parse '(or "foo" "bar") "foo"))))
  (is (eq 'foo+ (add-rule 'foo+
                          (make-instance 'rule :expression '(+ "foo")))))
  (is (equal '(("foo" "foo" "foo") nil t)
             (multiple-value-list (parse 'foo+ "foofoofoo")))))

(test examples-from-readme.decimal
  "README examples related to \"decimal\" rule."
  (is (eq 'decimal
          (add-rule
           'decimal
           (make-instance
            'rule
            :expression `(+ (or "0" "1" "2" "3" "4" "5" "6" "7" "8" "9"))
            :transform (lambda (list start end)
                         (declare (ignore start end))
                         (parse-integer (format nil "~{~A~}" list)))))))
  (is (eql 123 (parse '(oddp decimal) "123")))
  (is (equal '(nil 0) (multiple-value-list
                       (parse '(evenp decimal) "123" :junk-allowed t)))))

;;; Examples in separate files

(test example-left-recursion.left-associative
  "Left associate grammar from example-left-recursion.lisp."
  ;; This grammar should work without left recursion.
  (let ((*on-left-recursion* :error))
    (is (equal (parse 'left-recursive-grammars:la-expr "1*2+3*4+5")
               '(+ (* 1 2) (+ (* 3 4) 5))))))

(test example-left-recursion.right-associative
  "Right associate grammar from example-left-recursion.lisp."
  ;; This grammar combination of grammar and input would require left
  ;; recursion.
  (let ((*on-left-recursion* :error))
    (signals left-recursion
      (parse 'left-recursive-grammars:ra-expr "1*2+3*4+5")))

  (is (equal (parse 'left-recursive-grammars:ra-expr "1*2+3*4+5")
             '(+ (+ (* 1 2) (* 3 4)) 5))))

(test example-left-recursion.warth.smoke
  "Warth's Java expression example from example-left-recursion.lisp."
 (mapc
  (curry #'apply
         (lambda (input expected)
           (is (equal expected
                      (parse 'left-recursive-grammars:primary input)))))
  '(("this"       "this")
    ("this.x"     (:field-access "this" "x"))
    ("this.x.y"   (:field-access (:field-access "this" "x") "y"))
    ("this.x.m()" (:method-invocation (:field-access "this" "x") "m"))
    ("x[i][j].y"  (:field-access (:array-access (:array-access "x" "i") "j") "y")))))

(test example-function-terminals.indented-block.smoke
  "Context-sensitive parsing via function terminals."
  (is (equal '("foo" "bar" "quux"
               (if "foo"
                   ("bla"
                    (if "baz"
                        ("bli" "blo")
                        ("whoop"))))
               "blu")
             (parse 'esrap-example.function-terminals:indented-block
                    "   foo
   bar
   quux
   if foo:
    bla
    if baz:
       bli
       blo
    else:
     whoop
   blu
"))))

(test example-function-terminals.indented-block.condition
  "Context-sensitive parsing via function terminals."
  (let ((input "if foo:
bla
"))
    (signals-esrap-error (input 0 ("Expected indent"))
      (parse 'esrap-example.function-terminals:indented-block input))))

(test example-function-terminals.read.smoke
  "Using CL:READ as a terminal."
  (macrolet ((test-case (input expected)
               `(is (equal ,expected
                           (with-standard-io-syntax
                             (parse 'esrap-example.function-terminals:common-lisp
                                    ,input))))))
    (test-case "(1 2 3)" '(1 2 3))
    (test-case "foo" 'cl-user::foo)
    (test-case "#C(1 3/4)" #C(1 3/4))))

(test example-function-terminals.read.condition
  "Test error reporting in the CL:READ-based rule"
  (handler-case
      (with-standard-io-syntax
        (parse 'esrap-example.function-terminals:common-lisp
               "(list 'i :::love 'lisp"))
    (esrap-error (condition)
      ;; Different readers may report this differently.
      (is (<= 9 (esrap-error-position condition) 16))
      ;; Not sure how other lists report this.
      #+sbcl (is (search "too many colons"
                         (princ-to-string condition))))))

;;; Test runner

(defun run-tests ()
  (let ((results (run 'esrap)))
    (explain! results)
    (results-status results)))
