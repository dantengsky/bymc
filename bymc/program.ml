open SpinIr

module StringMap = Map.Make (String)

type expr_t = Spin.token expr

exception Program_error of string

type program = {
    f_params: var list; f_shared: var list; f_instrumental: var list;
    f_sym_tab: symb_tab; (* kept internally *)
    f_type_tab: data_type_tab;
    f_assumes: expr_t list; f_unsafes: string list;
    f_procs: Spin.token proc list;
    f_atomics: Spin.token atomic_expr StringMap.t;
    f_ltl_forms: expr_t StringMap.t
}

let empty = {
    f_params = []; f_shared = []; f_instrumental = [];
    f_sym_tab = new symb_tab ""; (* global scope *)
    f_type_tab = new data_type_tab;
    f_assumes = []; f_procs = []; f_unsafes = [];
    f_atomics = StringMap.empty; f_ltl_forms = StringMap.empty
}

let update_sym_tab prog =
    let var_to_symb v = (v :> symb) in
    let proc_to_symb p = (p :> symb) in (* can we reuse var_to_symb? *)
    let string_to_symb s = new symb(s) in
    let map_to_symb m =
        List.map (fun (k, _) -> string_to_symb k) (StringMap.bindings m) in
    let syms =
        (List.map var_to_symb prog.f_params)
        @ (List.map var_to_symb prog.f_shared)
        @ (List.map var_to_symb prog.f_instrumental)
        @ (List.map proc_to_symb prog.f_procs)
        @ (map_to_symb prog.f_atomics)
        @ (map_to_symb prog.f_ltl_forms)
    in
    prog.f_sym_tab#set_syms syms;
    (* XXX: processes are not copied but their attributes are updated! *)
    let update_proc_tab p = p#set_parent prog.f_sym_tab in
    List.iter update_proc_tab prog.f_procs;
    prog

let get_params prog =
    prog.f_params

let set_params new_params prog =
    update_sym_tab { prog with f_params = new_params }

let get_shared prog =
    prog.f_shared

let set_shared new_shared prog =
    update_sym_tab { prog with f_shared = new_shared }

let get_instrumental prog =
    prog.f_instrumental

let set_instrumental new_instr prog =
    update_sym_tab { prog with f_instrumental = new_instr }

let get_type prog variable =
    try prog.f_type_tab#get_type variable
    with Not_found ->
        raise (Program_error ("No data type for variable " ^ variable#get_name))

let set_type_tab type_tab prog =
    { prog with f_type_tab = type_tab }

let get_type_tab prog =
    prog.f_type_tab

(* no set_sym_tab: it is updated automatically *)
let get_sym_tab prog =
    prog.f_sym_tab

let get_assumes prog = prog.f_assumes
let set_assumes new_assumes prog = {prog with f_assumes = new_assumes}

let get_unsafes prog = prog.f_unsafes
let set_unsafes new_unsafes prog = {prog with f_unsafes = new_unsafes}

let get_procs prog = prog.f_procs

let set_procs new_procs prog =
    update_sym_tab { prog with f_procs = new_procs }

let get_atomics prog = prog.f_atomics

let set_atomics new_atomics prog =
    update_sym_tab { prog with f_atomics = new_atomics }

let get_ltl_forms prog =
    prog.f_ltl_forms

let set_ltl_forms new_ltl_forms prog =
    update_sym_tab { prog with f_ltl_forms = new_ltl_forms }

let get_ltl_forms_as_hash prog =
    let h = Hashtbl.create 10 in
    let to_hash name form = Hashtbl.add h name form in
    let _ = StringMap.mapi to_hash prog.f_ltl_forms in
    h

let is_global prog v =
    try v = (List.find ((=) v) (prog.f_params @ prog.f_shared))
    with Not_found -> false

let is_not_global prog v =
    not (is_global prog v)

let get_all_locals prog =
    let collect lst = function
    | MDecl (_, v, _) -> v :: lst
    | _ -> lst
    in
    let collect_proc lst p =
        List.fold_left collect lst p#get_stmts
    in
    List.fold_left collect_proc [] prog.f_procs


let program_of_units type_tab units =
    let fold_u prog = function
    | Stmt (MDecl(_, v, _)) ->
            if v#is_symbolic
            then { prog with f_params = (v :: prog.f_params) }
            else if v#is_instrumental
            then { prog with f_instrumental = (v :: prog.f_instrumental) }
            else { prog with f_shared = (v :: prog.f_shared) }
    | Stmt (MDeclProp(_, v, e)) ->
            let new_ap = (StringMap.add v#get_name e prog.f_atomics) in
            { prog with f_atomics = new_ap }
    | Stmt (MAssume(_, e)) ->
            { prog with f_assumes = (e :: prog.f_assumes) }
    | Stmt (MUnsafe(_, s)) ->
            { prog with f_unsafes = (s :: prog.f_unsafes) }
    | Stmt (_ as s) ->
            raise (Program_error
                ("Unexpected top-level statement: " ^ (SpinIrImp.mir_stmt_s s)))
    | Proc p ->
            { prog with f_procs = p :: prog.f_procs }
    | Ltl (name, ltl_form) ->
            let new_fs = (StringMap.add name ltl_form prog.f_ltl_forms) in
            { prog with f_ltl_forms = new_fs }
    | None ->
            prog
    in
    let prog = List.fold_left fold_u empty (List.rev units) in
    update_sym_tab { prog with f_type_tab = type_tab }


let units_of_program program =
    let var_to_decl v =
        Stmt (MDecl (fresh_id (), v, (Nop ""))) in
    let atomic_to_decl name expr accum =
        (Stmt (MDeclProp(fresh_id (), new_var name, expr))) :: accum in
    let form_to_ltl name expr accum =
        (Ltl(name, expr)) :: accum in
    let to_assume e = Stmt (MAssume(fresh_id (), e)) in
    let to_unsafe e = Stmt (MUnsafe(fresh_id (), e)) in
    let to_proc p = Proc p in
    (List.concat
        [(List.map var_to_decl program.f_params);
         (List.map var_to_decl program.f_shared);
         (List.map var_to_decl program.f_instrumental);
         (StringMap.fold atomic_to_decl program.f_atomics []);
         (List.map to_assume program.f_assumes);
         (List.map to_unsafe program.f_unsafes);
         (List.map to_proc program.f_procs);
         (StringMap.fold form_to_ltl program.f_ltl_forms [])])


let run_smt_solver prog =
    let smt_of_asrt e =
        Printf.sprintf "(assert %s)" (Smt.expr_to_smt e) in
    let var_to_smt v =
        let tp = get_type prog v in
        Smt.var_to_smt v tp in
    let smt_exprs =
        List.append
            (List.map var_to_smt (get_params prog))
            (List.map smt_of_asrt (get_assumes prog))
    in
    let solver = new Smt.yices_smt in
    solver#start;
    (* solver#set_debug true; *) (* see yices.log *)
    List.iter solver#append smt_exprs;
    solver

