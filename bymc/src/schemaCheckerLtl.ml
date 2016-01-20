(**
 
 An improvement of SlpsChecker that generates schemas on-the-fly and supports LTL(F,G).

 Igor Konnov, 2016
 *)

open Batteries
open Printf

open Accums
open Debug
open PorBounds
open SymbSkel
open Poset
open SchemaSmt
open Spin
open SpinIr
open SymbSkel

exception IllegalLtl_error of string

(* The initial state and the state where the loop starts
   have fixed indices in the partial order.
 *)
let po_init = 1
let po_loop = 0

(**
 The record type of a result returned by check_schema_tree_on_the_fly.
 *)
type result_t = {
    m_is_err_found: bool;
    m_counterexample_filename: string;
}


(**
 The type of atomic formulas supported by the model checker
 *)
type atomic_spec_t =
    | And_Keq0 of int list          (** /\_{i \in X} k_i = 0 *)
    | AndOr_Kne0 of int list list   (** /\_{X_j \in Y} \/_{i \in X_j} k_i \ne 0 *)
    | Shared_Or_And_Keq0 of Spin.token SpinIr.expr * int list
                                    (** f(g) \/ /\_{i \in X} k_i = 0 *)


(**
 LTL(F, G) formulas as supported by the model checker
 *)
type utl_k_spec_t =
    | TL_p of atomic_spec_t     (** a conjunction of atomic formulas *)
    | TL_F of utl_k_spec_t        (** F \phi *)
    | TL_G of utl_k_spec_t        (** G \phi *)
    | TL_and of utl_k_spec_t list (* a conjunction *)


(**
 A classification of temporal formulas
 *)
type spec_t =
    | Safety of Spin.token SpinIr.expr * Spin.token SpinIr.expr
        (* a safety violation: init_form -> F bad_form *)
    | UTL of utl_k_spec_t
        (* a UTL formula *)


(**
 Find the propositional subformulas that are not covered by a temporal operator.
 *)
let find_uncovered_utl_props form =
    let rec collect col = function
    | TL_p prop ->
        prop :: col

    | TL_and fs ->
        List.fold_left collect col fs

    | _ -> (* skip the temporal operators *)
        col
    in
    collect [] form


(**
 Find the propositional subformulas that are covered by G (as constructed by utl_k_to_expr).
 *)
let find_G_props form =
    let rec collect col = function
    | TL_G f ->
        (find_uncovered_utl_props f) @ col

    | TL_and fs ->
        List.fold_left collect col fs

    | _ -> (* skip the temporal operators *)
        col
    in
    collect [] form


(**
 Find the propositional subformulas that are not covered by a temporal operator
 in an LTL formula. Similar to find_uncovered_utl_props, but works for LTL, not UTL.
 *)
let keep_uncovered_ltl_props form =
    (* a special expression denoting a deleted subexpression *)
    let deleted = IntConst (-1) in
    let fuse op l r =
        if l = deleted
        then r
        else if r = deleted
            then l
            else BinEx (op, l, r)
    in
    (* remove everything but the propositional formulas *)
    let rec keep = function
    | BinEx(EQ, _, _)
    | BinEx(NE, _, _)
    | BinEx(LT, _, _)
    | BinEx(LE, _, _)
    | BinEx(GT, _, _)
    | BinEx(GE, _, _) as expr ->
        expr

    | UnEx (NEG, exp) ->
        let ke = keep exp in
        if ke = deleted
        then deleted
        else UnEx (NEG, ke)

    | BinEx (AND, l, r) ->
        fuse AND (keep l) (keep r)

    | BinEx (OR, l, r) ->
        fuse OR (keep l) (keep r)

    | BinEx (IMPLIES, l, r) ->
        fuse OR (keep (UnEx (NEG, l))) (keep r)

    | UnEx (EVENTUALLY, _)
    | UnEx (ALWAYS, _)
    | UnEx (NEXT, _) ->         (* although we do not support nexttime *)
        deleted

    | BinEx (UNTIL, _, _)       (* nor until and release *)
    | BinEx (RELEASE, _, _) ->
        deleted

    | _ as e ->
        raise (Failure ("Unexpected formula: " ^ (SpinIrImp.expr_s e)))
    in
    let res = keep form in
    if res = deleted
    then IntConst 1 (* just true *)
    else Ltl.normalize_form res


let find_temporal_subformulas form =
    let rec collect col = function
    | TL_F _ as f ->
        f :: col

    | TL_G _ as f ->
        f :: col

    | TL_and fs ->
        List.fold_left collect col fs

    | _ -> (* skip the propositional subformulas *)
        col
    in
    collect [] form


