open! Base
module F = Duckdb_ffi
module N = F.Native_request

let check label condition = if not condition then failwith label
let installed = function N.Installed -> true | _ -> false
let used = function N.Request_used -> true | _ -> false
let detached = function N.Uninstalled -> true | _ -> false
let disposed = function Ok () -> true | Error N.Still_installed -> false
let close_database database =
  Exn.protect ~f:(fun () -> F.close_database database)
    ~finally:(fun () -> F.finish_database_close database)
let close_connection connection =
  Exn.protect ~f:(fun () -> F.close_connection connection)
    ~finally:(fun () -> F.finish_connection_close connection)
let open_database () =
  let database = F.database_owner () in
  F.open_database database "" 1 0 false;
  check "database opens" (F.database_status database = 0);
  database
let connect database =
  let connection = F.connection_owner database in
  F.connect connection;
  check "connection opens" (F.connection_status connection = 0);
  connection
let with_database f =
  let database = open_database () in
  Exn.protect ~f:(fun () -> f database) ~finally:(fun () -> close_database database)
let with_connection database f =
  let connection = connect database in
  Exn.protect ~f:(fun () -> f connection) ~finally:(fun () -> close_connection connection)

let ineligible request =
  check "USER disabled: reserve ineligible"
    (match N.reserve_delivery request with N.Ineligible -> true | _ -> false);
  check "delivery requires reservation"
    (match N.try_interrupt request with N.Not_reserved -> true | _ -> false);
  N.retire_delivery request;
  N.retire_delivery request

let tombstone connection request =
  N.cancel request; N.cancel request;
  ineligible request;
  check "disposed install rejected" (used (N.try_install connection request));
  check "disposed uninstall rejected"
    (match N.try_uninstall request with N.Not_installed -> true | _ -> false);
  check "dispose idempotent" (disposed (N.dispose request))

let single_binding () =
  with_database (fun database ->
    with_connection database (fun a ->
      with_connection database (fun b ->
        let request = N.create () in
        let fresh = N.create () in
        check "first install" (installed (N.try_install a request));
        check "same request on two connections rejected" (used (N.try_install b request));
        check "same request on same connection rejected" (used (N.try_install a request));
        check "other fresh request sees leased connection"
          (match N.try_install a fresh with N.Connection_leased -> true | _ -> false);
        check "detach" (detached (N.try_uninstall request));
        check "reinstall after detach rejected" (used (N.try_install a request));
        check "fresh request reuses connection" (installed (N.try_install a fresh));
        check "fresh detach" (detached (N.try_uninstall fresh));
        check "dispose first" (disposed (N.dispose request));
        check "dispose fresh" (disposed (N.dispose fresh));
        tombstone a request; tombstone a fresh)));
  check "single binding restores counters without forced GC" (F.live_resources () = 0)

let preallocated_installation () =
  with_database (fun database ->
    with_connection database (fun connection ->
      let request = N.create () in
      let installation = N.prepare_install connection request in
      let alias = installation in
      check "preallocated install" (installed (N.try_install_prepared installation));
      check "preallocated alias single use" (used (N.try_install_prepared alias));
      check "preallocated detach" (detached (N.try_uninstall request));
      check "preallocated alias cannot reinstall" (used (N.try_install_prepared alias));
      check "preallocated dispose" (disposed (N.dispose request));
      check "preallocated alias respects tombstone" (used (N.try_install_prepared alias))));
  check "preallocated installation deterministic reclamation" (F.live_resources () = 0)

let lifecycle () =
  with_database (fun database ->
    with_connection database (fun connection ->
      let baseline = F.live_resources () in
      let request = N.create () in
      let alias = request in
      check "request counted" (F.live_resources () = baseline + 1);
      N.cancel request; N.cancel alias;
      ineligible request;
      check "fresh uninstall"
        (match N.try_uninstall request with N.Not_installed -> true | _ -> false);
      check "install cancelled request" (installed (N.try_install connection request));
      check "installed disposal refused"
        (match N.dispose alias with Error N.Still_installed -> true | Ok () -> false);
      ineligible alias;
      N.cancel alias;
      check "uninstall cancelled request" (detached (N.try_uninstall alias));
      check "repeat uninstall"
        (match N.try_uninstall request with N.Not_installed -> true | _ -> false);
      ineligible request;
      check "dispose detached" (disposed (N.dispose alias));
      check "explicit disposal restores native counters without GC" (F.live_resources () = baseline);
      tombstone connection request;
      let fresh = N.create () in
      check "dispose never installed" (disposed (N.dispose fresh));
      tombstone connection fresh;
      let closed = F.connection_owner database in
      let retry = N.create () in
      check "empty connection rejected"
        (match N.try_install closed retry with N.Connection_closed -> true | _ -> false);
      close_connection closed;
      check "released slot rejected"
        (match N.try_install closed retry with N.Connection_closed -> true | _ -> false);
      check "failed install stays fresh" (installed (N.try_install connection retry));
      check "retry detach" (detached (N.try_uninstall retry));
      check "retry dispose" (disposed (N.dispose retry))));
  check "lifecycle counters zero" (F.live_resources () = 0)

