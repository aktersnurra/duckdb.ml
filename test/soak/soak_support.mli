type scenario =
  | Queued_cancel
  | Running_callback_cancel
  | Terminal_race
  | Repeated_cancel
  | Stale_reuse
  | Shutdown_active
  | Shutdown_shared
  | Typed_then_shutdown

type config = { seed : int; episodes : int }

val parse_config : string array -> (config, string) result
val schedule : config -> scenario array
val scenario_name : scenario -> string
val report : adapter:string -> config -> episode:int -> scenario -> detail:string -> unit