let atomic_to_expr sk ae =
    let eq0 i =
        BinEx (EQ, Var (SymbSkel.Sk.locvar sk i), IntConst 0)
    in
    let ne0 i =
        BinEx (NE, Var (SymbSkel.Sk.locvar sk i), IntConst 0)
    in
    match ae with
    | And_Keq0 is ->
        list_to_binex AND (List.map eq0 is)

    | AndOr_Kne0 ors ->
        let mk_or is = list_to_binex OR (List.map ne0 is) in
        list_to_binex AND (List.map mk_or ors)

    | Shared_Or_And_Keq0 (e, is) ->
        BinEx (OR, e, list_to_binex AND (List.map eq0 is))


let utl_k_to_expr sk form =
    let rec trans = function
    | TL_p ae ->
        (atomic_to_expr sk) ae

    | TL_F f ->
        UnEx (EVENTUALLY, trans f)

    | TL_G f ->
        UnEx (ALWAYS, trans f)

    | TL_and fs ->
        list_to_binex AND (List.map trans fs)
    in
    trans form


(** Convert an atomic formula to a string *)
let rec atomic_spec_s = function
    | And_Keq0 indices ->
        let p i = sprintf "k[%d] = 0" i in
        sprintf "(%s)" (str_join " /\\ " (List.map p indices))

    | AndOr_Kne0 disjs ->
        let p i = sprintf "k[%d] != 0" i in
        let pd indices =
            sprintf "(%s)" (str_join " \\/ " (List.map p indices))
        in
        sprintf "(%s)" (str_join " /\\ " (List.map pd disjs))

    | Shared_Or_And_Keq0 (e, is) ->
        let p i = sprintf "k[%d] = 0" i in
        let iss = str_join " /\\ " (List.map p is) in
        sprintf "(%s) \\/ (%s)" (SpinIrImp.expr_s e) iss


(** Convert a UTL formula to a string *)
let rec utl_spec_s = function
    | TL_p prop ->
        atomic_spec_s prop

    | TL_F form ->
        sprintf "F (%s)" (utl_spec_s form)

    | TL_G form ->
        sprintf "G (%s)" (utl_spec_s form)

    | TL_and forms ->
        sprintf "(%s)" (str_join " /\\ " (List.map utl_spec_s forms))


(* run the first function and if it does not fail, run the second one *)
let fail_first a b =
    let res = Lazy.force a in
    if res.m_is_err_found
    then res
    else Lazy.force b


let get_unlocked_rules sk deps uset lset invs =
    (* collect those locations
       that are required to be always zero by the invariants *)
    let collect_invs zerolocs = function
        | And_Keq0 is ->
            List.fold_left (flip IntSet.add) zerolocs is

        | _ -> zerolocs
    in
    let zerolocs = List.fold_left collect_invs IntSet.empty invs in
    let collect_enabled lst r no =
        if not (IntSet.mem r.Sk.src zerolocs) && not (IntSet.mem r.Sk.dst zerolocs)
        then no :: lst
        else lst
    in
    let enabled_nos =
        List.fold_left2 collect_enabled [] sk.Sk.rules (range 0 sk.Sk.nrules)
    in
    let unlocked_rule_nos =
        enabled_nos
            |> List.filter (PorBounds.is_rule_unlocked deps uset lset)
            |> PorBounds.pack_rule_set
            
    in
    PorBounds.unpack_rule_set unlocked_rule_nos deps.D.full_segment


(**
 The elements of the constructed partial order
 *)
type po_elem_t =
    | PO_init of utl_k_spec_t (** the initial state and the associated formulas *)
    | PO_loop_start         (** the loop start point *)
    | PO_guard of PSet.elt  (** an unlocking/locking guard *)
    | PO_tl of utl_k_spec_t   (** an extremal appearance of a temporal-logic formula *)


let po_elem_s sk = function
    | PO_guard e ->
        sprintf "C%s" (PSet.elem_str e)

    | PO_tl form ->
        sprintf "TL(%s)" (SpinIrImp.expr_s (utl_k_to_expr sk form))

    | PO_loop_start ->
        "LOOP"

    | PO_init form ->
        sprintf "INIT(%s)" (SpinIrImp.expr_s (utl_k_to_expr sk form))


let po_elem_short_s sk elem =
    let trim s =
        if 10 < (String.length s)
        then (String.sub s 0 10) ^ "..."
        else s
    in
    match elem with
    | PO_guard e ->
        sprintf "G%s" (PSet.elem_str e)

    | PO_tl form ->
        sprintf "TL(%s)" (trim (SpinIrImp.expr_s (utl_k_to_expr sk form)))

    | PO_loop_start ->
        "LOOP"

    | PO_init form ->
        sprintf "INIT(%s)" (trim (SpinIrImp.expr_s (utl_k_to_expr sk form)))


