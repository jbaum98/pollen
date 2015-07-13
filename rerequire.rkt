#lang racket/base
#|
This is the rerequire.rkt. from the Racket 6.2.0.3 distribution.
`dynamic-rerequire` was improved after 6.0 to return a list of updated files.
So this makes the better version available, while keeping Pollen compatible with 6.0.
In general this is not a superb strategy but this module is largely independent,
and Pollen uses a ton of `dynamic-rerequire`.
|#

(require syntax/modcode)
(require sugar/debug)

(provide dynamic-rerequire)

(define (dynamic-rerequire mod #:verbosity [verbosity 'reload])
  (unless (module-path? mod)
    (raise-argument-error 'dynamic-rerequire "module-path?" mod))
  (unless (memq verbosity '(all reload none))
    (raise-argument-error 'dynamic-rerequire "(or/c 'all 'reload 'none)" verbosity))
  (rerequire mod verbosity))

(struct mod (name timestamp depends) #:transparent)

(define loaded (make-hash))

(define (rerequire mod verbosity)
  (define loaded-paths '())
  (define (collect-loaded-path! path) (set! loaded-paths (cons path loaded-paths)))
  ;; Collect dependencies while loading:
  (parameterize ([current-load/use-compiled
                  (rerequire-load/use-compiled (current-load/use-compiled)
                                               #f verbosity collect-loaded-path!)])
    (dynamic-require mod 0))
  ;; Reload anything that's not up to date:
  (check-latest mod verbosity collect-loaded-path!)
  ;; Return a list of the paths that were loaded this time, in order:
  (reverse loaded-paths))

(define (rerequire-load/use-compiled orig re? verbosity path-collector)
  (define notify
    (if (or (eq? 'all verbosity) (and re? (eq? 'reload verbosity)))
        (λ(path)
          (eprintf "~aloading ~a from source\n" (if re? "re" "") path)
          (path-collector path))
        path-collector))
  (λ(path name)
    (report path 'path-being-loaded)
    (if (and name
             (not (and (pair? name)
                       (not (car name)))))
        ;; Module load:
        (with-handlers ([(λ(exn)
                           (and (pair? name)
                                (exn:get-module-code? exn)))
                         (λ(exn) 
                           ;; Load-handler protocol: quiet failure when a
                           ;; submodule is not found
                           (void))])
          (let* ([code (get-module-code
                        path "compiled"
                        (λ(e)
                          (parameterize ([compile-enforce-module-constants #f])
                            (compile e)))
                        (λ(ext loader?) (load-extension ext) #f)
                        #:notify notify)]
                 [dir  (or (current-load-relative-directory) (current-directory))]
                 [path (path->complete-path path dir)]
                 [path (normal-case-path (simplify-path path))])
            ;; Record module timestamp and dependencies:
            (define-values (ts actual-path) (get-timestamp path))
            (let ([a-mod (mod name
                              ts
                              (if code
                                  (apply append 
                                         (map cdr (module-compiled-imports code)))
                                  null))])
              (hash-set! loaded path a-mod))
            ;; Evaluate the module:
            (parameterize ([current-module-declare-source actual-path])
              (eval code))))
        ;; Not a module, or a submodule that we shouldn't load from source:
        (begin (notify path) (orig path name)))))

(define (get-timestamp path)
  (let ([ts (file-or-directory-modify-seconds path #f (λ _ #f))])
    (if ts
        (values ts path)
        (if (regexp-match? #rx#"[.]rkt$" (path->bytes path))
            (let* ([alt-path (path-replace-suffix path #".ss")]
                   [ts (file-or-directory-modify-seconds alt-path #f (λ _ #f))])
              (if ts
                  (values ts alt-path)
                  (values -inf.0 path)))
            (values -inf.0 path)))))

(define submodule-path? list?)
(require describe)

(define (check-latest mod verbosity path-collector)
  (report loaded)
  (define mpi (module-path-index-join mod #f))
  (define done (make-hash))
  (let loop ([mpi mpi])
    (define rpath (module-path-index-resolve mpi))
    (define path-or-submodule-path (resolved-module-path-name rpath))
    (cond
      [(path? path-or-submodule-path)
       (define path (normal-case-path path-or-submodule-path))
       (unless (hash-ref done path #f)
         (hash-set! done path #t)
         (define mod (hash-ref loaded path #f))
         (when mod
           (for-each loop (mod-depends mod))
           (define-values (last-timestamp actual-path) (get-timestamp path))
           (when (last-timestamp . > . (mod-timestamp mod))
             (define orig (current-load/use-compiled))
             (parameterize ([current-load/use-compiled
                             (rerequire-load/use-compiled orig #f verbosity path-collector)]
                            [current-module-declare-name rpath]
                            [current-module-declare-source actual-path])
               ((rerequire-load/use-compiled orig #t verbosity path-collector)
                path (mod-name mod))))))]
      [(submodule-path? path-or-submodule-path)
       (define submodule-path path-or-submodule-path)
       #;(loop (module-path-index-join #f #f submodule-path))
       (void)])))