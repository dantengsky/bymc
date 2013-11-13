(*
 Translating processes in SSA and encoding them in NuSMV format.
 This is the third try to create an efficient encoding in NuSMV.
 *)

open Printf

open Accums
open Cfg
open CfgSmt
open Nusmv
open Spin
open SpinIr
open SpinIrImp
open Ssa

(* ============================= utility declarations and functions *)

type proc_var_t =
    | SharedIn of var * data_type
    | SharedOut of var * data_type
    | LocalIn of var * data_type
    | LocalOut of var * data_type
    | Temp of var * data_type

let proc_var_lt a b =
    match a, b with
    | (SharedIn _, SharedOut _)
    | (SharedIn _, LocalIn _)
    | (SharedIn _, LocalOut _)
    | (SharedIn _, Temp _)
    | (SharedOut _, LocalIn _)
    | (SharedOut _, LocalOut _)
    | (SharedOut _, Temp _)
    | (LocalIn _, LocalOut _)
    | (LocalIn _, Temp _)
    | (LocalOut _, Temp _) -> true
    | (SharedIn (v, _), SharedIn (w, _))
    | (SharedOut (v, _), SharedOut (w, _))
    | (LocalIn (v, _), LocalIn (w, _))
    | (LocalOut (v, _), LocalOut (w, _))
    | (Temp (v, _), Temp (w, _)) ->
            (String.compare v#qual_name w#qual_name) < 0
    | _ -> false

let proc_var_cmp a b =
    if proc_var_lt a b
    then -1
    else if proc_var_lt b a
    then 1
    else 0


let is_var_temp = function
    | Temp _ -> true
    | _ -> false

let is_var_local = function
    | LocalIn _ -> true
    | LocalOut _ -> true
    | _ -> false

let is_var_shared_in = function
    | SharedIn _ -> true
    | _ -> false

let ptov = function
    | SharedIn (v, _)
    | SharedOut (v, _)
    | LocalIn (v, _)
    | LocalOut (v, _)
    | Temp (v, _) -> v

let ptovt = function
    | SharedIn (v, t)
    | SharedOut (v, t)
    | LocalIn (v, t)
    | LocalOut (v, t)
    | Temp (v, t) -> v, t


let strip_in s = String.sub s 0 ((String.length s) - 3 (* _IN *))
let strip_out s = String.sub s 0 ((String.length s) - 4 (* _OUT *))


let partition_var tt v =
    let is_in = (Str.last_chars v#get_name 3) = "_IN" in
    let is_out = (Str.last_chars v#get_name 4) = "_OUT" in
    let t = tt#get_type v in
    match (is_in, is_out) with
    | (true, _) ->
            if v#proc_name = "" then SharedIn (v, t) else LocalIn (v, t)
    | (_, true) ->
            if v#proc_name = "" then SharedOut (v, t) else LocalOut (v, t)
    | _ -> Temp (v, t)


let replace_with_next syms tt v =
    match partition_var tt v with
    | SharedOut (_, _) ->
        let inm = (strip_out v#get_name) ^ "_IN" in
        UnEx (NEXT, Var ((syms#lookup inm)#as_var))

    | _ -> Var v 


(* ====================== important functions *)

let module_of_proc rt prog proc =
    let vars_of_syms syms =
        let is_var s = s#get_sym_type = SymVar in
        List.map (fun s -> s#as_var) (List.filter is_var syms)
    in
    let to_ssa =
        let reg_tbl =
            (rt#caches#find_struc prog)#get_regions proc#get_name in
        let comp = reg_tbl#get "comp" proc#get_stmts in
        (* both locals and shared are the parameters of our module *)
        let locals = vars_of_syms proc#get_symbs in
        let shared = Program.get_shared prog in
        (* construct SSA as in SmtXducerPass *)
        let new_sym_tab = new symb_tab "tmp" in
        let new_type_tab = (Program.get_type_tab prog)#copy in
        let cfg =
            mk_ssa false (shared @ locals) []
                new_sym_tab new_type_tab (mk_cfg (mir_to_lir comp)) in
        let exprs =
            cfg_to_constraints proc#get_name new_sym_tab new_type_tab cfg in
        (* find the new variables *)

        (new_type_tab, new_sym_tab, List.map expr_of_m_stmt exprs)
    in
    let ntt, syms, exprs = to_ssa in
    let new_vars = vars_of_syms syms#get_symbs in
    let exprs = List.map (map_vars (replace_with_next syms ntt)) exprs in
    let pvars = List.sort proc_var_cmp (List.map (partition_var ntt) new_vars) in
    let temps = List.filter is_var_temp pvars in
    let args =
        List.filter (fun pv -> is_var_local pv || is_var_shared_in pv) pvars in
    let mod_type =
        SModule (proc#get_name,
            List.map ptov args, [SVar (List.map ptovt temps); STrans exprs])
    in
    (mod_type, args)


let create_proc_mods rt intabs_prog =
    let transform_proc (globals, main_sects) p =
        let mod_type, args = module_of_proc rt intabs_prog p in
        let to_param = function
            | SharedIn (v, t) -> (v#copy (strip_in v#get_name), t)
            | SharedOut (v, t) -> (v#copy (strip_out v#get_name), t)
            | LocalIn (v, t) -> raise (Failure ("Unexpected LocalIn"))
            | LocalOut (v, t) -> (v#copy (strip_out v#get_name), t)
            | _ -> raise (Failure ("Unexpected param type"))
        in
        let params = List.map to_param args in
        let inst = SModInst("p_" ^ p#get_name, p#get_name,
            (List.map (fun (v, _) -> Var v) params))
        in
        let locals = List.filter (fun (v, _) -> v#proc_name <> "") params in
        (mod_type :: globals, (SVar locals) :: inst :: main_sects)
    in
    let procs = Program.get_procs intabs_prog in
    let tt = Program.get_type_tab intabs_prog in
    let globals, main_sects = List.fold_left transform_proc ([], []) procs in
    let shared =
        List.map (fun v -> (v, tt#get_type v)) (Program.get_shared intabs_prog)
    in
    ((SVar shared) :: main_sects, globals)


(* partially copied from nusmvCounterClusterPass *)
(* TODO: deal with many process types *)
let module_of_counter rt ctrabs_prog p =
    let ctr_ctx = rt#caches#analysis#get_pia_ctr_ctx_tbl#get_ctx p#get_name in
    let dom = rt#caches#analysis#get_pia_dom in
    let tt = Program.get_type_tab ctrabs_prog in
    let dec_tbl =
        NusmvCounterClusterPass.collect_rhs rt#solver tt dom ctr_ctx PLUS in
    let inc_tbl =
        NusmvCounterClusterPass.collect_rhs rt#solver tt dom ctr_ctx MINUS in
    let prev_locals = List.map fst ctr_ctx#prev_next_pairs in
    let next_locals = List.map snd ctr_ctx#prev_next_pairs in
    let my_var v = v#copy ("my_" ^ v#get_name) in
    let cmp_idx join cmp vars =
        let f pv v = BinEx (cmp, Var v, Var (my_var pv)) in
        list_to_binex join (List.map2 f prev_locals vars)
    in
    let prev_eq = cmp_idx AND EQ prev_locals in
    let prev_ne = cmp_idx OR NE prev_locals in
    let next_eq = cmp_idx AND EQ next_locals in
    let next_ne = cmp_idx OR NE next_locals in
    let myval = new_var "myval" in
    let mk_case prev_ex next_ex prev_val next_vals =
        let guard = BinEx (AND, BinEx (AND, prev_ex, next_ex),
                                BinEx (EQ, Var myval, Const prev_val)) in
        let rhs = List.map (fun i -> Const i) next_vals in
        (guard, rhs)
    in
    let prev_cases = hashtbl_map (mk_case prev_eq next_ne) dec_tbl in
    let next_cases = hashtbl_map (mk_case prev_ne next_eq) inc_tbl in
    let cases = prev_cases @ next_cases @
        [(Var nusmv_true, [Var myval])] in
    let choice = SAssign [ANext (myval, cases)] in
    let args =
        myval :: (List.map my_var prev_locals)
            @ prev_locals @ next_locals
    in 
    SModule ("Counter" ^ p#get_name, args, [choice])


let create_counter_mods rt ctrabs_prog =
    let dom = rt#caches#analysis#get_pia_dom in
    let create_vars l p =
        let ctr_ctx =
            rt#caches#analysis#get_pia_ctr_ctx_tbl#get_ctx p#get_name
        in
        let prev = List.map fst ctr_ctx#prev_next_pairs in
        let next = List.map snd ctr_ctx#prev_next_pairs in
        let ctr = ctr_ctx#get_ctr in
        let tp = new data_type SpinTypes.TINT in
        tp#set_range 0 dom#length;
        let per_idx l idx =
            let myctr = ctr#copy (sprintf "%s%d" ctr#get_name idx) in
            let valtab = ctr_ctx#unpack_from_const idx in
            let get_val v = Const (Hashtbl.find valtab v) in
            let tov v = Var v in
            let params =
                [tov myctr] @ (List.map get_val prev)
                @ (List.map tov prev) @ (List.map tov next) in
            (SVar [(myctr, tp)])
            :: (SModInst( (sprintf "p_%s%d" ctr#get_name idx),
                     "Counter" ^ p#get_name, params))
            :: l
        in
        List.fold_left per_idx
            l (ctr_ctx#all_indices_for (fun _ -> true))
    in
    let procs = Program.get_procs ctrabs_prog in
    let main_sects = List.fold_left create_vars [] procs in
    let mods = List.map (module_of_counter rt ctrabs_prog) procs in
    (main_sects, mods)


let transform rt out_name intabs_prog ctrabs_prog =
    let out = open_out (out_name ^ ".smv") in
    let main_sects, proc_mod_defs = create_proc_mods rt intabs_prog in
    let ctr_main, ctr_mods = create_counter_mods rt ctrabs_prog in
    let tops = SModule ("main", [], main_sects @ ctr_main)
        :: proc_mod_defs @ ctr_mods in
    List.iter (fun t -> fprintf out "%s\n" (top_s t)) tops;
    close_out out