exception Callback_failure
let exception_cleanup () =
  with_database (fun database ->
    with_connection database (fun connection ->
      let request = N.create () in
      check "exception install" (installed (N.try_install connection request));
      (try
         Exn.protect
           ~f:(fun () -> N.cancel request; raise Callback_failure)
           ~finally:(fun () ->
             check "exception detach" (detached (N.try_uninstall request));
             check "exception dispose" (disposed (N.dispose request)))
       with Callback_failure -> ());
      tombstone connection request));
  check "exception restores counters without forced GC" (F.live_resources () = 0)

let collect () =
  Stdlib.Gc.full_major (); Stdlib.Gc.full_major (); Stdlib.Gc.full_major ()

(* The only remaining ML connection root is inside the bound request. *)
let[@inline never] rooted_request database =
  let connection = connect database in
  let weak = Stdlib.Weak.create 1 in
  Stdlib.Weak.set weak 0 (Some connection);
  let request = N.create () in
  check "root install" (installed (N.try_install connection request));
  request, weak

let root_lifetime () =
  with_database (fun database ->
    let request, weak = rooted_request database in
    let before = F.fallback_reclaims () in
    collect ();
    check "bound request retains ML connection root" (Stdlib.Weak.check weak 0);
    check "no owner fallback while request live" (F.fallback_reclaims () = before);
    check "root detach" (detached (N.try_uninstall request));
    check "root dispose" (disposed (N.dispose request));
    collect ();
    check "detach releases ML root" (not (Stdlib.Weak.check weak 0)));
  collect ();
  check "root lifetime counters zero" (F.live_resources () = 0)

let[@inline never] abandon_request connection =
  let request = N.create () in
  check "abandon install" (installed (N.try_install connection request));
  N.cancel request

let[@inline never] abandon_tree () =
  let database = open_database () in
  let connection = connect database in
  abandon_request connection

let[@inline never] child_last () =
  let database = open_database () in
  let connection = connect database in
  let child = F.prepared_owner connection in
  abandon_request connection;
  child

let abandonment () =
  with_database (fun database ->
    with_connection database (fun connection ->
      let baseline = F.live_resources () in
      let before = F.fallback_reclaims () in
      abandon_request connection;
      collect ();
      check "idle abandoned installation reclaimed" (F.live_resources () = baseline);
      check "request fallback counted separately" (F.fallback_reclaims () > before);
      let fresh = N.create () in
      check "request-first fallback clears owner pointer" (installed (N.try_install connection fresh));
      check "fallback reuse detach" (detached (N.try_uninstall fresh));
      check "fallback reuse dispose" (disposed (N.dispose fresh))));
  abandon_tree ();
  collect ();
  check "whole idle tree abandonment reclaimed" (F.live_resources () = 0);
  let child = child_last () in
  collect ();
  check "child retains native owner tree" (F.live_resources () > 0);
  F.close_prepared child;
  F.finish_prepared_close child;
  check "child-last native unref reclaims tree" (F.live_resources () = 0)

let () =
  let fallback = F.fallback_reclaims () in
  single_binding (); preallocated_installation (); lifecycle (); exception_cleanup ();
  check "deterministic cases need no fallback" (F.fallback_reclaims () = fallback);
  Stdlib.print_endline "native lifecycle: single binding, aliases, deterministic disposal/exception cleanup passed";
  root_lifetime (); abandonment ();
  Stdlib.print_endline "native lifecycle: ML root retention and separate idle GC fallback passed; USER disabled"