let find_schema_multiplier invs =
    let count_disjs n = function
        (* as it follows from the analysis, we need 3 * |Disjs| + 1 *)
    | AndOr_Kne0 disjs -> n + (List.length disjs)
        (* this conjunction requires less rules, not more *)
    | And_Keq0 _ -> n
        (* similar *)
    | Shared_Or_And_Keq0 _ -> n
    in
    1 + 3 * (List.fold_left count_disjs 0 invs)


let dump_counterex_to_file solver sk form_name prefix_frames loop_frames =
    let fname = sprintf "cex-%s.trx" form_name in
    let out = open_out fname in
    fprintf out "----------------\n";
    fprintf out " Counterexample\n";
    fprintf out "----------------\n";
    fprintf out "           \n";
    let prefix_len = SchemaChecker.write_counterex solver sk out prefix_frames
    in
    if loop_frames <> []
    then begin
        fprintf out "\n****** LOOP *******\n";
        ignore (SchemaChecker.write_counterex
            solver sk out loop_frames ~start_no:prefix_len)
    end;
    fprintf out "\n Gute Nacht. Spokoinoy nochi. Laku noch.\n";
    close_out out;
    printf "    > Saved counterexample to %s\n" fname


let check_one_order solver sk spec deps tac elem_order =
    let is_safety, safety_init, safety_bad =
        (* we have to treat safety differently from the general case *)
        match spec with
        | Safety (init, bad) -> true, init, bad
        | UTL _ -> false, IntConst 1, IntConst 0 
    in
    let node_type tl =
        if tl = [] then SchemaSmt.Leaf else SchemaSmt.Intermediate
    in
    let assert_propositions invs =
        tac#assert_top (List.map (atomic_to_expr sk) invs)
    in
    let print_top_frame _ =
        printf " >%d" tac#top.F.no; flush stdout;
    in
    let check_steady_schema uset lset invs =
        let not_and_keq0 = function
            | And_Keq0 _ -> false
            | _ -> true
        in
        let filtered_invs = List.filter not_and_keq0 invs in
        (* push all the unlocked rules *)
        let push_rule r =
            tac#push_rule deps sk r;
            (* the invariants And_Keq0 are treated in get_unlocked_rules *)
            if invs <> [] then assert_propositions filtered_invs
        in
        let push_schema _ =
            List.iter push_rule (get_unlocked_rules sk deps uset lset invs)
        in
        (* specifications /\_{X \subseteq Y} \/_{i \in X} k_i \ne 0
           require a schema multiplied several times *)
        BatEnum.iter push_schema (1--(find_schema_multiplier invs));
        let on_error frame_hist =
            dump_counterex_to_file solver sk "fixme" frame_hist [];
        in
        print_top_frame ();
        (* check, whether a safety property is violated *)
        if is_safety
        then if tac#check_property safety_bad on_error
            then { m_is_err_found = true; m_counterexample_filename = "fixme" }
            else { m_is_err_found = false; m_counterexample_filename = "" }
        else { m_is_err_found = false; m_counterexample_filename = "" }
    in
    let at_least_one_step_made loop_start_frame =
        (* make sure that at least one rule had a non-zero factor *)
        let in_prefix f = (f.F.no < loop_start_frame.F.no) in
        let loop_frames = BatList.drop_while in_prefix tac#frame_hist in
        let pos_factor f = BinEx (GT, Var f.F.accel_v, IntConst 0) in
        (* remove the first frame,
           as its acceleration factor still belongs to the prefix *)
        list_to_binex OR (List.map pos_factor (List.tl loop_frames))
    in
    let rec search prefix_last_frame uset lset invs = function
        | [] ->
            if is_safety
                (* no errors: we have already checked the prefix *)
            then begin
                { m_is_err_found = false; m_counterexample_filename = "" }
            end else begin
                (* close the loop *)
                let lf = get_some prefix_last_frame in
                let in_loop f = (f.F.no >= lf.F.no) in
                let loop_start_frame = List.find in_loop tac#frame_hist in
                tac#assert_frame_eq sk loop_start_frame;
                tac#assert_top [at_least_one_step_made loop_start_frame];
                printf " loop(%d)" loop_start_frame.F.no; flush stdout;
                let on_error frame_hist =
                    let prefix, loop =
                        BatList.span (fun f -> not (in_loop f)) frame_hist in
                    dump_counterex_to_file solver sk "fixme" prefix loop
                in
                if tac#check_property (IntConst 1) on_error
                then { m_is_err_found = true; m_counterexample_filename = "fixme" }
                else { m_is_err_found = false; m_counterexample_filename = "" }
            end

        | (PO_init utl_form) :: tl ->
            (* treat the initial state *)
            tac#enter_context;
            if not is_safety
            then assert_propositions (find_uncovered_utl_props utl_form)
            else if not (SpinIr.is_c_true safety_init)
                then tac#assert_top [safety_init];
                
            let new_invs = find_G_props utl_form in
            assert_propositions new_invs;
            let result =
                prune_or_continue prefix_last_frame uset lset (new_invs @ invs) (node_type tl) tl in
            tac#leave_context;
            result

        | (PO_guard id) :: tl ->
            (* An unlocking/locking guard:
               activate the context, check a schema and continue.
               This can be done only outside a loop.
             *)
            if prefix_last_frame = None
            then begin
                let is_unlocking = PSet.mem id deps.D.umask in
                let cond_expr = PSetEltMap.find id deps.D.cond_map in
                tac#enter_context;
                (* fire a sequence of rules that should unlock the condition associated with id *)
                (* TODO: alternatively, we can enforce that only one rules fires
                    and check the invariant once after the whole sequence has been
                    executed *)
                (get_unlocked_rules sk deps uset lset invs)
                    |> List.iter (tac#push_rule deps sk) ;
                (* assert that the condition is now unlocked (resp. locked) *)
                tac#assert_top [cond_expr];
                assert_propositions invs;   (* don't forget the invariants *)
                let new_uset, new_lset =
                    if is_unlocking
                    then (PSet.add id uset), lset
                    else uset, (PSet.add id lset)
                in
                let result =
                    prune_or_continue prefix_last_frame new_uset new_lset invs (node_type tl) tl in
                tac#leave_context;
                result
            end else
                search prefix_last_frame uset lset invs tl

        | PO_loop_start :: tl ->
            assert (not is_safety);
            (* TODO: check that no other guards were activated *)
            let prefix_last_frame =
                try Some tac#top
                with Failure m ->
                    printf "PO_loop_start: %s\n" m;
                    raise (Failure m)
            in
            prune_or_continue prefix_last_frame uset lset invs LoopStart tl

        | (PO_tl (TL_and fs)) :: tl ->
            (* an extreme appearance of F *)
            let props = find_uncovered_utl_props (TL_and fs) in
            tac#enter_context;
            (* the propositional subformulas should be satisfied right now *)
            tac#assert_top (List.map (atomic_to_expr sk) props);
            let new_invs = find_G_props (TL_and fs) in
            let result =
                prune_or_continue prefix_last_frame uset lset (new_invs @ invs) (node_type tl) tl
            in
            tac#leave_context;
            result

        | _ ->
            raise (Failure "Not implemented yet")

    and prune_or_continue prefix_last_frame uset lset invs node_type seq =
        (* the following reachability check does not always improve the situation *)
        if not (SchemaOpt.is_reach_opt_enabled ()) || solver#check
        then begin
            (* try to find an execution
                that does not enable new conditions and reaches a bad state *)
            tac#enter_node node_type;
            let res = fail_first
                (lazy (check_steady_schema uset lset invs))
                (lazy (search prefix_last_frame uset lset invs seq))
            in
            tac#leave_node node_type;
            res
        end else (* the current frame is unreachable *)
            { m_is_err_found = false; m_counterexample_filename = "" }
    in
    (* evaluate the order *)
    let result = search None PSet.empty PSet.empty [] elem_order in
    printf "\n"; flush stdout;
    result


(**
 Add all partial orders induced by the unlocking/locking guards.
 *)
let poset_mixin_guards deps start_pos prec_order rev_map =
    let uconds = deps.D.uconds and lconds = deps.D.lconds in
    let all_ids = List.map (fun (_, id, _, _) -> id) (uconds @ lconds) in
    (* rename the condition ids to the range 0 .. nconds - 1 *)
    let assign_num (n, map) id = (n + 1, PSetEltMap.add id n map) in
    let end_pos, enum_map = List.fold_left assign_num (start_pos, PSetEltMap.empty) all_ids in
    let get_num id =
        try PSetEltMap.find id enum_map
        with Not_found ->
            raise (Failure "Not_found in poset_mixin_guards")
    in
    let new_rev_map =
        PSetEltMap.fold (fun k v m -> IntMap.add v (PO_guard k) m) enum_map rev_map in

    (* construct the partial order *)
    let add_implications a_id implications lst =
        (* b should come before a, as a implies b *)
        let add_impl orders b_id =
            if not (PSet.elem_eq a_id b_id) && PSet.mem b_id implications
            then (get_num b_id, get_num a_id) :: orders
            else orders
        in
        List.fold_left add_impl lst all_ids
    in
    let impl_order = PSetEltMap.fold add_implications deps.D.cond_imp [] in
    let after_init lst i = (po_init, i) :: lst in
    let new_order =
        List.fold_left after_init impl_order (range start_pos end_pos) in
     end_pos, new_order @ prec_order, new_rev_map


(**
 Add all partial orders induced by the unary temporal logic.
 *)
let poset_make_utl form =
    (* positions 1 and 0 correspond to the initial state
       and the start of the loop respectively *)
    let add_empty pos map =
        IntMap.add pos [] map
    in
    let add_form pos form map =
        IntMap.add pos (form :: (IntMap.find pos map)) map
    in
    let rec make in_loop (pos, orders, map) = function
    | TL_p _ as e ->
        pos, orders, (add_form pos e map)

    | TL_and fs ->
        List.fold_left (make in_loop) (pos, orders, map) fs

    | TL_G psi ->
        let props = List.map (fun ae -> TL_p ae) (find_uncovered_utl_props psi) in
        let nm = add_form pos (TL_G (TL_and props)) map in
        (* all subformulas should be also true in the loop part *)
        make true (pos, orders, nm) psi

    | TL_F psi ->
        let new_orders =
            if in_loop
            (* pos + 1 must be in the loop *)
            then (po_loop, pos + 1) :: (pos, pos + 1) :: orders
            (* pos + 1 comes after pos *)
            else (pos, pos + 1) :: orders
        in
        make in_loop (pos + 1, new_orders, (add_empty (pos + 1) map)) psi
    in
    (* find the subformulas and compute the dependencies *)
    let n, orders, map =
        make false (po_init, [], (IntMap.singleton po_init [])) form
    in
    let remap i fs =
        if i = po_init
        then PO_init (TL_and fs)
        else PO_tl (TL_and fs)
    in
    n, orders, (IntMap.mapi remap map)


(**
  Given an element order (the elements come from a small set 0..n),
  we compute the unique fingerprint of the order.
  For the moment, we use just a simple string representation.
  *)
let compute_fingerprint order =
    let buf = BatBuffer.create (3 * (List.length order)) in
    let append is_first i =
        if not is_first
        then BatBuffer.add_char buf '.';
        BatBuffer.add_string buf (sprintf "%x" i);
        false
    in
    ignore (List.fold_left append true order);
    BatBuffer.contents buf


let enum_orders (map_fun: int -> po_elem_t) (order_fun: po_elem_t list -> 'r)
        (is_end_fun: 'r -> bool) (result: 'r ref) (iter: linord_iter_t): 'r =
    let visited = Hashtbl.create 1024 in
    let not_loop e = (e <> po_loop) in
    let not_guard num =
        match map_fun num with
        | PO_guard _ -> false
        | _ -> true
    in
    let filter_guards_after_loop order =
        if po_loop = (List.hd order)
        then List.tl order (* safety *)
        else let prefix, loop = BatList.span not_loop order in
            let floop = List.filter not_guard loop in
            prefix @ floop (* liveness *)
    in
    while not (linord_iter_is_end iter) && not (is_end_fun !result) do
        let order = BatArray.to_list (linord_iter_get iter) in
        let filtered = filter_guards_after_loop order in
        let fingerprint = compute_fingerprint filtered in
        if not (Hashtbl.mem visited fingerprint)
        then begin
            (*printf "  visiting %s\n" fingerprint;*)
            Hashtbl.add visited fingerprint 1;
            let eorder = List.map map_fun filtered in
            result := order_fun eorder;
        end;
        if not (is_end_fun !result)
        then linord_iter_next iter;
    done;
    !result


(**
  Construct the schema tree and check it on-the-fly.

  The construction is similar to compute_static_schema_tree, but is dynamic.
 *)
let gen_and_check_schemas_on_the_fly solver sk spec deps tac =
    let nelems, order, rev_map =
        match spec with
        | UTL utl_form ->
            (* add all the F-formulas to the poset *)
            let n, o, m = poset_make_utl utl_form in
            1 + n, ((po_init, po_loop) :: o), (IntMap.add po_loop PO_loop_start m)

        | Safety (_, _) ->
            (* add the initial state and the loop (the loop will be ignored) *)
            let inite = PO_init (TL_and []) in (* safety is handled explicitely *)
            (* hack: place po_loop BEFORE po_init, so the loop start does not explode
               the number of combinations *)
            2, [(po_loop, po_init)],
                (IntMap.add po_loop PO_loop_start (IntMap.singleton po_init inite))
    in
    (* add the guards *)
    let size, order, rev_map = poset_mixin_guards deps nelems order rev_map in
    let get_elem num =
        try IntMap.find num rev_map
        with Not_found ->
            raise (Failure 
                (sprintf "Not_found (key=%d) in gen_and_check_schemas_on_the_fly" num))
    in
    let pord (a, b) =
        sprintf "%s < %s" (po_elem_short_s sk (get_elem a)) (po_elem_short_s sk (get_elem b))
    in
    logtm INFO (sprintf "The partial order is:\n    %s\n\n"
        (str_join ", " (List.map pord order)));
    let ppord (a, b) = sprintf "%d < %d" a b in
    Debug.ltrace Trc.scl
        (lazy (sprintf "The partial order is:\n    %s\n\n"
            (str_join ", " (List.map ppord order))));

    let total_count = ref 0 in
    enum_orders get_elem (fun _ -> total_count := 1 + !total_count)
        (fun _ -> false) (ref ()) (linord_iter_first size order);
    logtm INFO (sprintf "%d orders to enumerate\n\n" !total_count);

    let current = ref 0 in
    let each_order eorder = 
        let pp e = sprintf "%3s" (po_elem_short_s sk e) in
        let percentage = 100 * !current / !total_count in
        printf "%3d%% -> %s...\n" percentage (str_join "  " (List.map pp eorder));
        current := 1 + !current;
        check_one_order solver sk spec deps tac eorder
    in
    (* enumerate all the linear extensions *)
    let result =
        ref { m_is_err_found = false; m_counterexample_filename = "" } in
    enum_orders get_elem each_order
        (fun r -> r.m_is_err_found) result (linord_iter_first size order)


(**
 The functions related to the conversion to an utl_k_spec_t formula.
 *)
module TL = struct
    exception Unexpected_err

    (** Subformulas of LTL(F, G, /\) *)
    type utl_sub_t =
        | Utl_F of Spin.token SpinIr.expr (* propositional *) * utl_sub_t list (* temporal *)
        | Utl_G of Spin.token SpinIr.expr (* propositional *) * utl_sub_t list (* temporal *)
    
    (** The top formula *)
    type utl_top_t =
        Spin.token SpinIr.expr (* propositional *) * utl_sub_t list (* temporal *)


    (** An atomic formula *)
    type atomic_ext_t =
        | Eq0 of int
        | Ne0 of int
        | ExtOrNe0 of int list
        | ExtAndEq0 of int list
        | ExtAndOrNe0 of int list list
        | ExtShared_Or_And_Keq0 of Spin.token SpinIr.expr list * int list
            (* looks complicated *)
        | ExtList of (Spin.token SpinIr.expr list * int list) list


    let rec utl_tab_of_expr = function
        | BinEx (EQ, _, _)
        | BinEx (NE, _, _)
        | BinEx (LT, _, _)
        | BinEx (LE, _, _)
        | BinEx (GT, _, _)
        | BinEx (GE, _, _) as prop ->
            (prop, [])

        | BinEx (OR, l, r) as exp ->
            let (lp, lt) = utl_tab_of_expr l in
            let (rp, rt) = utl_tab_of_expr r in
            if lt <> [] || rt <> []
            then raise (IllegalLtl_error
                ("A disjunction of temporal subformulas is not allowed: "
                    ^ (SpinIrImp.expr_s exp)))
            else begin
                match (lp, rp) with
                | (Nop "", r) -> (r, [])
                | (l, Nop "") -> (l, [])
                | (l, r) -> (BinEx (OR, l, r), [])
            end

        | BinEx (AND, l, r) ->
            let (lp, lt) = utl_tab_of_expr l in
            let (rp, rt) = utl_tab_of_expr r in
            begin
                match (lp, rp) with
                | (Nop "", r) -> (r, lt @ rt)
                | (l, Nop "") -> (l, lt @ rt)
                | (l, r) -> (BinEx (AND, l, r), lt @ rt)
            end

        | UnEx (EVENTUALLY, sub) ->
            let (props, temps) = utl_tab_of_expr sub in
            (Nop "", [Utl_F (props, temps)])

        | UnEx (ALWAYS, sub) ->
            let (props, temps) = utl_tab_of_expr sub in
            (Nop "", [Utl_G (props, temps)])

        | _ as exp ->
            raise (IllegalLtl_error
                ("Unexpected subformula: " ^ (SpinIrImp.expr_s exp)))


    let atomic_ext_to_utl = function
        | Eq0 i ->
            TL_p (And_Keq0 [i])

        | Ne0 i ->
            TL_p (AndOr_Kne0 [[i]])

        | ExtOrNe0 is ->
            TL_p (AndOr_Kne0 [is])

        | ExtAndEq0 is ->
            TL_p (And_Keq0 is)

        | ExtAndOrNe0 ors ->
            TL_p (AndOr_Kne0 ors)

        | ExtShared_Or_And_Keq0 (shared_es, is) ->
            TL_p (Shared_Or_And_Keq0 (list_to_binex OR shared_es, is))

        | ExtList lst ->
            let each (es, is) =
                TL_p (Shared_Or_And_Keq0 (list_to_binex OR es, is))
            in
            TL_and (List.map each lst)


    let merge_or = function
        | (Ne0 i, Ne0 j) ->
            ExtOrNe0 [i; j]

        | (ExtOrNe0 is, Ne0 j) ->
            ExtOrNe0 (j :: is)

        | (Ne0 i, ExtOrNe0 js) ->
            ExtOrNe0 (i :: js)

        | (ExtOrNe0 is, ExtOrNe0 js) ->
            ExtOrNe0 (is @ js)

        | (ExtShared_Or_And_Keq0 (es1, is1),
           ExtShared_Or_And_Keq0 (es2, is2)) ->
            ExtShared_Or_And_Keq0 (es1 @ es2, is1 @ is2)

        | (ExtShared_Or_And_Keq0 (es, is), ExtAndEq0 js) ->
            ExtShared_Or_And_Keq0 (es, is @ js)

        | (ExtAndEq0 js, ExtShared_Or_And_Keq0 (es, is)) ->
            ExtShared_Or_And_Keq0 (es, js @ is)

        | (ExtShared_Or_And_Keq0 (es, is), Eq0 j) ->
            ExtShared_Or_And_Keq0 (es, j :: is)

        | (Eq0 j, ExtShared_Or_And_Keq0 (es, is)) ->
            ExtShared_Or_And_Keq0 (es, j :: is)

        | _ ->
            raise Unexpected_err


    (* lots of rewriting rules *)
    let merge_and = function
        | (Eq0 i, Eq0 j) ->
            ExtAndEq0 [i; j]

        | (ExtAndEq0 is, Eq0 j) ->
            ExtAndEq0 (j :: is)

        | (Eq0 j, ExtAndEq0 is) ->
            ExtAndEq0 (j :: is)

        | (ExtAndEq0 is, ExtAndEq0 js) ->
            ExtAndEq0 (is @ js)

        | (ExtOrNe0 is, ExtOrNe0 js) ->
            ExtAndOrNe0 [is; js]

        | (ExtAndOrNe0 ors, ExtAndOrNe0 ors2) ->
            ExtAndOrNe0 (ors @ ors2)

        | (ExtAndOrNe0 ors, ExtOrNe0 js) ->
            ExtAndOrNe0 (js :: ors)

        | (ExtOrNe0 js, ExtAndOrNe0 ors) ->
            ExtAndOrNe0 (js :: ors)

        | (Ne0 j, ExtOrNe0 is) ->
            ExtAndOrNe0 [[j]; is]

        | (ExtOrNe0 is, Ne0 j) ->
            ExtAndOrNe0 [[j]; is]

        | (Ne0 j, ExtAndOrNe0 ors) ->
            ExtAndOrNe0 ([j] :: ors)

        | (ExtAndOrNe0 ors, Ne0 j) ->
            ExtAndOrNe0 ([j] :: ors)

        | (ExtShared_Or_And_Keq0 (es1, is1),
           ExtShared_Or_And_Keq0 (es2, is2)) ->
                ExtList [(es1, is1); (es2, is2)]

        | (ExtList lst, ExtShared_Or_And_Keq0 (es, is)) ->
                ExtList ((es, is) :: lst)

        | (ExtShared_Or_And_Keq0 (es, is), ExtList lst) ->
                ExtList ((es, is) :: lst)

        | (ExtList lst1, ExtList lst2) ->
                ExtList (lst1 @ lst2)

        | _ ->
            raise Unexpected_err


    let extract_utl sk form_exp =
        let var_to_int i v map = IntMap.add v#id i map in
        let rev_map = IntMap.fold var_to_int sk.Sk.loc_vars IntMap.empty
        in
        let rec parse_props = function
            | BinEx (NE, Var v, IntConst 0) ->
                Ne0 (IntMap.find v#id rev_map)

            | BinEx (EQ, Var v, IntConst 0) ->
                Eq0 (IntMap.find v#id rev_map)

            | BinEx (GE, Var x, e)
            | BinEx (LT, Var x, e)
            | BinEx (GT, Var x, e)
            | BinEx (LE, Var x, e) as cmp ->
                if SpinIr.expr_exists SpinIr.not_symbolic e
                then let m = sprintf "Unexpected %s in %s"
                        (SpinIrImp.expr_s e) (SpinIrImp.expr_s cmp) in
                    raise (IllegalLtl_error m)
                else ExtShared_Or_And_Keq0 ([cmp], [])

            | BinEx (OR, l, r) as expr ->
                begin
                    try merge_or (parse_props l, parse_props r)
                    with Unexpected_err ->
                        let m = sprintf "Unexpected %s in %s"
                                (SpinIrImp.expr_s expr) (SpinIrImp.expr_s form_exp) in
                        raise (IllegalLtl_error m)
                end

            | BinEx (AND, l, r) as expr ->
                begin
                    try merge_and (parse_props l, parse_props r)
                    with Unexpected_err ->
                        let m = sprintf "Unexpected %s in %s"
                                (SpinIrImp.expr_s expr) (SpinIrImp.expr_s form_exp) in
                        raise (IllegalLtl_error m)
                end
        
            | _ as e ->
                raise (IllegalLtl_error
                    (sprintf "Expected an and-or combinations of counter tests, found %s"
                        (SpinIrImp.expr_s e)))
        in
        let parse_props_p props =
            if props <> Nop ""
            then atomic_ext_to_utl (parse_props props)
            else TL_and []
        in
        let join = function
            | (TL_and [], [f]) -> f
            | (TL_p p, []) -> TL_p p
            | (TL_and [TL_and ls], rs) -> TL_and (ls @ rs)
            | (TL_and ls, rs) -> TL_and (ls @ rs)
            | (l, r) -> TL_and (l :: r)
        in
        let rec parse_tl = function
            | Utl_F (props, temps) ->
                let ps = parse_props_p props in
                let tls = List.map parse_tl temps in
                TL_F (join (ps, tls))

            | Utl_G (props, temps) ->
                let ps = parse_props_p props in
                let tls = List.map parse_tl temps in
                TL_G (join (ps, tls))
        in
        let (props, temps) = utl_tab_of_expr (Ltl.normalize_form form_exp) in
        let ps = parse_props_p props in
        let tls = List.map parse_tl temps in
        join (ps, tls)
end

let extract_utl = TL.extract_utl


let extract_safety_or_utl type_tab sk = function
    (* !(p -> [] q) *)
    | BinEx (AND, lhs, UnEx (EVENTUALLY, rhs)) as f ->
        if (Ltl.is_propositional type_tab lhs)
            && (Ltl.is_propositional type_tab rhs)
        then Safety (Ltl.normalize_form lhs, Ltl.normalize_form rhs)
        else UTL (TL.extract_utl sk f)

    (* !([] q) *)
    | UnEx (EVENTUALLY, sub) as f ->
        if (Ltl.is_propositional type_tab sub)
        then Safety (IntConst 1, Ltl.normalize_form sub)
        else UTL (TL.extract_utl sk f)

    | _ as f ->
        UTL (TL.extract_utl sk f)


let can_handle_spec type_tab sk form =
    try
        ignore (extract_safety_or_utl type_tab sk form);
        true
    with IllegalLtl_error m ->
        Debug.ltrace Trc.scl (lazy (sprintf "IllegalLtl_error: %s\n" m));
        false


let find_error rt tt sk form_name ltl_form deps =
    let check_trivial = function
    | Safety (init_form, bad_form) ->
        if SpinIr.is_c_false bad_form
        then raise (Failure
            (sprintf "%s: bad condition is trivially false" form_name));
        if SpinIr.is_c_false init_form
        then raise (Failure
            (sprintf "%s: initial condition is trivially false" form_name));

    | _ -> ()
    in
    let neg_form = Ltl.normalize_form (UnEx (NEG, ltl_form)) in
    Debug.ltrace Trc.scl
        (lazy (sprintf "neg_form = %s\n" (SpinIrImp.expr_s neg_form)));
    let spec = extract_safety_or_utl tt sk neg_form in
    check_trivial spec;

    rt#solver#push_ctx;
    rt#solver#set_need_model true;

    let ntt = tt#copy in
    let tac = new SchemaChecker.tree_tac_t rt ntt in
    let initf = F.init_frame ntt sk in
    tac#push_frame initf;
    rt#solver#comment "initial constraints from the spec";
    tac#assert_top sk.Sk.inits;

    let result = gen_and_check_schemas_on_the_fly rt#solver sk spec deps tac in
    rt#solver#set_need_model false;
    rt#solver#pop_ctx;
    result

