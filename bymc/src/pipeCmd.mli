(*
 * A high-level communication with a child process using readline and writeline
 * primitives. The process is served by a separate thread that takes care of
 * avoiding deadlocks and other low-level surprises.
 *
 * Igor Konnov, 2013
 *)

exception Comm_error of string

type cmd_stat

(* create a new process using Unix.create_process, connect it with a pipe
  and associate a communicating thread with it *)
val create: string -> string array -> string -> cmd_stat

(* terminate the child process and the associated thread *)
val destroy: cmd_stat -> bool

(* read one line from the process pipe. The current thread may be blocked
  when there is no pending output from the process. *)
val readline: cmd_stat -> string

val writeline: cmd_stat -> string -> unit