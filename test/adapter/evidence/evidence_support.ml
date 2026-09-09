open! Base

type failure = { exception_ : exn; backtrace : Stdlib.Printexc.raw_backtrace }
exception Multiple_failures of failure * failure
type 'a outcome = Returned of 'a | Raised of failure
let capture f =
  try Returned (f ()) with exception_ ->
    let backtrace = Stdlib.Printexc.get_raw_backtrace () in
    Raised { exception_; backtrace }
let restore = function
  | Returned value -> value
  | Raised { exception_; backtrace } -> Stdlib.Printexc.raise_with_backtrace exception_ backtrace

type 'a settlement = { primary : 'a outcome; cleanup : unit outcome }
let settle work ~cleanup =
  let primary = capture work in
  let cleanup = capture cleanup in
  { primary; cleanup }

let await ~label predicate =
  let start = Mtime_clock.counter () in
  while not (predicate ()) do
    if Float.(Mtime.Span.to_float_ns (Mtime_clock.count start) > 10_000_000_000.)
    then failwith ("handshake deadline: " ^ label);
    Thread.delay 0.001
  done

let with_worker work ~f =
  let outcome = Stdlib.Atomic.make None in
  let worker = Thread.create (fun () -> Stdlib.Atomic.set outcome (Some (capture work))) () in
  let joined = ref None in
  let observed = ref false in
  let join () =
    let result = match !joined with
      | Some result -> result
      | None ->
        let deadline = capture (fun () ->
          await ~label:"worker completion before join" (fun () -> Option.is_some (Stdlib.Atomic.get outcome))) in
        (* Mandatory even after deadline failure: there is no bounded Thread.join.
           The executable timeout is the explicit process-level failure bound. *)
        Thread.join worker;
        let worker_result = Option.value_exn (Stdlib.Atomic.get outcome) in
        let result = match deadline, worker_result with
          | Returned (), result -> result
          | Raised failure, Returned _ -> Raised failure
          | Raised primary, Raised cleanup ->
            Raised { primary with exception_ = Multiple_failures (primary, cleanup) } in
        joined := Some result;
        result in
    observed := true;
    restore result in
  let body = capture (fun () -> f join) in
  let cleanup = capture (fun () -> if not !observed then ignore (join ())) in
  match body, cleanup with
  | Returned value, Returned () -> value
  | Raised failure, Returned () | Returned _, Raised failure -> restore (Raised failure)
  | Raised primary, Raised cleanup -> raise (Multiple_failures (primary, cleanup))
