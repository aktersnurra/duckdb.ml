let check (connection : Duckdb_ffi.connection) =
  let request = Duckdb_ffi.Native_request.create () in
  let module N = Duckdb_ffi.Native_request in
  N.cancel request;
  let installation = N.prepare_install connection request in
  (match N.try_install_prepared installation with
   | N.Installed | N.Install_contended | N.Connection_closed
   | N.Connection_leased | N.Request_used | N.Connection_active -> ());
  (match N.try_install connection request with
   | N.Installed | N.Install_contended | N.Connection_closed
   | N.Connection_leased | N.Request_used | N.Connection_active -> ());
  (match N.reserve_delivery request with
   | N.Reserved | N.Ineligible | N.Reservation_pending -> ());
  (match N.try_interrupt request with
   | N.Delivered | N.Skipped | N.Not_reserved -> ());
  (match N.deliver request with
   | N.Delivered | N.Skipped | N.Not_reserved -> ());
  N.retire_delivery request;
  (match N.try_uninstall request with
   | N.Uninstalled | N.Uninstall_contended | N.Native_work_pending
   | N.Delivery_pending | N.Not_installed -> ());
  match N.dispose request with Ok () | Error N.Still_installed -> ()
