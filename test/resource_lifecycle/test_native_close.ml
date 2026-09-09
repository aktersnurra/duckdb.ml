open! Base
module F = Duckdb_ffi
module N = F.Native_request
module E = Evidence_support
external reset : unit -> unit = "adapter_bridge_reset"
external disconnect_gate : bool -> unit = "adapter_bridge_disconnect_gate"
external disconnect_entered : unit -> bool = "adapter_bridge_disconnect_entered"
external execute_gate : int -> unit = "adapter_bridge_execute_gate"
external execute_entered : unit -> int = "adapter_bridge_execute_entered"
external release_fixture : unit -> unit = "lifecycle_release_fixture"
external contended_install : F.connection -> N.t -> N.install_result = "lifecycle_contended_install"
external boundary_gate : int -> unit = "lifecycle_boundary_gate"
external boundary_entered : unit -> int = "lifecycle_boundary_entered"
let check label condition = if not condition then failwith label
let dispose request = check "dispose" (match N.dispose request with Ok () -> true | Error _ -> false)
let fixture f =
  let database = F.database_owner () in
  F.open_database database "" 1 0 false;
  let connection = F.connection_owner database in
  F.connect connection;
  Exn.protect ~f:(fun () -> f connection) ~finally:(fun () ->
    F.close_connection connection; F.finish_connection_close connection;
    F.close_database database; F.finish_database_close database)
let foreign_admission () = fixture (fun connection ->
  let request = N.create () in
  let installation = N.prepare_install connection request in
  reset (); execute_gate 2;
  Exn.protect ~finally:(fun () -> ignore (N.try_uninstall request); dispose request) ~f:(fun () ->
    E.with_worker (fun () -> F.execute connection "SELECT 1" false) ~f:(fun join ->
      Exn.protect ~finally:(fun () -> execute_gate 0) ~f:(fun () ->
        E.await ~label:"unbound foreign work pending" (fun () -> execute_entered () = 2);
        check "cannot install during unbound foreign activity"
          (match N.try_install_prepared installation with N.Connection_active -> true | _ -> false);
        execute_gate 0; join ()));
    check "failed active install remains fresh"
      (match N.try_install_prepared installation with N.Installed -> true | _ -> false)))
let foreign_completion () = fixture (fun connection ->
  let request = N.create () in
  check "bound install" (match N.try_install connection request with N.Installed -> true | _ -> false);
  reset (); execute_gate 2;
  Exn.protect ~finally:(fun () ->
    ignore (N.try_uninstall request); dispose request) ~f:(fun () ->
    E.with_worker (fun () -> F.execute connection "SELECT 1" false) ~f:(fun join ->
      Exn.protect ~finally:(fun () -> execute_gate 0) ~f:(fun () ->
        E.await ~label:"foreign result produced but wrapper pending" (fun () -> execute_entered () = 2);
        check "zero reservations is not foreign completion"
          (match N.try_uninstall request with N.Native_work_pending -> true | _ -> false);
        execute_gate 0; join ()));
    check "detach after actual completion" (match N.try_uninstall request with N.Uninstalled -> true | _ -> false)))
let closing () = fixture (fun connection ->
  let request = N.create () in
  reset (); disconnect_gate true;
  Exn.protect ~finally:(fun () -> ignore (N.try_uninstall request); dispose request) ~f:(fun () ->
    E.with_worker (fun () -> F.close_connection connection) ~f:(fun join ->
      Exn.protect ~finally:(fun () -> disconnect_gate false) ~f:(fun () ->
        E.await ~label:"unlocked disconnect after closing publication" disconnect_entered;
        check "closing published before disconnect"
          (match N.try_install connection request with N.Connection_closed -> true | _ -> false);
        disconnect_gate false; join ()))))
