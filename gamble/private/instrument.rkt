;; Copyright (c) 2014 Ryan Culpepper
;; Released under the terms of the 2-clause BSD license.
;; See the file COPYRIGHT for details.

#lang racket/base
(require (for-syntax racket/base
                     racket/list
                     racket/syntax
                     syntax/parse
                     syntax/id-table
                     "analysis/base.rkt"
                     "analysis/known-functions.rkt"
                     "analysis/stxclass.rkt"
                     "analysis/calls-erp.rkt"
                     "analysis/obs-exp.rkt"
                     "analysis/cond-ctx.rkt")
         racket/match
         "instrument-data.rkt"
         "interfaces.rkt"
         "context.rkt")
(provide describe-all-call-sites
         describe-call-site
         instrumenting-module-begin
         instrumenting-top-interaction
         begin-instrumented
         instrument/local-expand
         (for-syntax analyze)
         instrument
         next-counter
         declare-observation-propagator)

(begin-for-syntax
  ;; analyze : Syntax -> Syntax
  (define (analyze stx)
    (define tagged-stx (analyze-TAG stx))
    (analyze-FUN-EXP tagged-stx)
    (analyze-CALLS-ERP tagged-stx)
    (analyze-COND-CTX tagged-stx #f)
    (analyze-OBS-EXP tagged-stx)
    tagged-stx))

(begin-for-syntax
  ;; display with: PLTSTDERR="info@instr" racket ....
  (define-logger instr))

(define-syntax (fresh-call-site stx)
  (syntax-case stx ()
    [(fresh-call-site info)
     #'(#%plain-app next-counter
         (#%plain-app variable-reference->module-source (#%variable-reference))
         info)]))

(begin-for-syntax
  (define (lift-call-site stx)
    (with-syntax ([stx-file (syntax-source stx)]
                  [line (syntax-line stx)]
                  [col (syntax-column stx)]
                  [fun (syntax-case stx (#%plain-app)
                         [(#%plain-app f arg ...) (identifier? #'f) #'f]
                         [_ #f])])
      (syntax-local-lift-expression
       #`(fresh-call-site '(stx-file line col #,stx f))))))

;; ----

(define-syntax (instrumenting-module-begin stx)
  (syntax-case stx ()
    [(instrumenting-module-begin form ...)
     (with-syntax ([(_pmb e-form ...)
                    (analyze
                     (local-expand #'(#%plain-module-begin form ...)
                                   'module-begin
                                   null))])
       #'(#%module-begin (instrument e-form #:nt) ...))]))

(define-syntax (instrumenting-top-interaction stx)
  (syntax-case stx ()
    [(instrumenting-top-interaction . e)
     (let ([estx (local-expand #'(#%top-interaction . e) 'top-level #f)])
       (syntax-case estx (begin)
         [(begin form ...)
          #'(begin (instrumenting-top-interaction . form) ...)]
         [form
          (with-syntax ([e-form
                         (analyze
                          (local-expand #'form 'top-level null))])
            #'(instrument e-form #:nt))]))]))

(define-syntax (begin-instrumented stx)
  (syntax-case stx ()
    [(begin-instrumented form ...)
     #'(instrument/local-expand (begin form ...))]))

(define-syntax (instrument/local-expand stx)
  (syntax-case stx ()
    [(instrument/local-expand form)
     (case (syntax-local-context)
       [(expression)
        (with-syntax ([e-form (analyze (local-expand #'form 'expression null))])
          #'(instrument e-form #:nt))]
       [else ;; module, top-level
        (let ([e-form (local-expand #'form 'module #f)])
          (syntax-parse e-form
            #:literal-sets (kernel-literals)
            [(define-values ids rhs)
             #'(define-values ids (instrument/local-expand rhs))]
            [(define-syntaxes . _) e-form]
            [(#%require . _) e-form]
            [(#%provide . _) e-form]
            [(#%declare . _) e-form]
            [(module . _) e-form]
            [(module* . _) e-form]
            [(begin form ...)
             #'(begin (instrument/local-expand form) ...)]
            [expr
             #'(#%expression (instrument/local-expand expr))]))])]))

;; (instrument expanded-form Mode)
;; where Mode is one of:
;;    #:cc - in observing context wrt enclosing lambda
;;    #:nt - not in observing context wrt enclosing lambda -- so must ignore OBS!
(define-syntax (instrument stx0)
  (syntax-parse stx0
    [(instrument form-to-instrument m)
     (define stx (syntax-disarm #'form-to-instrument stx-insp))
     (define instrumented
       (syntax-parse stx
         #:literal-sets (kernel-literals)
         ;; Fully-Expanded Programs
         ;; Rewrite applications
         [(#%plain-app) stx]
         [(#%plain-app f e ...)
          #`(instrument-app m #,stx)]
         ;; -- module body
         [(#%plain-module-begin form ...)
          #'(#%plain-module-begin (instrument form #:nt) ...)]
         ;; -- module-level form
         [(#%provide . _) stx]
         [(begin-for-syntax . _) stx]
         [(module . _) stx]
         [(module* . _)
          (raise-syntax-error #f "submodule not allowed within `#lang gamble' module" stx)]
         [(#%declare . _) stx]
         ;; -- general top-level form
         [(define-values ids e)
          #`(instrument-definition #,stx)]
         [(define-syntaxes . _) stx]
         [(#%require . _) stx]
         ;; -- expr
         [var:id #'var]
         [(#%plain-lambda formals e ... e*)
          (cond [(lam-cond-ctx? stx)
                 #'(#%plain-lambda formals
                     (call-with-immediate-continuation-mark OBS-mark
                       (lambda (obs)
                         (with ([OBS obs] [ADDR (ADDR-mark)])
                           (instrument e #:nt) ... (instrument e* #:cc)))))]
                [else
                 (log-instr-info "NON-CC lambda: ~s: ~a"
                                 (TAG stx) (syntax-summary stx))
                 #'(#%plain-lambda formals
                     (with ([OBS #f] [ADDR (ADDR-mark)])
                       (instrument e #:nt) ... (instrument e* #:nt)))])]
         [(case-lambda [formals e ... e*] ...)
          (cond [(lam-cond-ctx? stx)
                 #'(case-lambda
                     [formals
                      (call-with-immediate-continuation-mark OBS-mark
                        (lambda (obs)
                          (with ([OBS obs] [ADDR (ADDR-mark)])
                            (instrument e #:nt) ... (instrument e* #:cc))))]
                     ...)]
                [else
                 (log-instr-info "NON-CC case-lambda: ~s: ~a"
                                 (TAG stx) (syntax-summary stx))
                 #'(case-lambda
                     [formals
                      (with ([OBS #f] [ADDR (ADDR-mark)])
                        (instrument e #:nt) ... (instrument e* #:nt))]
                     ...)])]
         [(if e1 e2 e3)
          #'(if (instrument e1 #:nt)
                (instrument e2 m)
                (instrument e3 m))]
         [(begin e ... e*)
          #'(begin (instrument e #:nt) ...
                   (instrument e* m))]
         [(begin0 e0 e ...)
          #'(begin0 (instrument e0 m) (instrument e #:nt) ...)]
         [(let-values ([vars rhs] ...) body ... body*)
          ;; HACK: okay to turn let-values into intdef (letrec) because
          ;; already expanded, thus "alpha-renamed", so no risk of capture
          #'(let ()
              (instrument (define-values vars rhs) #:nt) ...
              (#%expression (instrument body #:nt)) ...
              (#%expression (instrument body* m)))]
         [(letrec-values ([vars rhs] ...) body ... body*)
          #'(let ()
              (instrument (define-values vars rhs) #:nt) ...
              (#%expression (instrument body #:nt)) ...
              (#%expression (instrument body* m)))]
         [(letrec-syntaxes+values ([svars srhs] ...) ([vvars vrhs] ...) body ... body*)
          #'(let ()
              (define-syntaxes svars srhs) ...
              (instrument (define-values vvars vrhs) #:nt) ...
              (#%expression (instrument body #:nt)) ...
              (#%expression (instrument body* m)))]
         [(set! var e)
          ;; (eprintf "** set! in expanded code: ~e" (syntax->datum stx))
          #'(set! var (instrument e #:nt))]
         [(quote d) stx]
         [(quote-syntax s) stx]
         [(with-continuation-mark e1 e2 e3)
          #'(with-continuation-mark (instrument e1 #:nt) (instrument e2 #:nt)
              (instrument e3 m))]
         ;; #%plain-app -- see above
         [(#%top . _) stx]
         [(#%variable-reference . _) stx]
         [(#%expression e)
          #'(#%expression (instrument e m))]
         [_ (raise-syntax-error #f "unhandled syntax in instrument" stx)]
         ))
     ;; Rearm and track result
     (let ([instrumented (relocate instrumented #'form-to-instrument)])
       (syntax-rearm (if (eq? stx instrumented)
                         stx
                         (syntax-track-origin instrumented stx #'instrument))
                     #'form-to-instrument))]))

(begin-for-syntax
  (define (relocate stx loc-stx)
    (if (identifier? stx)
        stx
        (datum->syntax stx (syntax-e stx) loc-stx stx))))

;; ----

(define-syntax (instrument-definition idstx)
  (syntax-parse idstx
    #:literals (define-values)
    [(_ (define-values (var:id) e))
     (syntax-parse (syntax-disarm #'e stx-insp)
       #:literals (#%plain-lambda case-lambda)
       ;; FIXME: handle rest args
       [(#%plain-lambda (arg ...) body ... body*)
        #'(define/instr-protocol (var arg ...)
            (instrument body #:nt) ...
            (instrument body* #:cc))]
       [(case-lambda [(arg ...) body ... body*] ...)
        #'(define/instr-protocol var
            (case-lambda
              [(arg ...)
               (instrument body #:nt) ...
               (instrument body* #:cc)]
              ...))]
       [_
        #'(define-values (var) (instrument e #:nt))])]
    [(_ (define-values vars e))
     #'(define-values vars (instrument e #:nt))]))

;; ------------------------------------------------------------

;; App needs to do 2 transformations
;;  - address-tracking (unless "safe" function)
;;  - conditioning-tracking (if conditionable AND tail wrt conditioning context)
;; Conditionable functions are a subset of safe functions,
;; so split that way.

(begin-for-syntax
  (define (add-app-tooltip! ttb stx msg)
    (when stx
      (define pos (syntax-position stx))
      (define span (syntax-span stx))
      (define tt
        (and pos span
             ;; offset positions by -1 to work around DrRacket bug (?)
             (vector stx (+ pos -1) (+ pos span -1) (string-append "* " msg))))
      ;; (log-instr-info "tooltip(~s) for ~s" (if (syntax-original? stx) 'Y 'N) stx)
      (when tt (set-box! ttb (cons tt (unbox ttb)))))))

(define-syntax (instrument-app iastx)
  (define stx (syntax-case iastx () [(_ m stx) #'stx]))
  (define f-stx (syntax-case stx (#%plain-app) [(#%plain-app f . _) #'f]))
  (define f-orig-id
    (syntax-parse stx
      #:literals (#%plain-app)
      [(#%plain-app f:contract-indirection-id _ ...)
       (or (for/or ([origin-id (in-list (syntax-property stx 'origin))])
             (and (identifier? origin-id)
                  (free-identifier=? origin-id #'f.c)
                  origin-id))
           #'f)]
      [(#%plain-app f:id arg ...) #'f]
      [_ #f]))
  (define tooltips (box null))
  (define (log-app-type msg)
    (log-instr-info (format "~a for ~s" msg f-stx)))
  (define (tt-fun-type! msg)
    (add-app-tooltip! tooltips f-orig-id msg))
  (unless (eq? f-stx f-orig-id)
    (log-instr-info (format "original of ~s is ~s" f-stx f-orig-id)))
  (check-app stx)
  (add-app-tooltip! tooltips f-orig-id
    (syntax-case iastx ()
      [(_ #:nt _) "call NOT in observation context"]
      [(_ #:cc _) "call in observation context wrt enclosing lambda"]))
  (define result
    (syntax-parse iastx
      #:literals (#%plain-app)

      ;; Conditionable primitives in conditionable context
      ;; All non-random first-order, so no need for address tracking.

      [(_ #:cc (#%plain-app op:final-arg-prop-fun e ... eFinal))
       (log-app-type "OBS PROP app (final arg)")
       (tt-fun-type! "function propagates observation to final argument")
       (with-syntax ([(tmp ...) (generate-temporaries #'(e ...))])
         #'(let-values ([(tmp) (instrument e #:nt)] ...)
             (#%plain-app op tmp ...
               (with ([OBS
                       (if OBS
                           (let ([obs-v (observation-value OBS)])
                             (if (op.pred obs-v tmp ...)
                                 (let* ([x (op.inverter obs-v tmp ...)]
                                        [scale (op.scaler x tmp ...)])
                                   (observation x (* (observation-scale OBS) scale)))
                                 (fail 'observe-failed-invert)))
                           #f)])
                     (instrument eFinal #:cc)))))]

      ;; contracted
      [(_ #:cc (#%plain-app op:contracted-final-arg-prop-fun ctc-info e ... eFinal))
       (log-app-type "OBS PROP app (contracted, final arg)")
       (tt-fun-type! "function propagates observation to final argument")
       (with-syntax ([(tmp ...) (generate-temporaries #'(e ...))])
         #'(let-values ([(tmp) (instrument e #:nt)] ...)
             (#%plain-app op ctc-info tmp ...
               (with ([OBS
                       (if OBS
                           (let ([obs-v (observation-value OBS)])
                             (if (op.pred obs-v tmp ...)
                                 (let* ([x (op.inverter obs-v tmp ...)]
                                        [scale (op.scaler x tmp ...)])
                                   (observation x (* (observation-scale OBS) scale)))
                                 (fail 'observe-failed-invert)))
                           #f)])
                     (instrument eFinal #:cc)))))]

      ;; lifted contracted (w/o ctc-info arg)
      [(_ #:cc (#%plain-app op:lifted-contracted-final-arg-prop-fun e ... eFinal))
       (log-app-type "OBS PROP app (lifted contracted, final arg)")
       (tt-fun-type! "function propagates observation to final argument")
       (with-syntax ([(tmp ...) (generate-temporaries #'(e ...))])
         #'(let-values ([(tmp) (instrument e #:nt)] ...)
             (#%plain-app op tmp ...
               (with ([OBS
                       (if OBS
                           (let ([obs-v (observation-value OBS)])
                             (if (op.pred obs-v tmp ...)
                                 (let* ([x (op.inverter obs-v tmp ...)]
                                        [scale (op.scaler x tmp ...)])
                                   (observation x (* (observation-scale OBS) scale)))
                                 (fail 'observe-failed-invert)))
                           #f)])
                     (instrument eFinal #:cc)))))]

      [(_ #:cc (#%plain-app op:all-args-prop-fun e ...))
       (log-app-type "OBS PROP app (all args)")
       (tt-fun-type! "function propagates observation to all arguments (constructor)")
       #'(#%plain-app op
           (with ([OBS
                   (if OBS
                       (let ([obs-v (observation-value OBS)])
                         (if (op.pred obs-v) ;; FIXME: redundant for 2nd arg on
                             (let ([x (op.inverter (observation-value OBS))])
                               (observation x (observation-scale OBS)))
                             (fail 'observe-failed-invert)))
                       #f)])
                 (instrument e #:cc))
           ...)]
      [(_ #:cc (#%plain-app (~literal list) e ...))
       (log-app-type "OBS PROP app (desugar list)")
       (tt-fun-type! "function propagates observation to all arguments (constructor)")
       (with-syntax ([unfolded-expr
                      (let loop ([es (syntax->list #'(e ...))])
                        (cond [(pair? es)
                               #`(#%plain-app cons #,(car es) #,(loop (cdr es)))]
                              [else
                               #'(quote ())]))])
         #'(instrument unfolded-expr #:cc))]

      ;; Non-conditionable-primitives in conditionable context

      ;; * non-random first-order non-instrumented
      ;;   Doesn't need address tracking, doesn't need observation
      [(_ #:cc (#%plain-app f:nrfo-fun e ...))
       (log-app-type "STATIC app (NRFO)")
       (tt-fun-type! "non-random first-order function (cannot observe)")
       ;; FIXME: error if OBS != #f
       #'(#%plain-app f (instrument e #:nt) ...)]
      ;; * analysis says doesn't call ERP (superset of prev case)
      ;;   Doesn't need address tracking, doesn't need observation
      [(_ #:cc (#%plain-app f:id e ...))
       #:when (not (app-calls-erp? stx))
       (log-app-type "STATIC app (!APP-CALLS-ERP)")
       (tt-fun-type! "analyzed non-random function (cannot observe)")
       ;; FIXME: error if OBS != #f
       #'(#%plain-app f (instrument e #:nt) ...)]
      ;; * instrumented function with right arity
      ;;   Use static protocol
      [(_ #:cc (#%plain-app f:instr-fun e ...))
       #:when (member (length (syntax->list #'(e ...))) (attribute f.arity))
       (log-app-type "STATIC app (instrumented)")
       (tt-fun-type! "instrumented function")
       (with-syntax ([c (lift-call-site stx)]
                     [f-instr (syntax-property #'f.instr 'disappeared-use #'f)])
         #'(#%plain-app f-instr (cons c ADDR) OBS (instrument e #:nt) ...))]
      ;; * unknown, function is varref
      ;;   Use dynamic protocol
      [(_ #:cc (#%plain-app f:id e ...))
       (log-app-type "DYNAMIC app")
       (tt-fun-type! "uninstrumented function (passing address and observation dynamically)")
       (with-syntax ([c (lift-call-site stx)]
                     [(tmp ...) (generate-temporaries #'(e ...))])
         #'(let-values ([(tmp) (instrument e #:nt)] ...)
             (with-continuation-mark ADDR-mark (cons c ADDR)
               (with-continuation-mark OBS-mark OBS
                 (#%plain-app f tmp ...)))))]
      ;; * unknown, function is expr
      ;;   Use dynamic protocol
      [(_ #:cc (#%plain-app e ...))
       (with-syntax ([c (lift-call-site stx)]
                     [(tmp ...) (generate-temporaries #'(e ...))])
         #'(let-values ([(tmp) (instrument e #:nt)] ...)
             (with-continuation-mark ADDR-mark (cons c ADDR)
               (with-continuation-mark OBS-mark OBS
                 (#%plain-app tmp ...)))))]

      ;; Non-conditionable context

      ;; * non-random first-order non-instrumented
      ;;   Doesn't need address, doesn't need observation
      [(_ #:nt (#%plain-app f:nrfo-fun e ...))
       (log-app-type "STATIC app (NRFO)")
       (tt-fun-type! "non-random first-order function")
       #'(#%plain-app f (instrument e #:nt) ...)]
      ;; * analysis says doesn't call ERP (superset of prev case)
      ;;   Doesn't need address tracking, doesn't need observation
      [(_ #:nt (#%plain-app f:id e ...))
       #:when (not (app-calls-erp? stx))
       (log-app-type "STATIC app (!APP-CALLS-ERP)")
       (tt-fun-type! "analyzed non-random function (not passing address)")
       #'(#%plain-app f (instrument e #:nt) ...)]
      ;; * instrumented function with right arity
      ;;   Use static protocol
      [(_ #:nt (#%plain-app f:instr-fun e ...))
       #:when (member (length (syntax->list #'(e ...))) (attribute f.arity))
       (log-app-type "STATIC app (instrumented)")
       (tt-fun-type! "instrumented function")
       (with-syntax ([c (lift-call-site stx)]
                     [f-instr (syntax-property #'f.instr 'disappeared-use #'f)])
         #'(#%plain-app f-instr (cons c ADDR) #f (instrument e #:nt) ...))]
      ;; * unknown, function is varref
      ;;   Use dynamic protocol
      [(_ #:nt (#%plain-app f:id e ...))
       (log-app-type "DYNAMIC app")
       (tt-fun-type! "uninstrumented function (passing address dynamically)")
       (with-syntax ([c (lift-call-site stx)]
                     [(tmp ...) (generate-temporaries #'(e ...))])
         #'(let-values ([(tmp) (instrument e #:nt)] ...)
             (with-continuation-mark ADDR-mark (cons c ADDR)
               (with-continuation-mark OBS-mark #f
                 (#%plain-app f tmp ...)))))]
      ;; * unknown, function is expr
      ;;   Use dynamic protocol
      [(_ #:nt (#%plain-app e ...))
       (with-syntax ([c (lift-call-site stx)]
                     [(tmp ...) (generate-temporaries #'(e ...))])
         #'(let-values ([(tmp) (instrument e #:nt)] ...)
             (with-continuation-mark ADDR-mark (cons c ADDR)
               (with-continuation-mark OBS-mark #f
                 (#%plain-app tmp ...)))))]))
  (syntax-property result
                   'mouse-over-tooltips
                   (unbox tooltips)))


(begin-for-syntax
  ;; check-app : Syntax -> Void
  ;; Check constraints on applications; currently, just that observe* is
  ;; called with observable function (OBS-LAM).
  (define (check-app stx)
    (syntax-parse stx
      #:literals (#%plain-app observe*)
      [(#%plain-app observe* thunk expected)
       (unless (OBS-LAM #'thunk)
         (define observe-form (syntax-property #'thunk 'observe-form))
         (syntax-case observe-form ()
           [(_ e v)
            (raise-syntax-error #f NOT-OBSERVABLE-MESSAGE observe-form #'e)]
           [_
            (raise-syntax-error 'observe NOT-OBSERVABLE-MESSAGE stx)]))]
      [_ (void)]))

  (define NOT-OBSERVABLE-MESSAGE
    (string-append "expression is not observable"
                   ";\n it does not sample in an observable context")))
