/* OCaml version of the Promela parser                  */
/* Adapted from the original yacc grammar of Spin 6.0.1 */
/* Igor Konnov 2012                                     */

/***** spin: spin.y *****/

/* Copyright (c) 1989-2003 by Lucent Technologies, Bell Laboratories.     */
/* All Rights Reserved.  This software is for educational purposes only.  */
/* No guarantee whatsoever is expressed or implied by the distribution of */
/* this code.  Permission is given to distribute this code provided that  */
/* this introductory message is not removed and no monies are exchanged.  */
/* Software written by Gerard J. Holzmann.  For tool documentation see:   */
/*             http://spinroot.com/                                       */
/* Send all bug-reports and/or questions to: bugs@spinroot.com            */

%{

(*
#include "spin.h"
#include <sys/types.h>
#include <unistd.h>
#include <stdarg.h>

#define YYDEBUG	0
#define Stop	nn(ZN,'@',ZN,ZN)
#define PART0	"place initialized var decl of "
#define PART1	"place initialized chan decl of "
#define PART2	" at start of proctype "

static	Lextok *ltl_to_string(Lextok * );

extern  Symbol	*context, *owner;
extern	Lextok *for_body(Lextok *, int);
extern	void for_setup(Lextok *, Lextok *, Lextok * );
extern	Lextok *for_index(Lextok *, Lextok * );
extern	Lextok *sel_index(Lextok *, Lextok *, Lextok * );
extern  int	u_sync, u_async, dumptab, scope_level;
extern	int	initialization_ok, split_decl;
extern	short	has_sorted, has_random, has_enabled, has_pcvalue, has_np;
extern	short	has_code, has_state, has_io;
extern	void	count_runs(Lextok * );
extern	void	no_internals(Lextok * );
extern	void	any_runs(Lextok * );
extern	void	ltl_list(char *, char * );
extern	void	validref(Lextok *, Lextok * );
extern	char	yytext[];

int	Mpars = 0;	/* max nr of message parameters  */
int	nclaims = 0;	/* nr of never claims */
int	ltl_mode = 0;	/* set when parsing an ltl formula */
int	Expand_Ok = 0, realread = 1, IArgs = 0, NamesNotAdded = 0;
int	in_for = 0;
char	*claimproc = (char * ) 0;
char	*eventmap = (char * ) 0;
static	char *ltl_name;

static	int	Embedded = 0, inEventMap = 0, has_ini = 0;
*)

open Printf;;

open Lexing;;
open Spin_ir;;

exception Not_implemented of string;;
exception Parse_error of string;;

(* we have to declare global objects, think of resetting them afterwards! *)
let err_cnt = ref 0;;
let stmt_cnt = ref 0;;
let met_else = ref false;;
let labels = Hashtbl.create 10;;
let fwd_labels = Hashtbl.create 10;;
let lab_stack = ref [];;
let global_scope = new symb_tab;;
let current_scope = ref global_scope;;

let new_id () =
    let id = !stmt_cnt in
    stmt_cnt := !stmt_cnt + 1;
    id
;;

let push_new_labs () =
    let e = mk_uniq_label () in (* one label for entry to do *)
    let b = mk_uniq_label () in (* one label to break from do/if *)
    lab_stack := (e, b) :: !lab_stack
;;

let pop_labs () = lab_stack := List.tl !lab_stack ;;

let top_labs () = List.hd !lab_stack;;

(* it uses tokens, so we cannot move it outside *)
let rec is_expr_symbolic e =
    match e with
    | Const _ -> true
    | Var v -> v#is_symbolic
    | UnEx (op, se) -> op = UMIN && is_expr_symbolic se
    | BinEx (op, le, re) ->
        (List.mem op [PLUS; MINUS; MULT; DIV; MOD])
            && (is_expr_symbolic le) && (is_expr_symbolic re)
    | _ -> false
;;

let curr_pos () =
    let p = Parsing.symbol_start_pos () in
    let fname = if p.pos_fname != "" then p.pos_fname else "<filename>" in
    let col = max (p.pos_cnum - p.pos_bol + 1) 1 in
    (fname, p.pos_lnum, col)
;;

let parse_error s =
    let f, l, c = curr_pos() in
    Printf.printf "%s:%d,%d %s\n" f l c s;
    err_cnt := !err_cnt + 1
;;

let fatal msg payload =
    let f, l, c = curr_pos() in
    raise (Failure (Printf.sprintf "%s:%d,%d %s %s\n" f l c msg payload))
;;
%}

%token	ASSERT PRINT PRINTM
%token	C_CODE C_DECL C_EXPR C_STATE C_TRACK
%token	RUN LEN ENABLED EVAL PC_VAL
%token	TYPEDEF MTYPE INLINE LABEL OF
%token	GOTO BREAK ELSE SEMI
%token	IF FI DO OD FOR SELECT IN SEP DOTDOT
%token	ATOMIC NON_ATOMIC D_STEP UNLESS
%token  TIMEOUT NONPROGRESS
%token	ACTIVE PROCTYPE D_PROCTYPE
%token	HIDDEN SHOW ISLOCAL
%token	PRIORITY PROVIDED
%token	FULL EMPTY NFULL NEMPTY
%token	<int> CONST                 /* val */
%token  <Spin_types.var_type> TYPE
%token  <Spin_types.xu_type> XU			    /* val */
%token	<string> NAME
%token  <string> UNAME
%token  <string> PNAME
%token  <string> INAME		        /* sym */
%token	<string> STRING
%token  CLAIM TRACE INIT	LTL	/* sym */
%token  NE EQ LT GT LE GE OR AND BITNOT BITOR BITXOR BITAND ASGN
%token  MULT PLUS MINUS DIV MOD DECR INCR
%token  LSHIFT RSHIFT
%token  COLON DOT COMMA LPAREN RPAREN LBRACE RBRACE LCURLY RCURLY
%token  O_SND SND RCV R_RCV AT
%token  NEVER NOTRACE TRACE ASSERT
%token  <string * string> DEFINE
%token  <string> INCLUDE
%token  MACRO_IF MACRO_IFDEF MACRO_ELSE MACRO_ENDIF
%token  <string> MACRO_OTHER
%token  EOF
/* FORSYTE extensions { */
%token  ASSUME SYMBOLIC ALL SOME
/* FORSYTE extensions } */
/* imaginary tokens */
%token  UMIN NEG VARREF ARRAY_DEREF