let guard_contention () = fixture (fun connection ->
  let child = F.prepared_owner connection in
  let request = N.create () in
  Exn.protect ~finally:(fun () ->
    dispose request; release_fixture ();
    F.close_prepared child; F.finish_prepared_close child) ~f:(fun () ->
    check "real guard rejects noalloc install without waiting"
      (match contended_install connection request with N.Install_contended -> true | _ -> false)))
let pending connection id work =
  let request = N.create () in
  check "boundary install" (match N.try_install connection request with N.Installed -> true | _ -> false);
  boundary_gate id;
  Exn.protect ~finally:(fun () -> ignore (N.try_uninstall request); dispose request) ~f:(fun () ->
    E.with_worker work ~f:(fun join ->
      Exn.protect ~finally:(fun () -> boundary_gate 0) ~f:(fun () ->
        E.await ~label:"native work/cleanup boundary" (fun () -> boundary_entered () = id);
        check ("native work/cleanup pending: " ^ Int.to_string id)
          (match N.try_uninstall request with N.Native_work_pending -> true | _ -> false);
        check "USER remains ineligible during work/cleanup"
          (match N.reserve_delivery request with N.Ineligible -> true | _ -> false);
        boundary_gate 0; join ()));
    check "boundary completion detaches" (match N.try_uninstall request with N.Uninstalled -> true | _ -> false))
let prepared_boundaries () = fixture (fun connection ->
  let p = F.prepared_owner connection in
  Exn.protect ~finally:(fun () -> F.close_prepared p; F.finish_prepared_close p; release_fixture ()) ~f:(fun () ->
    F.prepare p "SELECT ?::BIGINT";
    pending connection 1 (fun () -> F.bind_int64 p 1 5 42L);
    pending connection 2 (fun () -> F.reset p);
    F.bind_int64 p 1 5 42L;
    let request = N.create () in
    check "prepared execute install" (match N.try_install connection request with N.Installed -> true | _ -> false);
    execute_gate 2;
    Exn.protect ~finally:(fun () -> ignore (N.try_uninstall request); dispose request) ~f:(fun () ->
      E.with_worker (fun () -> F.execute_prepared p) ~f:(fun join ->
        Exn.protect ~finally:(fun () -> execute_gate 0) ~f:(fun () ->
          E.await ~label:"prepared foreign return" (fun () -> execute_entered () = 2);
          check "prepared foreign work pending" (match N.try_uninstall request with N.Native_work_pending -> true | _ -> false);
          execute_gate 0; join ())));
    pending connection 6 (fun () -> ignore (F.fetch p));
    pending connection 5 (fun () -> F.close_result p);
    F.finish_result_close p;
    F.execute_prepared p;
    pending connection 3 (fun () -> F.close_result p);
    F.finish_result_close p;
    pending connection 4 (fun () -> F.close_prepared p)))
let appender_boundaries () = fixture (fun connection ->
  F.execute connection "CREATE TABLE native_appender (i BIGINT)" false;
  List.iter [7; 8; 9; 10] ~f:(fun id ->
    let a = F.appender_owner connection in
    Exn.protect ~finally:(fun () -> F.close_appender a false; F.finish_appender_close a; release_fixture ()) ~f:(fun () ->
      F.create_appender a "main" "native_appender";
      check "appender fixture created" (F.appender_status a = 0);
      F.append_rows a [|[|(5, false, 1L, 0., "")|]|];
      pending connection id (fun () -> if id = 7 then F.flush_appender a else F.close_appender a (id = 8)))))
let run () =
  (match Array.to_list Stdlib.Sys.argv with
   | [_; "closing"] -> closing ()
   | _ -> foreign_admission (); foreign_completion (); closing (); guard_contention (); prepared_boundaries (); appender_boundaries ());
  check "native lifecycle fixture no GC" (F.live_resources () = 0 && F.fallback_reclaims () = 0);
  Stdlib.print_endline "native lifecycle: active admission, foreign completion, prepared/bind/reset/fetch/cleanup, appender close, closing and try-guard passed (USER disabled)"
let () = run ()
