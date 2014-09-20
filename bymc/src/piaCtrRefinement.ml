(* The refinement for our counter abstraction *)

open Printf
open Str

open AbsBasics
open Accums
open Ltl
open Program
open Spin
open SpinIr
open SpinIrImp
open Smt
open Debug

exception Refinement_error of string

exception No_moving_error

let pred_reach = "p"
let pred_recur = "r"


(* don't touch symbolic variables --- they are the parameters! *)
let map_to_in v = if v#is_symbolic then v else v#copy (v#get_name ^ "_IN") ;;
let map_to_out v = if v#is_symbolic then v else v#copy (v#get_name ^ "_OUT") ;;
let map_to_step step v =
    if v#is_symbolic
    then v
    else v#copy (sprintf "S%d_%s" step v#get_name)


let stick_var map_fun v = Var (map_fun v)

let connect_steps tracked_vars step =
    let connect v =
        let ov = map_to_step step (map_to_out v) in
        let iv = map_to_step (step + 1) (map_to_in v) in
        BinEx (EQ, Var ov, Var iv) in
    list_to_binex AND (List.map connect tracked_vars)


(* the process is skipping the step, not moving *)
let skip_step local_vars step =
    let eq v =
        let iv = map_to_step step (map_to_in v) in
        let ov = map_to_step step (map_to_out v) in
        BinEx (EQ, Var ov, Var iv) in
    list_to_binex AND (List.map eq local_vars)


let create_path proc local_vars shared_vars n_steps =
    let tracked_vars = local_vars @ shared_vars in
    let map_xducer n =
        let es = List.map expr_of_m_stmt proc#get_stmts in
        List.map (map_vars (stick_var (map_to_step n))) es
    in
    let move_or_skip step = map_xducer step in
    (* the old way:
        let entry_loc = map_to_step step (CfgSmt.get_entry_loc proc) in
        (* if the process is enabled, use the transition relation,
           else keep the local variables *)
        BinEx (OR, Var entry_loc, skip_step local_vars step)
            :: (* by construction: at0 -> *) (map_xducer step)
            *)
    let xducers = List.concat (List.map move_or_skip (range 0 n_steps)) in
    let connections =
        List.map (connect_steps tracked_vars) (range 0 (n_steps - 1)) in
    xducers @ connections


let smt_append_bind solver smt_rev_map state_no orig_expr mapped_expr =
    let smt_id = solver#append_expr mapped_expr in
    (* bind ids assigned to expressions by the solver *)
    if smt_id >= 0
    then begin
        log DEBUG (sprintf "map: %d -> %d, %s\n"
            smt_id state_no (expr_s mapped_expr));
        if solver#get_collect_asserts
        then Hashtbl.add smt_rev_map smt_id (state_no, orig_expr)
    end


let activate_process procs step =
    let enabled p = Var (map_to_step step (CfgSmt.get_entry_loc p)) in
    let disabled p = UnEx (NEG, enabled p) in
    let proc_mux = function
        | [p; q] ->
            if p#get_name <> q#get_name
            then BinEx (OR, disabled p, disabled q)
            else (Nop "")

        | _ -> raise (Failure "[p; q] expected")
    in
    let at_least_one = list_to_binex OR (List.map enabled procs) in
    let mux = list_to_binex AND (List.map proc_mux (mk_product procs 2))
    in
    BinEx (AND, at_least_one, mux)


let check_trail_asserts solver trail_asserts n_steps =
    let smt_rev_map = Hashtbl.create 10 in
    let append_one_assert state_no is_traceable asrt =
        let new_e =
            if state_no = 0
            then map_vars (fun v -> Var (map_to_step 0 (map_to_in v))) asrt
            else map_vars
                (fun v -> Var (map_to_step (state_no - 1) (map_to_out v))) asrt
        in
        if is_traceable
        then smt_append_bind solver smt_rev_map state_no asrt new_e
        else let _ = solver#append_expr new_e in ()
    in
    let append_trail_asserts state_no (asserts, assumes, _) =
        List.iter (append_one_assert state_no true) asserts;
        List.iter (append_one_assert state_no false) assumes
    in
    (* put asserts from the counter example *)
    log INFO (sprintf "    adding %d trail asserts..."
        (List.length trail_asserts));

    assert (n_steps < (List.length trail_asserts));
    let trail_asserts = list_sub trail_asserts 0 (n_steps + 1) in
    solver#push_ctx;
    List.iter2 append_trail_asserts (range 0 (n_steps + 1)) trail_asserts;
    logtm INFO "    waiting for SMT...";
    let result = solver#check in
    solver#pop_ctx;
    (result, smt_rev_map)


let simulate_in_smt solver xd_prog ctr_ctx_tbl n_steps =
    let shared_vars = Program.get_shared xd_prog in
    let type_tab = Program.get_type_tab xd_prog in

    let proc_asserts proc =
        let local_vars = ctr_ctx_tbl#all_counters in
        create_path proc local_vars shared_vars n_steps
    in
    (* put asserts from the control flow graph *)
    log INFO (sprintf 
        "    getting declarations and assertions of %d transition relations..."
        (List.length (Program.get_procs xd_prog)));
    let procs = Program.get_procs xd_prog in
    assert (1 = (List.length procs));
    (*let activation = List.map (activate_process procs) (range 0 n_steps) in*)
    let xducer_asserts = (* the old thing: activation @ *)
        (List.concat (List.map proc_asserts procs)) in
    let decls = expr_list_used_vars xducer_asserts in

    trace Trc.pcr (fun _ -> sprintf " xducer asserts");
    trace Trc.pcr (fun _ -> str_join "\n" (List.map expr_s xducer_asserts));
    trace Trc.pcr (fun _ -> sprintf " xducer decls");
    trace Trc.pcr (fun _ ->
        str_join "\n" (List.map (fun v -> sprintf "%s#%d" v#qual_name v#id) decls));

    log INFO (sprintf "    adding %d declarations..." (List.length decls));
    let append_def v = solver#append_var_def v (type_tab#get_type v) in
    List.iter append_def decls;

    log INFO (sprintf "    adding %d transition asserts..."
        (List.length xducer_asserts));
    List.iter (fun e -> let _ = solver#append_expr e in ()) xducer_asserts


let parse_smt_evidence prog solver =
    let vals = Hashtbl.create 10 in
    let lines = solver#get_evidence in
    let aliases = Hashtbl.create 5 in
    let is_alias full_name = Hashtbl.mem aliases full_name in
    let add_alias full_name step name dir =
        Hashtbl.add aliases full_name (step, name, dir) in
    let get_alias full_name = Hashtbl.find aliases full_name in
    let param_re = Str.regexp "(= \\([a-zA-Z0-9]+\\) \\([-0-9]+\\))" in
    let var_re =
        Str.regexp "(= S\\([0-9]+\\)_\\([_a-zA-Z0-9]+\\)_\\(IN\\|OUT\\) \\([-0-9]+\\))"
    in
    let arr_re =
        Str.regexp "(= (S\\([0-9]+\\)_\\([_a-zA-Z0-9]+\\)_\\([A-Z0-9]+\\) \\([0-9]+\\)) \\([-0-9]+\\))"
    in
    let alias_re =
        Str.regexp ("(= S\\([0-9]+\\)_\\([_a-zA-Z0-9]+\\)_\\(IN\\|OUT\\) "
            ^ "S\\([0-9]+_[_a-zA-Z0-9]+_[A-Z0-9]+\\))") in
    let add_state_expr state expr =
        if not (Hashtbl.mem vals state)
        then Hashtbl.add vals state [expr]
        else Hashtbl.replace vals state (expr :: (Hashtbl.find vals state))
    in
    let parse_line line =
        if Str.string_match var_re line 0
        then begin
            (* (= S0_nsnt_OUT 1) *)
            let step = int_of_string (Str.matched_group 1 line) in
            let name = (Str.matched_group 2 line) in
            let dir = (Str.matched_group 3 line) in
            (* we support ints only, don't we? *)
            let value = int_of_string (Str.matched_group 4 line) in
            let state = if dir = "IN" then step else (step + 1) in
            let e = BinEx (ASGN, Var (new_var name), Const value) in
            if List.exists
                (fun v -> v#get_name = name) (Program.get_shared prog)
            then add_state_expr state e;
        end else if Str.string_match arr_re line 0
        then begin
            (* (= (S0_bymc_kP_IN 11) 0) *)
            let s = int_of_string (Str.matched_group 1 line) in
            let n = (Str.matched_group 2 line) in
            let d = (Str.matched_group 3 line) in
            let full = sprintf "%d_%s_%s" s n d in
            let step, name, dir =
                if is_alias full then get_alias full else s, n, d in
            let idx = int_of_string (Str.matched_group 4 line) in
            (* we support ints only, don't we? *)
            let value = int_of_string (Str.matched_group 5 line) in
            let state = if dir = "IN" then step else (step + 1) in
            let e = BinEx (ASGN,
                BinEx (ARR_ACCESS, Var (new_var name), Const idx),
                Const value) in
            if dir = "IN" || dir = "OUT"
            then add_state_expr state e; (* and ignore auxillary arrays *)
        end else if Str.string_match alias_re line 0
        then begin
            (* (= S0_bymc_kP_OUT S0_bymc_kP_Y2) *)
            let target = (Str.matched_group 4 line) in
            let step = int_of_string (Str.matched_group 1 line) in
            let name = (Str.matched_group 2 line) in
            let dir = (Str.matched_group 3 line) in
            add_alias target step name dir
        end else if Str.string_match param_re line 0
        then begin
            (* (= T 2) *)
            let name = (Str.matched_group 1 line) in
            let value = int_of_string (Str.matched_group 2 line) in
            add_state_expr 0 (BinEx (ASGN, Var (new_var name), Const value))
        end
    in
    List.iter parse_line lines;
    let cmp e1 e2 =
        let comp_res = match e1, e2 with
        | BinEx (ASGN, Var v1, Const k1),
          BinEx (ASGN, Var v2, Const k2) ->
              let r = String.compare v1#get_name v2#get_name in
              if r <> 0 then r else (k1 - k2)
        | BinEx (ASGN, BinEx (ARR_ACCESS, Var a1, Const i1), Const k1),
          BinEx (ASGN, BinEx (ARR_ACCESS, Var a2, Const i2), Const k2) ->
                let r = String.compare a1#get_name a2#get_name in
                if r <> 0
                then r
                else if i1 <> i2
                then i1 - i2
                else k1 - k2
        | BinEx (ASGN, BinEx (ARR_ACCESS, Var a1, Const i1), _),
          BinEx (ASGN, Var v2, _) ->
                -1 (* arrays go first *)
        | BinEx (ASGN, Var v1, _),
          BinEx (ASGN, BinEx (ARR_ACCESS, Var a2, Const i2), _) ->
                1 (* arrays go first *)
        | _ -> raise (Failure
            (sprintf "Incomparable: %s and %s" (expr_s e1) (expr_s e2)))
        in
        comp_res
    in
    let new_tbl = Hashtbl.create (Hashtbl.length vals) in
    Hashtbl.iter
        (fun k vs -> Hashtbl.add new_tbl k (list_sort_uniq cmp vs))
        vals;
    new_tbl


(* group an expression in a sorted valuation *)
let pretty_print_exprs exprs =
    let last_arr = ref "" in
    let last_idx = ref (-1) in
    let start_arr arr idx = 
        last_arr := arr#get_name;
        last_idx := idx - 1;
        printf "%s = { " !last_arr
    in
    let stop_arr () = 
        printf "} ";
        last_arr := ""
    in
    let pp = function
        | BinEx (ASGN, BinEx (ARR_ACCESS, Var arr, Const idx), Const value) ->
                if !last_arr <> "" && !last_arr <> arr#get_name
                then stop_arr ();
                if !last_arr <> arr#get_name
                then start_arr arr idx;
                if (!last_idx >= idx)
                then raise (Failure
                    (sprintf "Met %s[%d] = %d after %s[%d]"
                        arr#get_name idx value arr#get_name !last_idx));
                (* fill the gaps in indices *)
                List.iter (fun _ -> printf "_ ") (range !last_idx (idx - 1));
                (* print the value *)
                printf "%d " value;
                last_idx := idx

        | BinEx (ASGN, Var var, Const value) ->
                if !last_arr <> ""
                then stop_arr ();
                printf "%s = %d " var#get_name value

        | _ -> ()
    in
    List.iter pp exprs


let find_max_pred prefix = 
    let re = Str.regexp (".*bit bymc_" ^ prefix ^ "\\([0-9]+\\) = 0;.*") in
    let read_from_file () =
        let cin = open_in "cegar_decl.inc" in
        let stop = ref false in
        let max_no = ref (-1) in
        while not !stop do
            try
                let line = input_line cin in
                if Str.string_match re line 0
                then
                    let no = int_of_string (Str.matched_group 1 line) in
                    max_no := max !max_no no
            with End_of_file ->
                close_in cin;
                stop := true
        done;
        !max_no
    in
    try read_from_file ()
    with Sys_error _ -> (-1)


let intro_new_pred new_type_tab prefix step_no (* pred_reach or pred_recur *) =
    let pred = new var (sprintf "bymc_%s%d" prefix step_no) (fresh_id ()) in
    new_type_tab#set_type pred (new data_type SpinTypes.TBIT);
    pred#set_instrumental;
    pred


(* retrieve unsat cores, map back corresponding constraints on abstract values,
   partition the constraints into two categories:
       before the transition, after the transition
 *)
let retrieve_unsat_cores rt smt_rev_map src_state_no =
    let leaf_fun = function
        | BinEx (ARR_ACCESS, Var _, _) -> true
        | Var _ as e -> not (is_symbolic e)
        | _ -> false
    in
    let abstract ((s, e): int * expr_t): int * expr_t =
        let dom = rt#caches#analysis#get_pia_dom in
        let abse = AbsInterval.abstract_pointwise_exprs
            dom rt#solver AbsBasics.ExistAbs leaf_fun e in
        (s, abse)
    in
    let core_ids = rt#solver#get_unsat_cores in
    log INFO (sprintf "Detected %d unsat core ids\n" (List.length core_ids));
    let filtered =
        List.filter (fun id -> Hashtbl.mem smt_rev_map id) core_ids in
    let mapped = List.map (fun id -> Hashtbl.find smt_rev_map id) filtered in
    (* List.iter (fun (s, e) -> printf "   %d: %s\n" s (expr_s e)) mapped; *)
    rt#solver#push_ctx;
    let aes = List.map abstract mapped in
    let pre, post = List.partition (fun (s, _) -> s = src_state_no) aes in
    let b2 (_, e) = e in
    let pre, post = List.map b2 pre, List.map b2 post in
    rt#solver#pop_ctx;
    (pre, post)


let refine_spurious_step rt smt_rev_map src_state_no ref_step prog =
    let new_type_tab = (Program.get_type_tab prog)#copy in
    let sym_tab = Program.get_sym_tab prog in
    let bymc_spur = (sym_tab#lookup "bymc_spur")#as_var in
    let pre, post = retrieve_unsat_cores rt smt_rev_map src_state_no in
    let pred = intro_new_pred new_type_tab pred_reach ref_step in

    if pre = [] && post = []
    then raise (Failure "Cannot refine: unsat core is empty");

    printf "pre = %s\n" (str_join ", " (List.map expr_s pre));
    printf "post = %s\n" (str_join ", " (List.map expr_s post));

    let asgn_spur e =
        MExpr (fresh_id (),
            BinEx (ASGN, Var bymc_spur,
                BinEx (OR, Var bymc_spur, e)))
    in
    let or_true e = if not_nop e then e else (Const 1) in
    (* Modify the counter abstraction directly to exclude the transitions
       by setting bymc_spur to true. By adding []!bymc_spur as a precondition,
       we cut out the spurious behaviour. This works for Promela.
       As the NuSMV encoding is more subtle, we save pre and post to
       Program.spurious_steps for a future use in NusmvSsaEncoding.
     *)
    let sub = function
        | MExpr (id, Nop ("assume(pre_cond)")) as s ->
            [ s; MExpr(fresh_id (),
                BinEx (ASGN, Var pred, or_true (list_to_binex AND pre))) ]

        | MExpr (id, Nop ("assume(post_cond)")) as s ->
            [ s; asgn_spur (list_to_binex AND ((Var pred) :: post)) ]

        | _ as s -> [ s ]
    in
    let sub_proc proc = 
        proc_replace_body proc (sub_basic_stmt_with_list sub proc#get_stmts)
    in
    let new_spurious =
        (list_to_binex AND pre, list_to_binex AND post)
            :: (Program.get_spurious_steps prog)
    in
    Program.set_spurious_steps new_spurious
        (Program.set_type_tab new_type_tab
        (Program.set_instrumental (pred :: (Program.get_instrumental prog))
        (Program.set_procs (List.map sub_proc (Program.get_procs prog)) prog)))


let print_vass_trace prog solver num_states = 
    printf "Here is a CONCRETE trace in VASS violating the property.\n";
    printf "State 0 gives concrete parameters.\n\n";
    let vals = parse_smt_evidence prog solver in
    let print_st i =
        printf "%d: " i;
        pretty_print_exprs (Hashtbl.find vals i);
        printf "\n";
    in
    List.iter (print_st) (range 0 num_states)


let is_loop_state_fair_by_step rt prog ctr_ctx_tbl fairness
        state_asserts state_num =
    rt#solver#comment ("is_loop_state_fair_by_step: " ^ (expr_s fairness));
    rt#solver#push_ctx;
    rt#solver#set_collect_asserts true;
    rt#solver#set_need_evidence true;

    (* State 0 is fair and it is a concretization of the abstract state
       kept in state_asserts. State 1 is restricted only by the transition
       relation, which also carries the invariants.
       In fact, we want to make a step to check, whether the fairness
       contradicts the invariants.
    *)
    let asserts, _, annot = state_asserts in
    let step_asserts = [(asserts, [fairness], annot); ([], [], StringMap.empty)]
    in
    (* simulate one step *)
    rt#solver#push_ctx;
    simulate_in_smt rt#solver prog ctr_ctx_tbl 1;
    let res, smt_rev_map = check_trail_asserts rt#solver step_asserts 1 in

    (* collect unsat cores if the assertions contradict fairness,
       or fairness + the state assertions lead to a deadlock *)
    let core_exprs, _ =
        if not res
        then retrieve_unsat_cores rt smt_rev_map 0
        else [], []
    in
    rt#solver#pop_ctx;
    let core_exprs_and = list_to_binex AND core_exprs in

    if res then begin
        logtm INFO
            (sprintf "State %d of the loop is fair. See the trace." state_num);
        print_vass_trace prog rt#solver 2;
    end else begin
        printf "core_exprs_s: %s\n" (expr_s core_exprs_and)
    end;

    rt#solver#set_collect_asserts false;
    rt#solver#set_need_evidence false;
    rt#solver#pop_ctx;
    res, core_exprs_and


(* TODO: this looks ugly, make a refactoring pass *)
let check_fairness_supression rt fair_forms
        loop_asserts ref_step vass_prog prog =
    let ctr_ctx_tbl = rt#caches#analysis#get_pia_ctr_ctx_tbl in
    let new_type_tab = (Program.get_type_tab prog)#copy in
    let check_one (res, cur_prog) ff = 
        log INFO ("  Checking if the loop is fair...");
        let check_and_collect_cores (all_sat, all_core_exprs, num) state_asserts =
            let sat, core_exprs =
                is_loop_state_fair_by_step rt
                    vass_prog ctr_ctx_tbl ff state_asserts num
            in
            (all_sat || sat, core_exprs :: all_core_exprs, (num + 1))
        in
        let sat, exprs, _ =
            List.fold_left check_and_collect_cores (false, [], 0) loop_asserts
        in
        if not sat
        then begin
            (* introduce a new predicate *)
            let pred = intro_new_pred new_type_tab pred_recur ref_step in
            let sub = function
                | MExpr (id, Nop ("assume(post_cond)")) as s ->
                    [ s; MExpr (fresh_id(),
                        BinEx (EQ, Var pred, (list_to_binex AND exprs))) ]

                | _ as s -> [ s ]
            in
            let sub_proc p = 
                proc_replace_body p (sub_basic_stmt_with_list sub p#get_stmts)
            in
            let fairness =
                StringMap.find "fairness_ctr" (Program.get_ltl_forms cur_prog)
            in
            let forbid_unfair_loop =
                (* the unfair predicate can't appear forever *)
                UnEx(ALWAYS, UnEx(EVENTUALLY, UnEx (NEG, Var pred))) in
            (* extend the fairness constraint with "no supression" *)
            let new_fairness =
                BinEx (AND, fairness, forbid_unfair_loop) in
            (* embed the predicate into the program and
               add the fairness constraint *)
            let new_i = pred :: (Program.get_instrumental cur_prog) in
            let new_p = List.map sub_proc (Program.get_procs cur_prog) in
            let new_f = StringMap.add "fairness_ctr" new_fairness
                (Program.get_ltl_forms cur_prog) in
            let new_prog =
                Program.set_type_tab new_type_tab
                    (Program.set_ltl_forms new_f
                        (Program.set_instrumental new_i
                            (Program.set_procs new_p cur_prog))) in
            (not sat, new_prog)
        end else (res || not sat, cur_prog)
    in
    List.fold_left check_one (false, prog) fair_forms


let filter_good_fairness type_tab aprops fair_forms =
    let err_fun f =
        printf "Fairness formula not supported by refinement (ignored): %s\n" 
            (expr_s f);
        Nop ""
    in
    let fair_atoms = List.map (find_fair_atoms err_fun type_tab aprops) fair_forms in
    let filtered = List.filter not_nop fair_atoms in
    printf "added %d fairness constraints\n" (List.length filtered);
    filtered


(* Translate the Program.path_t format to the list of assertions
   annotated with intrinsics. Intrinsics are not used anymore,
   but maybe they will be used in the future again.
 *)
let annotate_path path =
    let f accum elem =
        match (elem, accum) with
        | (State es, l) ->
            (* new state, no annotations *)
            (es, [], StringMap.empty) :: l

        | (Intrinsic i, (es, _, map) :: tl) ->
            (* merge annotations *)
            (es, [], StringMap.merge map_merge_fst i map) :: tl

        | (Intrinsic i, []) ->
            log DEBUG "Intrinsic met before State. Ignored.";
            []
    in
    List.rev (List.fold_left f [] path)


(* FIXME: refactor it, the decisions must be clear and separated *)
(* units -> interval abstraction -> vector addition state systems *)
let do_refinement (rt: Runtime.runtime_t) ref_step
        ctr_prog xducer_prog (prefix, loop) =
    let apath = annotate_path (prefix @ loop) in
    let num_states = List.length apath in
    let loop_start = List.length (annotate_path prefix) in
    let total_steps = num_states - 1 in
    log INFO (sprintf "  %d step(s)" total_steps);
    if total_steps = 0
    then raise (Failure "All processes idle forever at the initial state");
    log INFO "  [DONE]";
    log INFO "> Simulating counter example in VASS...";

    let check_trans st = 
        let next_st = if st = num_states - 1 then loop_start else st + 1 in
        let step_asserts = [List.nth apath st; List.nth apath next_st] in
        rt#solver#push_ctx;
        rt#solver#comment
            (sprintf ";; Checking the transition %d -> %d" st next_st);
        rt#solver#set_collect_asserts true;
        let res, smt_rev_map = check_trail_asserts rt#solver step_asserts 1 in
        rt#solver#set_collect_asserts false;
        if not res
        then begin
            logtm INFO
                (sprintf "  The transition %d -> %d is spurious." st next_st);
            rt#solver#pop_ctx;
            (* speedup trick: pop out  here the transition relation
               saved in (A),
               as we do not need it when looking for unsat cores.
               Otherwise, it will be popped in (C) *)
            (* XXX: bad design, refactor *)
            rt#solver#pop_ctx; (* (B) *)

            let new_prog =
                refine_spurious_step rt smt_rev_map 0 ref_step ctr_prog in
            (true, new_prog)
        end else begin
            logtm INFO (sprintf "  The transition %d -> %d (of %d) is OK."
                    st next_st total_steps);
            rt#solver#pop_ctx;
            (false, ctr_prog)
        end
    in
    let find_first (res, prog) step_no =
        if res
        then (true, prog)
        else check_trans step_no
    in
    (* Try to detect spurious transitions and unfair paths
       (discussed in the FMCAD13 paper) *)
    logtm INFO "  Trying to find a spurious transition...";
    rt#solver#push_ctx; (* (A) *)
    rt#solver#set_need_evidence true; (* needed for refinement! *)
    let ctr_ctx_tbl = rt#caches#analysis#get_pia_ctr_ctx_tbl in
    simulate_in_smt rt#solver xducer_prog ctr_ctx_tbl 1;
    let last_state = if loop <> [] then num_states else num_states - 1 in
    let (refined, new_prog) =
        List.fold_left find_first (false, ctr_prog) (range 0 last_state)
    in
    if refined
    then begin
        log INFO "(status trace-refined)";
        (true, new_prog)
    end else begin
        rt#solver#pop_ctx; (* (C) pop the transition relation *)
        (* try to detect fairness supression *)
        let ltl_forms = Program.get_ltl_forms_as_hash xducer_prog in
        let type_tab = Program.get_type_tab xducer_prog in
        let fairness =
            filter_good_fairness type_tab (Program.get_atomics_map xducer_prog)
                (collect_fairness_forms ltl_forms) in
        let aloop = annotate_path loop in
        let (refined, new_prog) =
            check_fairness_supression rt fairness aloop ref_step
                xducer_prog ctr_prog
        in
        if refined
        then begin
            log INFO "The loop is unfair. Refined.";
            (true, new_prog)
        end else begin
            log INFO "The loop is fair";

            log INFO "This counterexample does not have spurious transitions or states.";
            log INFO "If it does not show a real problem, provide me with an invariant.";
            (false, ctr_prog)
        end
    end

