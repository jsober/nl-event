;; @module libevent
;; @description Low-level newlisp bindings for libevent2.
;; @version 0.1
;; @author Jeff Ober <jeffober@gmail.com>
;;
;; The libevent module provides a thin wrapper on top of the
;; @link http://libevent.org/ libevent2 library.
;;
;; TODO
;; <ul>
;;   <li>signals</li>
;;   <li>io buffers</li>
;; </ul>
;;
;; @example
;; (load "libevent2.lsp")
;; (libevent:init)
;;
;; ; Timers
;; (libevent:set-interval 10
;;   (fn () (println "Another 10ms have passed!")))
;;
;; ; IO
;; (setf socket (net-connect "www.google.com" 80))
;; (setf buffer "")
;;
;; ; Wait until socket is write-ready
;; (libevent:watch-once socket libevent:WRITE
;;   (fn (fd e id)
;;     ; send HTTP request
;;     (write socket "GET / HTTP/1.0\r\n\r\n")
;;
;;     ; wait for response
;;     (libevent:watch socket libevent:READ
;;       (fn (fd e id , buf bytes)
;;         ; read to local buffer
;;         (setf bytes (read fd buf 4096))
;;         (if bytes
;;           ; write to global buffer
;;           (write buffer buf)
;;           ; kill watcher and stop loop
;;           (begin
;;             (libevent:unwatch id)
;;             (libevent:stop)))))))
;;
;; ; start event loop
;; (libevent:run)
;;
;; ; print results
;; (println (length buffer) " bytes received")

(define EventCB:EventCB)
(define EventID:EventID)

