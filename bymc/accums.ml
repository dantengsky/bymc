(* Like batteries, but our own. Useful functions that do not fit elsewhere. *)

(* make a cartesian product of lst on itself n times *)
let rec mk_product lst n =
    if n <= 0
    then raise (Failure "mk_product: n must be positive")
    else
        if n = 1
        then List.map (fun e -> [e]) lst
        else List.concat
            (List.map (fun tuple -> List.map (fun e -> e :: tuple) lst)
                (mk_product lst (n - 1)))
;;

(* like String.join in python *)
let str_join sep list_of_strings =
    List.fold_left
        (fun res s -> if res <> "" then (res ^ sep ^ s) else res ^ s)
        "" list_of_strings
;;

(* separate a list into three parts:
    before a matching element, the matching element, the tail.
    If an element is not found, then two last resulting lists are empty.
 *)
let list_cut_general ignore_dups match_fun lst =
    List.fold_left
        (fun (hl, el, tl) e ->
            match (hl, el, tl) with
            | (_, [some], _) ->
                if not (match_fun e) || ignore_dups
                then (hl, el, tl @ [e])
                else raise (Failure
                    "list_cut found several matching elements")
            | (_, [], []) ->
                if match_fun e
                then (hl, [e], tl)
                else (hl @ [e], [], tl)
            | _ -> raise
                (Failure "Logic error: impossible combination of arguments")
        ) ([], [], []) lst
;;

let list_cut match_fun lst = list_cut_general false match_fun lst;;

let list_cut_ignore match_fun lst = list_cut_general true match_fun lst;;

(* Find the n-th element and
   return the elements before it, the element itself, and the elements after
 *)
let rec list_nth_slice lst n =
    if lst = []
    then raise (Failure (Printf.sprintf "list_nth_split: lst = [], n = %d" n));
    if n < 0 then raise (Failure "list_nth_split: n < 0");
    match n with
    | 0 -> ([], List.hd lst, List.tl lst)
    | _ ->
        let (h, e, t) = list_nth_slice (List.tl lst) (n - 1) in
        ((List.hd lst) :: h, e, t)
;;

let rec list_sub lst start len =
    match lst with
    | [] ->
        if start <> 0 || len <> 0
        then raise (Failure "list_sub: invalid start or len")
        else []
    | hd :: tl ->
        if start > 0
        then list_sub tl (start - 1) len
        else if len > 0
        then hd :: (list_sub tl 0 (len - 1))
        else []
;;

(* sort and remove duplicates, one could have used BatList.sort_unique *)
let list_sort_uniq comp_fun lst =    
    let consume_copy l cur prev =
        if (comp_fun cur prev) <> 0 then cur :: l else l in
    let no_dups =
        match List.stable_sort comp_fun lst with
        | [] -> []
        | [hd] -> [hd]
        | hd :: tl ->
                let wo_last = (hd :: (List.rev (List.tl (List.rev tl)))) in
                hd :: (List.rev (List.fold_left2 consume_copy [] tl wo_last))
    in
    no_dups
;;

(* Find the position of the first element equal to e *)
let list_find_pos e lst =
    let rec fnd = function
        | [] -> raise Not_found
        | hd :: tl ->
            if hd = e then 0 else 1 + (fnd tl)
    in
    fnd lst
;;

(* Python-like range *)                                                         
let rec range i j =
    if j <= i then [] else i :: (range (i + 1) j);;

let rec rev_range i j =
    if j <= i then [] else (j - 1) :: (rev_range i (j - 1));;

let str_contains str substr =
    let re = Str.regexp_string substr in
    try ((Str.search_forward re str 0) >= 0) with Not_found -> false;;

(*
   check two hash tables for element equality as standard "=" works
   only on the hash tables of the same capacity!
 *)
let hashtbl_eq lhs rhs =
    if (Hashtbl.length lhs) <> (Hashtbl.length rhs)
    then false
    else
        let subset_eq l r =
            Hashtbl.iter
                (fun k v ->
                    if (Hashtbl.find r k) <> v then raise Not_found
                ) l
        in
        try
            subset_eq lhs rhs;
            subset_eq rhs lhs;
            true
        with Not_found ->
            false
;;

let hashtbl_vals tbl = Hashtbl.fold (fun _ v s -> v :: s) tbl [];;

let hashtbl_keys tbl = Hashtbl.fold (fun k _ s -> k :: s) tbl [];;

let hashtbl_as_list tbl = Hashtbl.fold (fun k v s -> (k, v) :: s) tbl [];;

let hashtbl_inverse (tbl: ('a, 'b) Hashtbl.t) : (('b, 'a) Hashtbl.t) =
    let inv = Hashtbl.create (Hashtbl.length tbl) in
    Hashtbl.iter (fun k v -> Hashtbl.add inv v k) tbl;
    inv
;;

let hashtbl_filter_keys (pred: 'b -> bool) (tbl: ('a, 'b) Hashtbl.t) : ('a list) =
    let filter k v lst = if pred v then k :: lst else lst in
    Hashtbl.fold filter tbl [] 
;;

let n_copies n e =
    let rec gen = function
    | 0 -> []
    | i -> e :: (gen (i - 1))
    in
    gen n
;;

let bits_to_fit n =                                                             
    let rec f b m =
        if n <= m
        then b
        else f (b + 1) (2 * m)
    in
    f 1 2
;;

let rec ipow a n =
    if n <= 0
    then 1
    else a * (ipow a (n - 1))
;;