%right	ASGN
%left	SND O_SND RCV R_RCV     /* SND doubles as boolean negation */
%left	IMPLIES EQUIV			/* ltl */
%left	OR
%left	AND
%left	ALWAYS EVENTUALLY		    /* ltl */
%left	UNTIL WEAK_UNTIL RELEASE	/* ltl */
%right	NEXT				        /* ltl */
%left	BITOR BITXOR BITAND
%left	EQ NE
%left	GT LT GE LE
%left	LSHIFT RSHIFT
%left	PLUS MINUS
%left	MULT DIV MOD
%left	INCR DECR
%right	NEG UMIN BITNOT
%left	DOT
%start program
%type <token Spin_ir.prog_unit list> program
%%

/** PROMELA Grammar Rules **/

program	: units	EOF { $1 }
	;

units	: unit      { $1 }
    | units unit    { List.append $1 $2 }
	;

unit	: proc	/* proctype        */    { [Proc $1] }
    | init		/* init            */    { [] }
	| claim		/* never claim        */ { [] }
	| ltl		/* ltl formula        */ { [] }
	| events	/* event assertions   */ { [] }
	| one_decl	/* variables, chans   */ { List.map (fun e -> Stmt e) $1 }
	| utype		/* user defined types */ { [] }
	| c_fcts	/* c functions etc.   */ { [] }
	| ns		/* named sequence     */ { [] }
	| SEMI		/* optional separator */ { [] }
    /* FORSYTE extensions */
    | prop_decl /* atomic propositions */ { [Stmt $1] }
	| ASSUME full_expr /* assumptions */
        {
            [Stmt (MAssume (new_id (), $2))]
        }
	| error { fatal "Unexpected top-level statement" ""}
	;

