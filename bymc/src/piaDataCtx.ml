open Spin
open SpinIr
open VarRole

(* Context of parametric interval abstraction.
   It collects variable roles over different process prototypes.
 *)
class pia_data_ctx i_roles =
    object(self)
        val mutable m_roles: var_role_tbl = i_roles
        val mutable m_hack_shared: bool = false

        method is_hack_shared = m_hack_shared
        method set_hack_shared b = m_hack_shared <- b

        method set_roles r = m_roles <- r

        method must_keep_concrete (e: token expr) =
            match e with
            | Var v ->
              begin
                try m_hack_shared && is_shared_unbounded (m_roles#get_role v)
                with VarRole.Var_not_found _ -> false
              end

            | _ -> false

        method var_needs_abstraction (v: var) =
            let is_bounded_scratch =
                match m_roles#get_role v with
                | Scratch o -> is_bounded (m_roles#get_role o)
                | _ -> false
            in
            let r = m_roles#get_role v in
            (not (self#must_keep_concrete (Var v)))
                && (not (is_bounded r)) && (not is_bounded_scratch)
    end