(context 'libevent)

(struct 'TIMEVAL "int" "long")

;-------------------------------------------------------------------------------
; Constants (from event.h)
;-------------------------------------------------------------------------------
(constant 'TIMEOUT   0x01)
(constant 'READ      0x02)
(constant 'WRITE     0x04)
(constant 'SIGNAL    0x08)
(constant 'PERSIST   0x10)
(constant 'LOOP_ONCE 0x01)

;-------------------------------------------------------------------------------
; Locate libevent library
;-------------------------------------------------------------------------------
(constant 'LIB
  (cond
    ((= ostype "Win32") "libevent.dll")
    ((= ostype "OSX")   "libevent.dylib")
    (true               "libevent.so")))

(unless (import LIB)
  (throw-error "libevent not found"))

;-------------------------------------------------------------------------------
; Import libevent routines
;-------------------------------------------------------------------------------
(import LIB "event_enable_debug_mode")
(import LIB "event_base_new" "void*")
(import LIB "event_base_free" "void" "void*")
(import LIB "event_base_loop" "int" "void*" "int")
(import LIB "event_base_dispatch" "int" "void*")
(import LIB "event_base_loopbreak" "int" "void*")
(import LIB "event_new" "void*" "void*" "int" "short int" "void*" "void*")
(import LIB "event_free" "void" "void*")
(import LIB "event_add" "int" "void*" "void*")
(import LIB "event_del" "int" "void*")

(when MAIN:LIBEVENT2_DEBUG
  (event_enable_debug_mode))

;-------------------------------------------------------------------------------
; Loop control
;-------------------------------------------------------------------------------
(setf BASE nil)
(setf RUNNING nil)

;; @syntax (init)
;; Initializes the event loop. Will not re-init a previously initialized
;; loop unless <cleanup> is called first.
(define (init)
  (or BASE
      (not (zero? (setf BASE (event_base_new))))
      (throw-error "Error initializing event loop")))

(define (assert-initialized)
  (or BASE (throw-error "Event loop is not initialized")))

(define (cleanup)
  "Cleans up memory used by the event loop."
  (when RUNNING (stop))
  (when BASE
    (event_base_free BASE)
    (setf BASE nil)))

;; @syntax (run)
;; Starts the event loop. Does not return until the loop is stopped.
(define (run)
  (setf RUNNING true)
  (case (event_base_dispatch BASE)
    (0  true)
    (1  (throw-error "No more events registered."))
    (-1 (throw-error "Unable to start loop."))))

(define (run-once , result)
  (setf RUNNING true)
  (setf result (event_base_loop BASE LOOP_ONCE))
  (setf RUNNING nil)
  (case result
    (0  true)
    (1  (throw-error "No more events registered."))
    (-1 (throw-error "Unable to start loop."))))


;; @syntax (stop)
;; Halts the event loop after the next iteration.
(define (stop)
  (unless (zero? (event_base_loopbreak BASE))
    (throw-error "Unable to halt event loop."))
  (setf RUNNING nil)
  (cleanup))

;-------------------------------------------------------------------------------
; Event callback triggering
;-------------------------------------------------------------------------------
(setf _id 0)
(define (event-id , id)
  (setf id (string "ev-" (inc _id)))
  (EventID id id) ; anchor in memory
  (list (EventID id) (address (EventID id))))

(define (trigger fd ev arg , id event cb)
  (setf id (get-string arg))
  (map set '(event cb) (EventCB id))
  (cb fd ev id)
  0)

(setf _event_cb (callback 'trigger "void" "int" "short int" "void*"))

(define (make-event fd ev cb once timeval, id event id-address)
  (assert-initialized)

  (unless once (setf ev (| ev PERSIST)))

  (map set '(id id-address) (event-id))
  (setf event (event_new BASE fd ev _event_cb id-address))
  (EventCB id (list event cb))

  (setf timeval
    (if timeval
      (pack TIMEVAL 0 (* 1000 timeval)) ; convert usec to msec
      0))

  (unless (zero? (event_add event (address timeval)))
    (throw-error "Error adding event"))

  id)

;-------------------------------------------------------------------------------
; Event registration
;-------------------------------------------------------------------------------
;; @syntax (watch <fd> <ev> <cb> <once>)
;; @param <int>  'fd'   An open file descriptor
;; @param <int>  'ev'   A bitmask of event constants
;; @param <fn>   'cb'   A callback function
;; @param <bool> 'once' When true (default false) callback is triggered only once
;; @return <int> id used to manage the event watcher
;; Registers callback function <cb> to be called whenever an event masked in
;; <ev> is triggered for <fd>. <cb> is called with the file descriptor,
;; event, and id as its arguments.
;;
;; @example
;; (watch socket (| READ WRITE)
;;   (fn (fd e)
;;     (cond
;;       (== e READ) (...)
;;       (== e WRITE) (...))))
(define (watch fd ev cb once , id event id-address)
  (assert-initialized)
  (make-event fd ev cb once))

;; @syntax (unwatch <id>)
;; @param <int> 'id' ID returned by <watch>
;; Unregisters an event watcher. Once unwatched, the watcher id is invalid
;; and may no longer be used.
;;
;; @example
;; (watch socket WRITE
;;   (lambda (fd e id)
;;     (unwatch id)
;;     (write fd "Hello world")))
(define (unwatch id , event cb)
  (assert-initialized)
  (map set '(event cb) (EventCB id))
  (event_del event)
  (event_free event))

;; @syntax (watch-once <fd> <ev> <cb>)
;; @param <int> 'fd' An open file descriptor
;; @param <int> 'ev' A bitmask of event constants
;; @param <fn>  'cb' A callback function
;; Registers a callback <cb> for events <ev> on descriptor <fd>. After the
;; callback is triggered, it is automatically unregistered for events <ev>.
;; For example, the example code from <unwatch> could be rewritten as:
;;
;; @example
;; (once socket WRITE
;;   (lambda (fd e)
;;     (write fd "Hello world")))
(define (watch-once fd ev cb)
  (watch fd ev cb true))

;-------------------------------------------------------------------------------
; Timers
;-------------------------------------------------------------------------------
;; @syntax (set-interval <msec> <cb>)
;; @param <int> 'msec' Millisecond interval
;; @param <fn>  'cb'   A callback function
;; @return <int> Returns the timer id
;; Registers a callback <cb> to be executed every <msec> milliseconds. Note
;; that the timing is not guaranteed; <cb> will be called on the first
;; iteration of the event loop after <msec> milliseconds have passed since its
;; last execution. Returns an event ID that may be used to clear the interval
;; event using <clear-interval>.
(define (set-interval msec cb)
  (assert-initialized)
  (make-event -1 (| 0 PERSIST) cb nil msec))

;; @syntax (clear-interval <id>)
;; @param <int> 'id' id of a timer event
;; Clears an interval id.
(define (clear-interval id)
  (unwatch id))

;; @syntax (set-timer <msec> <cb>)
;; @param <int> 'msec' Millisecond interval
;; @param <fn>  'cb'   A callback function
;; @return <int> Returns the timer id
;; Registers a callback <cb> to be executed one time after <msec> milliseconds.
(define (set-timer msec cb)
  (assert-initialized)
  (make-event -1 0 cb nil msec))

(context 'MAIN)