proc	: inst		/* optional instantiator */
	  proctype NAME	/* { 
          (*
			  setptype($3, PROCTYPE, ZN);
			  setpname($3);
			  context = $3->sym;
			  context->ini = $2; (* linenr and file *)
			  Expand_Ok++; (* expand struct names in decl *)
			  has_ini = 0;
          *)
			} */
	  LPAREN decl RPAREN	/* { (* Expand_Ok--;
			  if (has_ini)
			  fatal("initializer in parameter list", (char * ) 0); *)
			} */
	  Opt_priority
	  Opt_enabler
	  body	{
                let p = new proc $3 $1 in
                let unpack e =
                    match e with    
                    | MDecl (_, v, i) -> v#add_flag HFormalPar; v
                    | _ -> fatal "Not a decl in proctype args" p#get_name
                in
                p#set_args (List.map unpack $5);
                p#set_stmts $9;
                p#add_all_symbs !current_scope;
                current_scope := global_scope;
                p
               (* ProcList *rl;
                  if ($1 != ZN && $1->val > 0)
                  {	int j;
                    rl = ready($3->sym, $6, $11->sq, $2->val, $10, A_PROC);
                    for (j = 0; j < $1->val; j++)
                    {	runnable(rl, $9?$9->val:1, 1);
                    }
                    announce(":root:");
                    if (dumptab) $3->sym->ini = $1;
                  } else
                  {	rl = ready($3->sym, $6, $11->sq, $2->val, $10, P_PROC);
                  }
                  if (rl && has_ini == 1)	/* global initializations, unsafe */
                  {	/* printf("proctype %s has initialized data\n",
                        $3->sym->name);
                     */
                    rl->unsafe = 1;
                  }
                  context = ZS; *)
                }
        ;

    proctype: PROCTYPE	{
            current_scope := new symb_tab;
            !current_scope#set_parent global_scope
            (* $$ = nn(ZN,CONST,ZN,ZN); $$->val = 0; *) }
        | D_PROCTYPE	{
            current_scope := new symb_tab;
            (* $$ = nn(ZN,CONST,ZN,ZN); $$->val = 1; *) }
        ;

    inst	: /* empty */	{ Const 0 }
        | ACTIVE	{ Const 1 }
        /* FORSYTE extension: any constant + a symbolic arith expression */
        | ACTIVE LBRACE expr RBRACE {
                match $3 with
                | Const i -> Const i
                | Var v ->
                    if (v#get_ini > 0)
                    then Const v#get_ini
                    else fatal "need constant initializer for" v#get_name
                | _ -> if is_expr_symbolic $3 then $3 else
                    fatal "active [..] must be constant or symbolic" ""
            }
        ;

    init	: INIT		/* { (* context = $1->sym; *) } */
          Opt_priority
          body		{ (* ProcList *rl;
                  rl = ready(context, ZN, $4->sq, 0, ZN, I_PROC);
                  runnable(rl, $3?$3->val:1, 1);
                  announce(":root:");
                  context = ZS; *)
                    }
        ;

    ltl	: LTL optname2		/* { (* ltl_mode = 1; ltl_name = $2->sym->name; *) } */
          ltl_body		{ (* if ($4) ltl_list($2->sym->name, $4->sym->name);
                  ltl_mode = 0; *)
                }
        ;

    ltl_body: LCURLY full_expr OS RCURLY { (* $$ = ltl_to_string($2); *) }
        | error		{ (* $$ = NULL; *) }
        ;

    claim	: CLAIM	optname	/* { (* if ($2 != ZN)
                  {	$1->sym = $2->sym;	(* new 5.3.0 *)
                  }
                  nclaims++;
                  context = $1->sym;
                  if (claimproc && !strcmp(claimproc, $1->sym->name))
                  {	fatal("claim %s redefined", claimproc);
                  }
                  claimproc = $1->sym->name; *)
                } */
          body		{ (* (void) ready($1->sym, ZN, $4->sq, 0, ZN, N_CLAIM);
                      context = ZS; *)
                    }
        ;

    optname : /* empty */	{ (* char tb[32];
                  memset(tb, 0, 32);
                  sprintf(tb, "never_%d", nclaims);
                  $$ = nn(ZN, NAME, ZN, ZN);
                  $$->sym = lookup(tb); *)
                }
        | NAME		{ (* $$ = $1; *) }
        ;

    optname2 : /* empty */ { (* char tb[32]; static int nltl = 0;
                  memset(tb, 0, 32);
                  sprintf(tb, "ltl_%d", nltl++);
                  $$ = nn(ZN, NAME, ZN, ZN);
                  $$->sym = lookup(tb); *)
                }
        | NAME		{ (* $$ = $1; *) }
        ;

    events : TRACE	/* { (* context = $1->sym;
                  if (eventmap)
                    non_fatal("trace %s redefined", eventmap);
                  eventmap = $1->sym->name;
                  inEventMap++; *)
                } */
          body	{ raise (Not_implemented "TRACE")
                (*
                  if (strcmp($1->sym->name, ":trace:") == 0)
                  {	(void) ready($1->sym, ZN, $3->sq, 0, ZN, E_TRACE);
                  } else
                  {	(void) ready($1->sym, ZN, $3->sq, 0, ZN, N_TRACE);
                  }
                      context = ZS;
                  inEventMap--; *)
                }
        ;

    utype	: TYPEDEF NAME	/*	{ (* if (context)
                       fatal("typedef %s must be global",
                            $2->sym->name);
                       owner = $2->sym; *)
                    } */
          LCURLY decl_lst LCURLY	{
                    raise (Not_implemented "typedef is not supported")
                 (* setuname($5); owner = ZS; *) }
        ;

    nm	: NAME			{ (* $$ = $1; *) }
        | INAME			{ (* $$ = $1;
                      if (IArgs)
                      fatal("invalid use of '%s'", $1->sym->name); *)
                    }
        ;

    ns	: INLINE nm LPAREN		/* { (* NamesNotAdded++; *) } */
          args RPAREN		{
                        raise (Not_implemented "inline")
                   (* prep_inline($2->sym, $5);
                      NamesNotAdded--; *)
                    }
        ;

    c_fcts	: ccode			{
                        raise (Not_implemented "c_fcts")
                      (* leaves pseudo-inlines with sym of
                       * type CODE_FRAG or CODE_DECL in global context
                       *)
                    }
        | cstate {}
        ;

    cstate	: C_STATE STRING STRING	{
                     raise (Not_implemented "c_state")
                    (*
                      c_state($2->sym, $3->sym, ZS);
                      has_code = has_state = 1; *)
                    }
        | C_TRACK STRING STRING {
                     raise (Not_implemented "c_track")
                     (*
                      c_track($2->sym, $3->sym, ZS);
                      has_code = has_state = 1; *)
                    }
        | C_STATE STRING STRING	STRING {
                     raise (Not_implemented "c_state")
                     (*
                      c_state($2->sym, $3->sym, $4->sym);
                      has_code = has_state = 1; *)
                    }
        | C_TRACK STRING STRING STRING {
                     raise (Not_implemented "c_track")
                     (*
                      c_track($2->sym, $3->sym, $4->sym);
                      has_code = has_state = 1; *)
                    }
        ;

    ccode	: C_CODE {
                     raise (Not_implemented "c_code")
                     (* Symbol *s;
                      NamesNotAdded++;
                      s = prep_inline(ZS, ZN);
                      NamesNotAdded--;
                      $$ = nn(ZN, C_CODE, ZN, ZN);
                      $$->sym = s;
                      has_code = 1; *)
                    }
        | C_DECL		{
                     raise (Not_implemented "c_decl")
                     (* Symbol *s;
                      NamesNotAdded++;
                      s = prep_inline(ZS, ZN);
                      NamesNotAdded--;
                      s->type = CODE_DECL;
                      $$ = nn(ZN, C_CODE, ZN, ZN);
                      $$->sym = s;
                      has_code = 1; *)
                    }
        ;
    cexpr	: C_EXPR	{
                     raise (Not_implemented "c_expr")
                     (* Symbol *s;
                      NamesNotAdded++;
                      s = prep_inline(ZS, ZN);
                      NamesNotAdded--;
                      $$ = nn(ZN, C_EXPR, ZN, ZN);
                      $$->sym = s;
                      no_side_effects(s->name);
                      has_code = 1; *)
                    }
        ;

    body	: LCURLY			/* { (* open_seq(1); *) } */
              sequence OS	/* { (* add_seq(Stop); *) } */
              RCURLY			{
                  $2
               (* $$->sq = close_seq(0);
                  if (scope_level != 0)
                  {	non_fatal("missing '}' ?", 0);
                    scope_level = 0;
                  } *)
                }
        ;

    sequence: step			{ $1 }
        | sequence MS step	{ List.append $1 $3 }
        ;

    step    : one_decl		{ $1 }
        | XU vref_lst		{ raise (Not_implemented "XU vref_lst")
            (* setxus($2, $1->val); $$ = ZN; *) }
        | NAME COLON one_decl	{ fatal "label preceding declaration," "" }
        | NAME COLON XU		{ fatal "label predecing xr/xs claim," "" }
        | stmnt			    { $1 }
        | stmnt UNLESS stmnt	{ raise (Not_implemented "unless") }
        ;

    vis	: /* empty */	{ HNone }
        | HIDDEN		{ HHide }
        | SHOW			{ HShow }
        | ISLOCAL		{ HTreatLocal }
        | SYMBOLIC      { HSymbolic }
        ;

    asgn:	/* empty */ {}
        | ASGN {}
        ;

    one_decl: vis TYPE var_list	{
            let f = $1 and t = $2 in
            let ds = (List.map
                (fun (v, i) ->
                    v#add_flag f; v#set_type t; MDecl(new_id (), v, i)) $3) in
            List.iter
                (fun d ->
                    match d with
                    | MDecl(_, v, i) ->
                            !current_scope#add_symb v#get_name (v :> symb)
                    | _ -> raise (Failure "Not a Decl")
                )
                ds;
            ds
           (* setptype($3, $2->val, $1);
              $$ = $3; *)
        }
        | vis UNAME var_list	{
                      raise (Not_implemented "variables of user-defined types")
                   (* setutype($3, $2->sym, $1);
                      $$ = expand($3, Expand_Ok); *)
                    }
        | vis TYPE asgn LCURLY nlst RCURLY {
                      raise (Not_implemented "mtype = {...}")
                     (*
                      if ($2->val != MTYPE)
                        fatal("malformed declaration", 0);
                      setmtype($5);
                      if ($1)
                        non_fatal("cannot %s mtype (ignored)",
                            $1->sym->name);
                      if (context != ZS)
                        fatal("mtype declaration must be global", 0); *)
                    }
        ;

    decl_lst: one_decl       	{ $1 }
        | one_decl SEMI
          decl_lst		        { $1 @ $3 }
        ;

    decl    : /* empty */		{ [] }
        | decl_lst      	    { $1 }
        ;

    vref_lst: varref		{ (* $$ = nn($1, XU, $1, ZN); *) }
        | varref COMMA vref_lst	{ (* $$ = nn($1, XU, $1, $3); *) }
        ;

    var_list: ivar              { [$1] }
        | ivar COMMA var_list	{ $1 :: $3 }
        ;

    ivar    : vardcl           	{ ($1, Nop) }
        | vardcl ASGN expr   	{
            ($1, $3)
            (* $$ = $1;
              $1->sym->ini = $3;
              trackvar($1,$3);
              if ($3->ntyp == CONST
              || ($3->ntyp == NAME && $3->sym->context))
              {	has_ini = 2; /* local init */
              } else
              {	has_ini = 1; /* possibly global */
              }
              if (!initialization_ok && split_decl)
              {	nochan_manip($1, $3, 0);
                no_internals($1);
                non_fatal(PART0 "'%s'" PART2, $1->sym->name);
              } *)
            }
        | vardcl ASGN ch_init	{
              raise (Not_implemented "var = ch_init")
           (* $1->sym->ini = $3;
              $$ = $1; has_ini = 1;
              if (!initialization_ok && split_decl)
              {	non_fatal(PART1 "'%s'" PART2, $1->sym->name);
              } *)
            }
        ;

    ch_init : LBRACE CONST RBRACE OF
          LCURLY typ_list RCURLY	{
                     raise (Not_implemented "channels")
                   (* if ($2->val) u_async++;
                      else u_sync++;
                          {	int i = cnt_mpars($6);
                        Mpars = max(Mpars, i);
                      }
                          $$ = nn(ZN, CHAN, ZN, $6);
                      $$->val = $2->val; *)
                        }
        ;

    vardcl  : NAME  		{ new var $1 }
        | NAME COLON CONST	{
            let v = new var $1 in
            v#set_nbits $3;
            v
            (* $1->sym->nbits = $3->val;
              if ($3->val >= 8*sizeof(long))
              {	non_fatal("width-field %s too large",
                    $1->sym->name);
                $3->val = 8*sizeof(long)-1;
              }
              $1->sym->nel = 1; $$ = $1; *)
            }
        | NAME LBRACE CONST RBRACE	{
            let v = new var $1 in
            v#set_isarray true;
            v#set_num_elems $3;
            v
            }
        ;

    varref	: cmpnd		{ $1 (* $$ = mk_explicit($1, Expand_Ok, NAME); *) }
        ;

    pfld	: NAME {
                (!current_scope#lookup $1)#as_var
                   (* $$ = nn($1, NAME, ZN, ZN);
                      if ($1->sym->isarray && !in_for)
                      {	non_fatal("missing array index for '%s'",
                            $1->sym->name);
                      } *)
                }
        | NAME			/* { (* owner = ZS; *) } */
          LBRACE expr RBRACE
                { raise (Not_implemented
                    "Array references, e.g., x[y] are not implemented") }
        ;

    cmpnd	: pfld			/* { (* Embedded++;
                      if ($1->sym->type == STRUCT)
                        owner = $1->sym->Snm; *)
                    } */
          sfld
                {  $1
                   (* $$ = $1; $$->rgt = $3;
                      if ($3 && $1->sym->type != STRUCT)
                        $1->sym->type = STRUCT;
                      Embedded--;
                      if (!Embedded && !NamesNotAdded
                      &&  !$1->sym->type)
                       fatal("undeclared variable: %s",
                            $1->sym->name);
                      if ($3) validref($1, $3->lft);
                      owner = ZS; *)
                    }
        ;

    sfld	: /* empty */		{ }
        | DOT cmpnd %prec DOT	{
             raise (Not_implemented
                    "Structure member addressing, e.g., x.y is not implemented")
             (* $$ = nn(ZN, '.', $2, ZN); *) }
        ;

    stmnt	: Special		{ $1 (* $$ = $1; initialization_ok = 0; *) }
        | Stmnt			{ $1 (* $$ = $1; initialization_ok = 0;
                      if (inEventMap)
                       non_fatal("not an event", (char * )0); *)
                    }
        ;

    for_pre : FOR LPAREN			/*	{ (* in_for = 1; *) } */
          varref		{ raise (Not_implemented "for") (* $$ = $4; *) }
        ;

    for_post: LCURLY sequence OS RCURLY { raise (Not_implemented "for") } ;

    Special : varref RCV	/*	{ (* Expand_Ok++; *) } */
          rargs		{ raise (Not_implemented "rcv")
                    (* Expand_Ok--; has_io++;
                      $$ = nn($1,  'r', $1, $4);
                      trackchanuse($4, ZN, 'R'); *)
                    }
        | varref SND		/* { (* Expand_Ok++; *) } */
          margs		{ raise (Not_implemented "snd")
                   (* Expand_Ok--; has_io++;
                      $$ = nn($1, 's', $1, $4);
                      $$->val=0; trackchanuse($4, ZN, 'S');
                      any_runs($4); *)
                    }
        | for_pre COLON expr DOTDOT expr RPAREN	/* { (*
                      for_setup($1, $3, $5); in_for = 0; *)
                    } */
          for_post	{
              raise (Not_implemented "for_post")
              (* $$ = for_body($1, 1); *)
                    }
        | for_pre IN varref RPAREN	/* { (* $$ = for_index($1, $3); in_for = 0; *)
                    } */
          for_post	{
              raise (Not_implemented "for_pre")
              (* $$ = for_body($5, 1); *)
                    }
        | SELECT LPAREN varref COLON expr DOTDOT expr RPAREN {
                        raise (Not_implemented "select")
                      (* $$ = sel_index($3, $5, $7); *)
                    }
        | if_begin options FI	{
                    pop_labs ();                
                    met_else := false;
                    [ MIf (new_id (), $2) ]
                    (* $$ = nn($1, IF, ZN, ZN);
                     $$->sl = $2->sl;
                     prune_opts($$); *)
              }
        | do_begin 		/* one more rule as ocamlyacc does not support multiple
                           actions like this: { (* pushbreak(); *) } */
              options OD {
                    (* use of elab/entry_lab is redundant, but we want
                       if/fi and do/od look similar as some algorithms
                       can cut off gotos at the end of an option *)
                    let (_, break_lab) = top_labs ()
                        and entry_lab = mk_uniq_label()
                        and opts = $2 in
                    met_else := false;
                    let do_s =
                        [MLabel (new_id (), entry_lab);
                         MIf (new_id (), opts);
                         MGoto (new_id (), entry_lab);
                         MLabel (new_id (), break_lab)]
                    in
                    pop_labs ();                
                    do_s

                    (* $$ = nn($1, DO, ZN, ZN);
                      $$->sl = $3->sl;
                      prune_opts($$); *)
                    }
        | BREAK     {
                    let (_, blab) = top_labs () in
                    [MGoto (new_id (), blab)]
                    (* $$ = nn(ZN, GOTO, ZN, ZN);
                      $$->sym = break_dest(); *)
                    }
        | GOTO NAME		{
            try
                [MGoto (new_id (), (Hashtbl.find labels $2))]
            with Not_found ->
                let label_no = mk_uniq_label () in
                Hashtbl.add fwd_labels $2 label_no;
                [MGoto (new_id (), label_no)] (* resolve it later *)
         (* $$ = nn($2, GOTO, ZN, ZN);
		  if ($2->sym->type != 0
		  &&  $2->sym->type != LABEL) {
		  	non_fatal("bad label-name %s",
			$2->sym->name);
		  }
		  $2->sym->type = LABEL; *)
		}
	| NAME COLON stmnt	{
        let label_no =
            if Hashtbl.mem labels $1
            then begin parse_error (sprintf "Label %s redeclared\n" $1); 0 end
            else if Hashtbl.mem fwd_labels $1
            then Hashtbl.find fwd_labels $1
            else (mk_uniq_label ())
        in
        Hashtbl.add labels $1 label_no;
        MLabel (new_id (), label_no) :: $3
                (* $$ = nn($1, ':',$3, ZN);
				  if ($1->sym->type != 0
				  &&  $1->sym->type != LABEL) {
				  	non_fatal("bad label-name %s",
					$1->sym->name);
				  }
				  $1->sym->type = LABEL; *)
		}
	;

Stmnt	: varref ASGN full_expr	{
                    [MExpr (new_id(), BinEx(ASGN, Var $1, $3))]
                 (* $$ = nn($1, ASGN, $1, $3);
				  trackvar($1, $3);
				  nochan_manip($1, $3, 0);
				  no_internals($1); *)
				}
	| varref INCR		{
                    let v = Var $1 in
                    [MExpr (new_id(), BinEx(ASGN, v, BinEx(PLUS, v, Const 1)))]
                 (* $$ = nn(ZN,CONST, ZN, ZN); $$->val = 1;
				  $$ = nn(ZN,  '+', $1, $$);
				  $$ = nn($1, ASGN, $1, $$);
				  trackvar($1, $1);
				  no_internals($1);
				  if ($1->sym->type == CHAN)
				   fatal("arithmetic on chan", (char * )0); *)
				}
	| varref DECR	{
                    let v = Var $1 in
                    [MExpr (new_id(), BinEx(ASGN, v, BinEx(MINUS, v, Const 1)))]
                 (* $$ = nn(ZN,CONST, ZN, ZN); $$->val = 1;
				  $$ = nn(ZN,  '-', $1, $$);
				  $$ = nn($1, ASGN, $1, $$);
				  trackvar($1, $1);
				  no_internals($1);
				  if ($1->sym->type == CHAN)
				   fatal("arithmetic on chan id's", (char * )0); *)
				}
	| PRINT	LPAREN STRING	/* { (* realread = 0; *) } */
	  prargs RPAREN	{
                    [MPrint (new_id(), $3, $4)]
                    (* $$ = nn($3, PRINT, $5, ZN); realread = 1; *) }
	| PRINTM LPAREN varref RPAREN	{
                    (* do we actually need it? *)
                    raise (Not_implemented "printm")
                 (* $$ = nn(ZN, PRINTM, $3, ZN); *)
                }
	| PRINTM LPAREN CONST RPAREN	{
                    raise (Not_implemented "printm")
                 (* $$ = nn(ZN, PRINTM, $3, ZN); *)
                }
	| ASSUME full_expr    	{
                    if is_expr_symbolic $2
                    then fatal "active [..] must be constant or symbolic" ""
                    else [MAssume (new_id(), $2)] (* FORSYTE ext. *)
                }
	| ASSERT full_expr    	{
                    [MAssert (new_id(), $2)]
                (* $$ = nn(ZN, ASSERT, $2, ZN); AST_track($2, 0); *) }
	| ccode			{ raise (Not_implemented "ccode") (* $$ = $1; *) }
	| varref R_RCV		/* { (* Expand_Ok++; *) } */
	  rargs			{
                    raise (Not_implemented "R_RCV")
                (*Expand_Ok--; has_io++;
				  $$ = nn($1,  'r', $1, $4);
				  $$->val = has_random = 1;
				  trackchanuse($4, ZN, 'R'); *)
				}
	| varref RCV		/* { (* Expand_Ok++; *) } */
	  LT rargs GT		{ raise (Not_implemented "rcv")
               (* Expand_Ok--; has_io++;
				  $$ = nn($1, 'r', $1, $5);
				  $$->val = 2;	/* fifo poll */
				  trackchanuse($5, ZN, 'R'); *)
				}
	| varref R_RCV		/* { (* Expand_Ok++; *) } */
	  LT rargs GT		{ raise (Not_implemented "r_rcv")
               (* Expand_Ok--; has_io++;	/* rrcv poll */
				  $$ = nn($1, 'r', $1, $5);
				  $$->val = 3; has_random = 1;
				  trackchanuse($5, ZN, 'R'); *)
				}
	| varref O_SND		/* { (* Expand_Ok++; *) } */
	  margs			{ raise (Not_implemented "o_snd")
               (* Expand_Ok--; has_io++;
				  $$ = nn($1, 's', $1, $4);
				  $$->val = has_sorted = 1;
				  trackchanuse($4, ZN, 'S');
				  any_runs($4); *)
				}
	| full_expr		{ [MExpr (new_id(), $1)]
                     (* $$ = nn(ZN, 'c', $1, ZN); count_runs($$); *) }
    | ELSE  		{ met_else := true; [] (* $$ = nn(ZN,ELSE,ZN,ZN); *)
				}
	| ATOMIC   LCURLY sequence OS RCURLY {
              [ MAtomic (new_id (), $3) ]
		  }
	| D_STEP LCURLY sequence OS RCURLY {
              [ MD_step (new_id (), $3) ]
		  }
	| LCURLY sequence OS RCURLY	{
              $2
	   	  }
	| INAME			/* { (* IArgs++; *) } */
	  LPAREN args RPAREN		/* { (* pickup_inline($1->sym, $4); IArgs--; *) } */
	  Stmnt			{ raise (Not_implemented "inline") (* $$ = $7; *) }
	;

if_begin : IF { push_new_labs () }
;

do_begin : DO { push_new_labs () }
;

options : option		{
            [$1]
            (* $$->sl = seqlist($1->sq, 0); *) }
	| option options	{
            $1 :: $2
            (* $$->sl = seqlist($1->sq, $2->sl); *) }
	;

option_head : SEP   { met_else := false (* open_seq(0); *) }
;

option  : option_head
      sequence OS	{
          if !met_else then MOptElse $2 else MOptGuarded $2
      }
	;

OS	: /* empty */ {}
	| SEMI			{ (* redundant semi at end of sequence *) }
	;

MS	: SEMI			{ (* at least one semi-colon *) }
	| MS SEMI		{ (* but more are okay too   *) }
	;

aname	: NAME		{ $1 }
	| PNAME			{ $1 }
	;

expr    : LPAREN expr RPAREN		{ $2 }
	| expr PLUS expr		{ BinEx(PLUS, $1, $3) }
	| expr MINUS expr		{ BinEx(MINUS, $1, $3) }
	| expr MULT expr		{ BinEx(MULT, $1, $3) }
	| expr DIV expr		    { BinEx(DIV, $1, $3) }
	| expr MOD expr		    { BinEx(MOD, $1, $3) }
	| expr BITAND expr		{ BinEx(BITAND, $1, $3) }
	| expr BITXOR expr		{ BinEx(BITXOR, $1, $3) }
	| expr BITOR expr		{ BinEx(BITOR, $1, $3) }
	| expr GT expr		    { BinEx(GT, $1, $3) }
	| expr LT expr		    { BinEx(LT, $1, $3) }
	| expr GE expr		    { BinEx(GE, $1, $3) }
	| expr LE expr		    { BinEx(LE, $1, $3) }
	| expr EQ expr		    { BinEx(EQ, $1, $3) }
	| expr NE expr		    { BinEx(NE, $1, $3) }
	| expr AND expr		    { BinEx(AND, $1, $3) }
	| expr OR  expr		    { BinEx(OR, $1, $3) }
	| expr LSHIFT expr	    { BinEx(LSHIFT, $1, $3) }
	| expr RSHIFT expr	    { BinEx(RSHIFT, $1, $3) }
	| BITNOT expr		    { UnEx(BITNOT, $2) }
	| MINUS expr %prec UMIN	{ UnEx(UMIN, $2) }
	| SND expr %prec NEG	{ UnEx(NEG, $2) }
	| LPAREN expr SEMI expr COLON expr RPAREN {
                  raise (Not_implemented "ternary operator")
                 (*
				  $$ = nn(ZN,  OR, $4, $6);
				  $$ = nn(ZN, '?', $2, $$); *)
				}

	| RUN aname		/* { (* Expand_Ok++;
				  if (!context)
				   fatal("used 'run' outside proctype",
					(char * ) 0); *)
				} */
	  LPAREN args RPAREN
	  Opt_priority		{
                  raise (Not_implemented "run")
               (* Expand_Ok--;
				  $$ = nn($2, RUN, $5, ZN);
				  $$->val = ($7) ? $7->val : 1;
				  trackchanuse($5, $2, 'A'); trackrun($$); *)
				}
	| LEN LPAREN varref RPAREN	{
                  raise (Not_implemented "len")
               (*  $$ = nn($3, LEN, $3, ZN);  *)}
	| ENABLED LPAREN expr RPAREN	{
                  raise (Not_implemented "enabled")
                (* $$ = nn(ZN, ENABLED, $3, ZN);
			 	   has_enabled++; *)
				}
	| varref RCV		/* {(*  Expand_Ok++;  *)} */
	  LBRACE rargs RBRACE		{
                  raise (Not_implemented "rcv")
                (* Expand_Ok--; has_io++;
				      $$ = nn($1, 'R', $1, $5); *)
				}
	| varref R_RCV		/* {(*  Expand_Ok++;  *)} */
	  LBRACE rargs RBRACE		{
                  raise (Not_implemented "r_rcv")
               (* Expand_Ok--; has_io++;
				  $$ = nn($1, 'R', $1, $5);
				  $$->val = has_random = 1; *)
				}
	| varref
        {
            let v = $1 in
            (* TODO: should not be set in printf *)
            v#add_flag HReadOnce;
            Var v
            (*  $$ = $1; trapwonly($1 /*, "varref" */);  *)
        }
	| cexpr			{raise (Not_implemented "cexpr") (*  $$ = $1;  *)}
	| CONST 	{
                    Const $1
               (* $$ = nn(ZN,CONST,ZN,ZN);
				  $$->ismtyp = $1->ismtyp;
				  $$->val = $1->val; *)
				}
	| TIMEOUT		{
                   raise (Not_implemented "timeout")
               (*  $$ = nn(ZN,TIMEOUT, ZN, ZN);  *)}
	| NONPROGRESS		{
                   raise (Not_implemented "nonprogress")
                (* $$ = nn(ZN,NONPROGRESS, ZN, ZN);
				  has_np++; *)
				}
	| PC_VAL LPAREN expr RPAREN	{
                   raise (Not_implemented "pc_value")
                (* $$ = nn(ZN, PC_VAL, $3, ZN);
				  has_pcvalue++; *)
				}
	| PNAME LBRACE expr RBRACE AT NAME
	  			{  raise (Not_implemented "PNAME operations")
                (*  $$ = rem_lab($1->sym, $3, $6->sym);  *)}
	| PNAME LBRACE expr RBRACE COLON pfld
	  			{  raise (Not_implemented "PNAME operations")
                (*  $$ = rem_var($1->sym, $3, $6->sym, $6->lft);  *)}
	| PNAME AT NAME	{
                   raise (Not_implemented "PNAME operations")
                (*  $$ = rem_lab($1->sym, ZN, $3->sym);  *)}
	| PNAME COLON pfld	{
                   raise (Not_implemented "PNAME operations")
                (*  $$ = rem_var($1->sym, ZN, $3->sym, $3->lft);  *)}
	| ltl_expr	{  raise (Not_implemented "ltl_expr")
            (*  $$ = $1;  *)}
    ;

/* FORSYTE extension */
prop_decl:
    ATOMIC NAME ASGN atomic_prop {
        MDeclProp (new_id (), new var($2), $4)
    }
    ;

/* FORSYTE extension */
atomic_prop:
      ALL LPAREN prop_expr RPAREN { PropAll ($3)  }
    | SOME LPAREN prop_expr RPAREN { PropSome ($3) }
    ;

prop_expr    : 
	  prop_expr PLUS prop_expr		{ BinEx(PLUS, $1, $3) }
	| prop_expr MINUS prop_expr		{ BinEx(MINUS, $1, $3) }
	| prop_expr MULT prop_expr		{ BinEx(MULT, $1, $3) }
	| prop_expr DIV prop_expr		{ BinEx(DIV, $1, $3) }
	| prop_expr GT prop_expr		{ BinEx(GT, $1, $3) }
	| prop_expr LT prop_expr		{ BinEx(LT, $1, $3) }
	| prop_expr GE prop_expr		{ BinEx(GE, $1, $3) }
	| prop_expr LE prop_expr		{ BinEx(LE, $1, $3) }
	| prop_expr EQ prop_expr		{ BinEx(EQ, $1, $3) }
	| prop_expr NE prop_expr		{ BinEx(NE, $1, $3) }
    | NAME /* proctype */ COLON NAME
        {
            let v = new var $3 in
            v#set_proc_name $1;
            Var (v) (* TODO: remember the proctype*)
        }
	| NAME
        {
            try
                Var (global_scope#find_or_error $1)#as_var
            with Not_found ->
                fatal "prop_expr: " (sprintf "Undefined global variable %s" $1)
        }
	| CONST { Const $1 }
    ;

Opt_priority:	/* none */	{(*  $$ = ZN;  *)}
	| PRIORITY CONST	{(*  $$ = $2;  *)}
	;

full_expr:	expr		{ $1 }
	| Expr		{ $1 }
	;

ltl_expr: expr UNTIL expr	{(*  $$ = nn(ZN, UNTIL,   $1, $3);  *)}
	| expr RELEASE expr	{(*  $$ = nn(ZN, RELEASE, $1, $3);  *)}
	| expr WEAK_UNTIL expr	{(* $$ = nn(ZN, ALWAYS, $1, ZN);
				  $$ = nn(ZN, OR, $$, nn(ZN, UNTIL, $1, $3)); *)
				}
	| expr IMPLIES expr	{ (*
				$$ = nn(ZN, '!', $1, ZN);
				$$ = nn(ZN, OR,  $$, $3); *)
				}
	| expr EQUIV expr	{(*  $$ = nn(ZN, EQUIV,   $1, $3);  *)}
	| NEXT expr       %prec NEG {(*  $$ = nn(ZN, NEXT,  $2, ZN);  *)}
	| ALWAYS expr     %prec NEG {(*  $$ = nn(ZN, ALWAYS,$2, ZN);  *)}
	| EVENTUALLY expr %prec NEG {(*  $$ = nn(ZN, EVENTUALLY, $2, ZN);  *)}
	;

	/* an Expr cannot be negated - to protect Probe expressions */
Expr	: Probe			{raise (Not_implemented "Probe") (*  $$ = $1;  *)}
	| LPAREN Expr RPAREN		{ $2 }
	| Expr AND Expr		{ BinEx(AND, $1, $3) }
	| Expr AND expr		{ BinEx(AND, $1, $3) }
	| expr AND Expr		{ BinEx(AND, $1, $3) }
	| Expr OR  Expr		{ BinEx(OR, $1, $3) }
	| Expr OR  expr		{ BinEx(OR, $1, $3) }
	| expr OR  Expr		{ BinEx(OR, $1, $3) }
	;

Probe	: FULL LPAREN varref RPAREN	{(*  $$ = nn($3,  FULL, $3, ZN);  *)}
	| NFULL LPAREN varref RPAREN	{(*  $$ = nn($3, NFULL, $3, ZN);  *)}
	| EMPTY LPAREN varref RPAREN	{(*  $$ = nn($3, EMPTY, $3, ZN);  *)}
	| NEMPTY LPAREN varref RPAREN	{(*  $$ = nn($3,NEMPTY, $3, ZN);  *)}
	;

Opt_enabler:	/* none */	{(*  $$ = ZN;  *)}
	| PROVIDED LPAREN full_expr RPAREN	{ (* if (!proper_enabler($3))
				  {	non_fatal("invalid PROVIDED clause",
						(char * )0);
					$$ = ZN;
				  } else
					$$ = $3; *)
				 }
	| PROVIDED error	{ (* $$ = ZN;
				  non_fatal("usage: provided ( ..expr.. )",
					(char * )0); *)
				}
	;

basetype: TYPE			{ (* $$->sym = ZS;
				  $$->val = $1->val;
				  if ($$->val == UNSIGNED)
				  fatal("unsigned cannot be used as mesg type", 0); *)
				}
	| UNAME			{ (* $$->sym = $1->sym;
				  $$->val = STRUCT; *)
				}
    | error		{}	/* e.g., unsigned ':' const */
	;

typ_list: basetype		{(*  $$ = nn($1, $1->val, ZN, ZN);  *)}
	| basetype COMMA typ_list	{(*  $$ = nn($1, $1->val, ZN, $3);  *)}
	;

args    : /* empty */		{(*  $$ = ZN;  *)}
	| arg			{(*  $$ = $1;  *)}
	;

prargs  : /* empty */		{ [] (*  $$ = ZN;  *)}
	| COMMA arg		{ $2 (*  $$ = $2;  *)}
	;

margs   : arg			{ (*  $$ = $1;  *)}
	| expr LPAREN arg RPAREN	{(* if ($1->ntyp == ',')
					$$ = tail_add($1, $3);
				  else
				  	$$ = nn(ZN, ',', $1, $3); *)
				}
	;

    arg     : expr	{ [$1]
                 (* if ($1->ntyp == ',')
					$$ = $1;
				  else
				  	$$ = nn(ZN, ',', $1, ZN); *)
				}
	| expr COMMA arg {
                $1 :: $3
                (* if ($1->ntyp == ',')
					$$ = tail_add($1, $3);
				  else
				  	$$ = nn(ZN, ',', $1, $3); *)
				}
	;

rarg	: varref		{ (* $$ = $1; trackvar($1, $1);
				  trapwonly($1 /*, "rarg" */); *) }
	| EVAL LPAREN expr RPAREN	{ (* $$ = nn(ZN,EVAL,$3,ZN);
				  trapwonly($1 /*, "eval rarg" */); *) }
	| CONST 		{ (* $$ = nn(ZN,CONST,ZN,ZN);
				  $$->ismtyp = $1->ismtyp;
				  $$->val = $1->val; *)
				}
	| MINUS CONST %prec UMIN	{ (* $$ = nn(ZN,CONST,ZN,ZN);
				  $$->val = - ($2->val); *)
				}
	;

rargs	: rarg			{ (* if ($1->ntyp == ',')
					$$ = $1;
				  else
				  	$$ = nn(ZN, ',', $1, ZN); *)
				}
	| rarg COMMA rargs	{ (* if ($1->ntyp == ',')
					$$ = tail_add($1, $3);
				  else
				  	$$ = nn(ZN, ',', $1, $3); *)
				}
	| rarg LPAREN rargs RPAREN	{ (* if ($1->ntyp == ',')
					$$ = tail_add($1, $3);
				  else
				  	$$ = nn(ZN, ',', $1, $3); *)
				}
	| LPAREN rargs RPAREN		{(*  $$ = $2;  *)}
	;

nlst	: NAME			{ (* $$ = nn($1, NAME, ZN, ZN);
				  $$ = nn(ZN, ',', $$, ZN); *) }
	| nlst NAME 		{ (* $$ = nn($2, NAME, ZN, ZN);
				  $$ = nn(ZN, ',', $$, $1); *)
				}
	| nlst COMMA		{ (* $$ = $1; /* commas optional */ *) }
	;
%%

(*
#define binop(n, sop)	fprintf(fd, "("); recursive(fd, n->lft); \
			fprintf(fd, ") %s (", sop); recursive(fd, n->rgt); \
			fprintf(fd, ")");
#define unop(n, sop)	fprintf(fd, "%s (", sop); recursive(fd, n->lft); \
			fprintf(fd, ")");

static void
recursive(FILE *fd, Lextok *n)
{
	if (n)
	switch (n->ntyp) {
	case NEXT:
		unop(n, "X");
		break;
	case ALWAYS:
		unop(n, "[]");
		break;
	case EVENTUALLY:
		unop(n, "<>");
		break;
	case '!':
		unop(n, "!");
		break;
	case UNTIL:
		binop(n, "U");
		break;
	case WEAK_UNTIL:
		binop(n, "W");
		break;
	case RELEASE: /* see http://en.wikipedia.org/wiki/Linear_temporal_logic */
		binop(n, "V");
		break;
	case OR:
		binop(n, "||");
		break;
	case AND:
		binop(n, "&&");
		break;
	case IMPLIES:
		binop(n, "->");
		break;
	case EQUIV:
		binop(n, "<->");
		break;
	default:
		comment(fd, n, 0);
		break;
	}
}

static Lextok *
ltl_to_string(Lextok *n)
{	Lextok *m = nn(ZN, 0, ZN, ZN);
	char formula[1024];
	FILE *tf = tmpfile();

	/* convert the parsed ltl to a string
	   by writing into a file, using existing functions,
	   and then passing it to the existing interface for
	   conversion into a never claim
	  (this means parsing everything twice, which is
	   a little redundant, but adds only miniscule overhead)
	 */

	if (!tf)
	{	fatal("cannot create temporary file", (char * ) 0);
	}
	recursive(tf, n);
	(void) fseek(tf, 0L, SEEK_SET);

	memset(formula, 0, sizeof(formula));
	if (!fgets(formula, sizeof(formula), tf))
	{	fatal("could not translate ltl formula", 0);
	}
	fclose(tf);

	if (1) printf("ltl %s: %s\n", ltl_name, formula);

	m->sym = lookup(formula);

	return m;
}
*)
