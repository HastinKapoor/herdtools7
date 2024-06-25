(******************************************************************************)
(*                                ASLRef                                      *)
(******************************************************************************)
(*
 * SPDX-FileCopyrightText: Copyright 2022-2023 Arm Limited and/or its affiliates <open-source-office@arm.com>
 * SPDX-License-Identifier: BSD-3-Clause
 *)
(******************************************************************************)
(* Disclaimer:                                                                *)
(* This material covers both ASLv0 (viz, the existing ASL pseudocode language *)
(* which appears in the Arm Architecture Reference Manual) and ASLv1, a new,  *)
(* experimental, and as yet unreleased version of ASL.                        *)
(* This material is work in progress, more precisely at pre-Alpha quality as  *)
(* per Arm’s quality standards.                                               *)
(* In particular, this means that it would be premature to base any           *)
(* production tool development on this material.                              *)
(* However, any feedback, question, query and feature request would be most   *)
(* welcome; those can be sent to Arm’s Architecture Formal Team Lead          *)
(* Jade Alglave <jade.alglave@arm.com>, or by raising issues or PRs to the    *)
(* herdtools7 github repository.                                              *)
(******************************************************************************)

open AST
open ASTUtils

let unsupported_expr e = Error.(fatal_from e (UnsupportedExpr (Dynamic, e)))
let fatal_from pos = Error.fatal_from pos

(* A bit more informative than assert false *)

let fail a msg = failwith (Printf.sprintf "%s: %s" (PP.pp_pos_str a) msg)

let fail_initialise a id =
  fail a (Printf.sprintf "Cannot initialise variable %s" id)

let _warn = false
let _dbg = false

module type S = sig
  module B : Backend.S

  val run_env : (AST.identifier * B.value) list -> AST.t -> B.value B.m
  val run : AST.t -> B.value B.m
  val run_typed : AST.t -> StaticEnv.env -> B.value B.m
end

module type Config = sig
  module Instr : Instrumentation.SEMINSTR

  val type_checking_strictness : Typing.strictness
  val unroll : int
end

module Make (B : Backend.S) (C : Config) = struct
  module B = B
  module SemanticsRule = Instrumentation.SemanticsRule

  type 'a m = 'a B.m

  module EnvConf = struct
    type v = B.value

    let unroll = C.unroll
  end

  module IEnv = Env.RunTime (EnvConf)

  type env = IEnv.env
  type value_read_from = B.value * identifier * scope

  type 'a maybe_exception =
    | Normal of 'a
    | Throwing of (value_read_from * ty) option * env

  (** An intermediate result of a statement. *)
  type control_flow_state =
    | Returning of B.value list * IEnv.global
        (** Control flow interruption: skip to the end of the function. *)
    | Continuing of env  (** Normal behaviour: pass to next statement. *)

  type expr_eval_type = (B.value * env) maybe_exception m
  type stmt_eval_type = control_flow_state maybe_exception m
  type func_eval_type = (value_read_from list * IEnv.global) maybe_exception m

  (*****************************************************************************)
  (*                                                                           *)
  (*                           Monadic operators                               *)
  (*                                                                           *)
  (*****************************************************************************)

  let one = B.v_of_int 1
  let true' = E_Literal (L_Bool true) |> add_dummy_pos
  let false' = E_Literal (L_Bool false) |> add_dummy_pos

  (* Return *)
  (* ------ *)
  let return = B.return
  let return_normal v = Normal v |> return
  let return_continue env : stmt_eval_type = Continuing env |> return_normal

  let return_return env vs : stmt_eval_type =
    Returning (vs, env.IEnv.global) |> return_normal

  (* Bind *)
  (* ---- *)

  (* Sequential bind *)
  let ( let*| ) = B.bind_seq

  (* Data bind *)
  let ( let* ) = B.bind_data
  let ( >>= ) = B.bind_data

  (* Control bind *)
  let ( let*= ) = B.bind_ctrl
  let ( >>*= ) = B.bind_ctrl

  (* Choice *)
  let choice m v1 v2 = B.choice m (return v1) (return v2)

  (*
   * Choice with inserted branching (commit) effect/
   * [choice_with_branching_effect_msg m_cond msg v1 v2 kont]:
   *  [m_cond], evaluates to boolean condition,
   *  [msg], message to decorate the branching event,
   *  [v1 v2] alternative for choice.
   *  [kont] contitinuation, takes choosed [v1] or [v2] as
   *         input .
   *)

  let choice_with_branch_effect_msg m_cond msg v1 v2 kont =
    choice m_cond v1 v2 >>= fun v ->
    B.commit (Some msg) >>*= fun () -> kont v

  let choice_with_branch_effect m_cond e_cond v1 v2 kont =
    let pp_cond = Format.asprintf "%a@?" PP.pp_expr e_cond in
    choice_with_branch_effect_msg m_cond pp_cond v1 v2 kont

  (* Exceptions *)
  let bind_exception binder m f =
    binder m (function Normal v -> f v | Throwing _ as res -> return res)

  let bind_exception_seq m f = bind_exception B.bind_seq m f
  let ( let**| ) = bind_exception_seq
  let bind_exception_data m f = bind_exception B.bind_data m f
  let ( let** ) = bind_exception_data

  (* Continue *)
  (* [bind_continue m f] executes [f] on [m] only if [m] is [Normal (Continuing _)] *)
  let bind_continue (m : stmt_eval_type) f : stmt_eval_type =
    bind_exception_seq m @@ function
    | Continuing env -> f env
    | Returning _ as res -> return_normal res

  let ( let*> ) = bind_continue

  (* Unroll *)
  (* [bind_unroll "while" m f] executes [f] on [m] after having ticked the
     unrolling stack of [m] only if [m] is [Normal (Continuing _)] *)
  let bind_unroll loop_name (m : stmt_eval_type) f : stmt_eval_type =
    bind_continue m @@ fun env ->
    let stop, env' = IEnv.tick_decr env in
    if stop then
      B.warnT (loop_name ^ " unrolling reached limit") env >>= return_continue
    else f env'

  let bind_maybe_unroll loop_name undet =
    if undet then bind_unroll loop_name else bind_continue

  (* To give name to rules *)
  let ( |: ) = C.Instr.use_with

  (* Product parallel *)
  (* ---------------- *)
  let ( and* ) = B.prod_par

  (* Application *)
  (* ----------- *)
  let ( >=> ) m f = B.appl_data m f

  (*****************************************************************************)
  (*                                                                           *)
  (*                                Environments                               *)
  (*                                                                           *)
  (*****************************************************************************)

  (* Functions *)
  (* --------- *)

  (** [build_funcs] initialize the unique calling reference for each function
      and builds the subprogram sub-env. *)
  let build_funcs ast (funcs : IEnv.func IMap.t) =
    List.to_seq ast
    |> Seq.filter_map (fun d ->
           match d.desc with
           | D_Func func -> Some (func.name, (ref 0, func))
           | _ -> None)
    |> Fun.flip IMap.add_seq funcs

  (* Global env *)
  (* ---------- *)

  let build_global_storage env0 eval_expr base_value =
    let names =
      List.fold_left (fun k (name, _) -> ISet.add name k) ISet.empty env0
    in
    let process_one_decl d =
      match d.desc with
      | D_GlobalStorage { initial_value; name; ty; _ } ->
          let scope = Scope_Global true in
          fun env_m ->
            if ISet.mem name names then env_m
            else
              let*| env = env_m in
              let* v =
                match (initial_value, ty) with
                | Some e, _ -> eval_expr env e
                | None, None -> fail_initialise d name
                | None, Some t -> base_value env t
              in
              let* () = B.on_write_identifier name scope v in
              IEnv.declare_global name v env |> return
      | _ -> Fun.id
    in
    let fold = function
      | TopoSort.ASTFold.Single d -> process_one_decl d
      | TopoSort.ASTFold.Recursive ds -> List.fold_right process_one_decl ds
    in
    fun ast -> TopoSort.ASTFold.fold fold ast

  (* Begin BuildGlobalEnv *)

  (** [build_genv static_env ast primitives] is the global environment before
      the start of the evaluation of [ast]. *)
  let build_genv env0 eval_expr base_value (static_env : StaticEnv.env)
      (ast : AST.t) =
    let funcs = IMap.empty |> build_funcs ast in
    let () =
      if _dbg then
        Format.eprintf "@[<v 2>Executing in env:@ %a@.]" StaticEnv.pp_global
          static_env.global
    in
    let env =
      let open IEnv in
      let global =
        { static = static_env.StaticEnv.global; storage = Storage.empty; funcs }
      in
      { global; local = empty_scoped (Scope_Global true) }
    in
    let env =
      List.fold_left
        (fun env (name, v) -> IEnv.declare_global name v env)
        env env0
    in
    let*| env =
      build_global_storage env0 eval_expr base_value ast (return env)
    in
    return env.global |: SemanticsRule.BuildGlobalEnv
  (* End *)

  (* Bind Environment *)
  (* ---------------- *)
  let discard_exception m =
    B.bind_data m @@ function
    | Normal v -> return v
    | Throwing _ -> assert false

  let bind_env m f =
    B.delay m (function
      | Normal (_v, env) -> fun m -> f (discard_exception m >=> fst, env)
      | Throwing (v, g) -> Throwing (v, g) |> return |> Fun.const)

  let ( let*^ ) = bind_env

  (* Primitives handling *)
  (* ------------------- *)
  let primitive_runtimes =
    List.to_seq B.primitives
    |> Seq.map AST.(fun ({ name; subprogram_type = _; _ }, f) -> (name, f))
    |> Hashtbl.of_seq

  let primitive_decls =
    List.map (fun (f, _) -> D_Func f |> add_dummy_pos) B.primitives

  let () =
    if false then
      Format.eprintf "@[<v 2>Primitives:@ %a@]@." PP.pp_t primitive_decls

  (*****************************************************************************)
  (*                                                                           *)
  (*                           Evaluation functions                            *)
  (*                                                                           *)
  (*****************************************************************************)

  (* Utils *)
  (* ----- *)
  let v_false = L_Bool false |> B.v_of_literal
  let m_false = return v_false
  let v_zero = L_Int Z.zero |> B.v_of_literal
  let m_zero = return v_zero

  let sync_list ms =
    let folder m vsm =
      let* v = m and* vs = vsm in
      return (v :: vs)
    in
    List.fold_right folder ms (return [])

  let fold_par2 fold1 fold2 acc e1 e2 =
    let*^ m1, acc = fold1 acc e1 in
    let*^ m2, acc = fold2 acc e2 in
    let* v1 = m1 and* v2 = m2 in
    return_normal ((v1, v2), acc)

  let rec fold_par_list fold acc es =
    match es with
    | [] -> return_normal ([], acc)
    | e :: es ->
        let** (v, vs), acc = fold_par2 fold (fold_par_list fold) acc e es in
        return_normal (v :: vs, acc)

  let rec fold_parm_list fold acc es =
    match es with
    | [] -> return_normal ([], acc)
    | e :: es ->
        let*^ m, acc = fold acc e in
        let** ms, acc = fold_parm_list fold acc es in
        return_normal (m :: ms, acc)

  let lexpr_is_var le =
    match le.desc with LE_Var _ | LE_Discard -> true | _ -> false

  let declare_local_identifier env name v =
    let* () = B.on_write_identifier name (IEnv.get_scope env) v in
    IEnv.declare_local name v env |> return

  let declare_local_identifier_m env x m = m >>= declare_local_identifier env x

  let declare_local_identifier_mm envm x m =
    let*| env = envm in
    declare_local_identifier_m env x m

  let assign_local_identifier env x v =
    let* () = B.on_write_identifier x (IEnv.get_scope env) v in
    IEnv.assign_local x v env |> return

  let return_identifier i = "return-" ^ string_of_int i
  let throw_identifier () = fresh_var "thrown"

  (* Begin ReadValueFrom *)
  let read_value_from ((v, name, scope) : value_read_from) =
    let* () = B.on_read_identifier name scope v in
    return v |: SemanticsRule.ReadValueFrom
  (* End *)

  let big_op default op =
    let folder m_acc m =
      let* acc = m_acc and* v = m in
      op acc v
    in
    function [] -> default | x :: li -> List.fold_left folder x li

  (* Evaluation of Expressions *)
  (* ------------------------- *)

  (** [eval_expr] specifies how to evaluate an expression [e] in an environment
      [env]. More precisely, [eval_expr env e] is the monadic evaluation  of
      [e] in [env]. *)
  let rec eval_expr (env : env) (e : expr) : expr_eval_type =
    if false then Format.eprintf "@[<3>Eval@ @[%a@]@]@." PP.pp_expr e;
    match e.desc with
    (* Begin Lit *)
    | E_Literal v -> return_normal (B.v_of_literal v, env) |: SemanticsRule.Lit
    (* End *)
    (* Begin ATC *)
    | E_ATC (e1, t) ->
        let** v, new_env = eval_expr env e1 in
        let* b = is_val_of_type e1 env v t in
        (if b then return_normal (v, new_env)
         else fatal_from e1 (Error.MismatchType (B.debug_value v, [ t.desc ])))
        |: SemanticsRule.ATC
    (* End *)
    | E_Var x -> (
        match IEnv.find x env with
        (* Begin ELocalVar *)
        | Local v ->
            let* () = B.on_read_identifier x (IEnv.get_scope env) v in
            return_normal (v, env) |: SemanticsRule.ELocalVar
        (* End *)
        (* Begin EGlobalVar *)
        | Global v ->
            let* () = B.on_read_identifier x (Scope_Global false) v in
            return_normal (v, env) |: SemanticsRule.EGlobalVar
        (* End *)
        (* Begin EUndefIdent *)
        | NotFound ->
            fatal_from e @@ Error.UndefinedIdentifier x
            |: SemanticsRule.EUndefIdent)
    (* End *)
    (* Begin BinopAnd *)
    | E_Binop (BAND, e1, e2) ->
        (* if e1 then e2 else false *)
        E_Cond (e1, e2, false')
        |> add_pos_from e |> eval_expr env |: SemanticsRule.BinopAnd
    (* End *)
    (* Begin BinopOr *)
    | E_Binop (BOR, e1, e2) ->
        (* if e1 then true else e2 *)
        E_Cond (e1, true', e2)
        |> add_pos_from e |> eval_expr env |: SemanticsRule.BinopOr
    (* End *)
    (* Begin BinopImpl *)
    | E_Binop (IMPL, e1, e2) ->
        (* if e1 then e2 else true *)
        E_Cond (e1, e2, true')
        |> add_pos_from e |> eval_expr env |: SemanticsRule.BinopImpl
    (* End *)
    (* Begin Binop *)
    | E_Binop (op, e1, e2) ->
        let*^ m1, env1 = eval_expr env e1 in
        let*^ m2, new_env = eval_expr env1 e2 in
        let* v1 = m1 and* v2 = m2 in
        let* v = B.binop op v1 v2 in
        return_normal (v, new_env) |: SemanticsRule.Binop
    (* End *)
    (* Begin Unop *)
    | E_Unop (op, e1) ->
        let** v1, env1 = eval_expr env e1 in
        let* v = B.unop op v1 in
        return_normal (v, env1) |: SemanticsRule.Unop
    (* End *)
    (* Begin ECond *)
    | E_Cond (e_cond, e1, e2) ->
        let*^ m_cond, env1 = eval_expr env e_cond in
        if is_simple_expr e1 && is_simple_expr e2 then
          let*= v_cond = m_cond in
          let* v =
            B.ternary v_cond
              (fun () -> eval_expr_sef env1 e1)
              (fun () -> eval_expr_sef env1 e2)
          in
          return_normal (v, env) |: SemanticsRule.ECondSimple
        else
          choice_with_branch_effect m_cond e_cond e1 e2 (eval_expr env1)
          |: SemanticsRule.ECond
    (* End *)
    (* Begin ESlice *)
    | E_Slice (e_bv, slices) ->
        let*^ m_bv, env1 = eval_expr env e_bv in
        let*^ m_positions, new_env = eval_slices env1 slices in
        let* v_bv = m_bv and* positions = m_positions in
        let* v = B.read_from_bitvector positions v_bv in
        return_normal (v, new_env) |: SemanticsRule.ESlice
    (* End *)
    (* Begin ECall *)
    | E_Call (name, actual_args, params) ->
        let**| ms, new_env = eval_call (to_pos e) name env actual_args params in
        let* v =
          match ms with
          | [ m ] -> m
          | _ ->
              let* vs = sync_list ms in
              B.create_vector vs
        in
        return_normal (v, new_env) |: SemanticsRule.ECall
    (* End *)
    (* Begin EGetArray *)
    | E_GetArray (e_array, e_index) -> (
        let*^ m_array, env1 = eval_expr env e_array in
        let*^ m_index, new_env = eval_expr env1 e_index in
        let* v_array = m_array and* v_index = m_index in
        match B.v_to_int v_index with
        | None -> unsupported_expr e
        | Some i ->
            let* v = B.get_index i v_array in
            return_normal (v, new_env) |: SemanticsRule.EGetArray)
    (* End *)
    | E_GetItem (e_tuple, index) ->
        let** v_tuple, new_env = eval_expr env e_tuple in
        let* v = B.get_index index v_tuple in
        return_normal (v, new_env)
    (* Begin ERecord *)
    | E_Record (_, e_fields) ->
        let names, fields = List.split e_fields in
        let** v_fields, new_env = eval_expr_list env fields in
        let* v = B.create_record (List.combine names v_fields) in
        return_normal (v, new_env) |: SemanticsRule.ERecord
    (* End *)
    (* Begin EGetField *)
    | E_GetField (e_record, field_name) ->
        let** v_record, new_env = eval_expr env e_record in
        let* v = B.get_field field_name v_record in
        return_normal (v, new_env) |: SemanticsRule.EGetBitField
    (* End *)
    (* Begin EGetFields *)
    | E_GetFields (e_record, field_names) ->
        let** v_record, new_env = eval_expr env e_record in
        let* v_list =
          List.map
            (fun field_name -> B.get_field field_name v_record)
            field_names
          |> sync_list
        in
        let* v = B.concat_bitvectors v_list in
        return_normal (v, new_env)
    (* End *)
    (* Begin EConcat *)
    | E_Concat e_list ->
        let** v_list, new_env = eval_expr_list env e_list in
        let* v = B.concat_bitvectors v_list in
        return_normal (v, new_env) |: SemanticsRule.EConcat
    (* End *)
    (* Begin ETuple *)
    | E_Tuple e_list ->
        let** v_list, new_env = eval_expr_list env e_list in
        let* v = B.create_vector v_list in
        return_normal (v, new_env) |: SemanticsRule.ETuple
    (* End *)
    (* Begin EUnknown *)
    | E_Unknown t ->
        let* v = B.v_unknown_of_type ~eval_expr_sef:(eval_expr_sef env) t in
        return_normal (v, env) |: SemanticsRule.EUnknown
    (* End *)
    (* Begin EPattern *)
    | E_Pattern (e, p) ->
        let** v1, new_env = eval_expr env e in
        let* v = eval_pattern env e v1 p in
        return_normal (v, new_env) |: SemanticsRule.EPattern
  (* End *)

  (* Evaluation of Side-Effect-Free Expressions *)
  (* ------------------------------------------ *)

  (** [eval_expr_sef] specifies how to evaluate a side-effect-free expression
      [e] in an environment [env]. More precisely, [eval_expr_sef env e] is the
      [eval_expr env e], if e is side-effect-free. *)
  (* Begin ESideEffectFreeExpr *)
  and eval_expr_sef env e : B.value m =
    eval_expr env e >>= function
    | Normal (v, _env) -> return v
    | Throwing (None, _) ->
        let msg =
          Format.asprintf
            "@[<hov 2>An exception was@ thrown@ when@ evaluating@ %a@]@."
            PP.pp_expr e
        in
        fatal_from e (Error.UnexpectedSideEffect msg)
    | Throwing (Some (_, ty), _) ->
        let msg =
          Format.asprintf
            "@[<hov 2>An exception of type @[<hv>%a@]@ was@ thrown@ when@ \
             evaluating@ %a@]@."
            PP.pp_ty ty PP.pp_expr e
        in
        fatal_from e (Error.UnexpectedSideEffect msg)
  (* End *)

  (* Runtime checks *)
  (* -------------- *)

  (* Begin ValOfType *)
  and is_val_of_type loc env v ty : bool B.m =
    let value_m_to_bool_m m = choice m true false in
    let big_or = big_op m_false (B.binop BOR) in
    match ty.desc with
    | T_Int UnConstrained -> return true
    | T_Int (UnderConstrained _) ->
        (* This cannot happen, because:
           1. Forgetting now about named types, or any kind of compound types,
              you cannot ask: [expr as ty] if ty is the unconstrained integer
              because there is no syntax for it.
           2. You cannot construct a type that is an alias for the
              underconstrained integer type.
           3. You cannot put the underconstrained integer type in a compound
              type.
        *)
        fatal_from loc Error.UnrespectedParserInvariant
    | T_Bits (e, _) ->
        let* v' = eval_expr_sef env e and* v_length = B.bitvector_length v in
        B.binop EQ_OP v_length v' |> value_m_to_bool_m
    | T_Int (WellConstrained constraints) ->
        let map_constraint = function
          | Constraint_Exact e ->
              let* v' = eval_expr_sef env e in
              B.binop EQ_OP v v'
          | Constraint_Range (e1, e2) ->
              let* v1 = eval_expr_sef env e1 and* v2 = eval_expr_sef env e2 in
              let* c1 = B.binop LEQ v1 v and* c2 = B.binop LEQ v v2 in
              B.binop BAND c1 c2
        in
        List.map map_constraint constraints |> big_or |> value_m_to_bool_m
    | _ -> fatal_from loc TypeInferenceNeeded
  (* End *)

  (* Evaluation of Left-Hand-Side Expressions *)
  (* ---------------------------------------- *)

  (** [eval_lexpr version env le m] is [env[le --> m]]. *)
  and eval_lexpr ver le env m : env maybe_exception B.m =
    match le.desc with
    (* Begin LEDiscard *)
    | LE_Discard -> return_normal env |: SemanticsRule.LEDiscard
    (* End *)
    | LE_Var x -> (
        let* v = m in
        match IEnv.assign x v env with
        (* Begin LELocalVar *)
        | Local env ->
            let* () = B.on_write_identifier x (IEnv.get_scope env) v in
            return_normal env |: SemanticsRule.LELocalVar
        (* End *)
        (* Begin LEGlobalVar *)
        | Global env ->
            let* () = B.on_write_identifier x (Scope_Global false) v in
            return_normal env |: SemanticsRule.LEGlobalVar
        (* End *)
        | NotFound -> (
            match ver with
            (* Begin LEUndefIdentOne *)
            | V1 ->
                fatal_from le @@ Error.UndefinedIdentifier x
                |: SemanticsRule.LEUndefIdentV1
            (* End *)
            (* Begin LEUndefIdentZero *)
            | V0 ->
                (* V0 first assignments promoted to local declarations *)
                declare_local_identifier env x v
                >>= return_normal |: SemanticsRule.LEUndefIdentV0))
    (* End *)
    (* Begin LESlice *)
    | LE_Slice (e_bv, slices) ->
        let*^ m_bv, env1 = expr_of_lexpr e_bv |> eval_expr env in
        let*^ m_positions, env2 = eval_slices env1 slices in
        let new_m_bv =
          let* v = m and* positions = m_positions and* v_bv = m_bv in
          B.write_to_bitvector positions v v_bv
        in
        eval_lexpr ver e_bv env2 new_m_bv |: SemanticsRule.LESlice
    (* End *)
    (* Begin LESetArray *)
    | LE_SetArray (re_array, e_index) ->
        let*^ rm_array, env1 = expr_of_lexpr re_array |> eval_expr env in
        let*^ m_index, env2 = eval_expr env1 e_index in
        let m1 =
          let* v = m and* v_index = m_index and* rv_array = rm_array in
          match B.v_to_int v_index with
          | None -> unsupported_expr e_index
          | Some i -> B.set_index i v rv_array
        in
        eval_lexpr ver re_array env2 m1 |: SemanticsRule.LESetArray
    (* End *)
    (* Begin LESetField *)
    | LE_SetField (re_record, field_name) ->
        let*^ rm_record, env1 = expr_of_lexpr re_record |> eval_expr env in
        let m1 =
          let* v = m and* rv_record = rm_record in
          B.set_field field_name v rv_record
        in
        eval_lexpr ver re_record env1 m1 |: SemanticsRule.LESetField
    (* End *)
    (* Begin LEDestructuring *)
    | LE_Destructuring le_list ->
        (* The index-out-of-bound on the vector are done either in typing,
           either in [B.get_index]. *)
        let n = List.length le_list in
        let nmonads = List.init n (fun i -> m >>= B.get_index i) in
        multi_assign ver env le_list nmonads |: SemanticsRule.LEDestructuring
    (* End *)
    (* Begin LEConcat *)
    | LE_Concat (les, Some widths) ->
        let extract_one width (ms, start) =
          let end_ = start + width in
          let v_width = B.v_of_int width and v_start = B.v_of_int start in
          let m' = m >>= B.read_from_bitvector [ (v_start, v_width) ] in
          (m' :: ms, end_)
        in
        let ms, _ = List.fold_right extract_one widths ([], 0) in
        multi_assign V1 env les ms
    (* End *)
    | LE_SetFields (le_record, fields, slices) ->
        let () =
          if List.compare_lengths fields slices != 0 then
            fatal_from le Error.TypeInferenceNeeded
        in
        let*^ rm_record, env1 = expr_of_lexpr le_record |> eval_expr env in
        let m2 =
          List.fold_left2
            (fun m1 field_name (i1, i2) ->
              let slice = [ (B.v_of_int i1, B.v_of_int i2) ] in
              let* v = m >>= B.read_from_bitvector slice and* rv_record = m1 in
              B.set_field field_name v rv_record)
            rm_record fields slices
        in
        eval_lexpr ver le_record env1 m2 |: SemanticsRule.LESetField
    | LE_Concat (_, None) ->
        let* () =
          let* v = m in
          Format.eprintf "@[<2>Failing on @[%a@]@ <-@ %s@]@." PP.pp_lexpr le
            (B.debug_value v);
          B.return ()
        in
        fatal_from le Error.TypeInferenceNeeded

  (* Evaluation of Expression Lists *)
  (* ------------------------------ *)
  (* Begin EExprListM *)
  and eval_expr_list_m env es =
    fold_parm_list eval_expr env es |: SemanticsRule.EExprListM

  (* End *)
  (* Begin EExprList *)
  and eval_expr_list env es =
    fold_par_list eval_expr env es |: SemanticsRule.EExprList
  (* End *)

  (* Evaluation of Slices *)
  (* -------------------- *)

  (** [eval_slices env slices] is the list of pair [(i_n, l_n)] that
      corresponds to the start (included) and the length of each slice in
      [slices]. *)
  and eval_slices env :
      slice list -> ((B.value * B.value) list * env) maybe_exception m =
    let eval_one env = function
      (* Begin SliceSingle *)
      | Slice_Single e ->
          let** v_start, new_env = eval_expr env e in
          return_normal ((v_start, one), new_env) |: SemanticsRule.SliceSingle
      (* End *)
      (* Begin SliceLength *)
      | Slice_Length (e_start, e_length) ->
          let*^ m_start, env1 = eval_expr env e_start in
          let*^ m_length, new_env = eval_expr env1 e_length in
          let* v_start = m_start and* v_length = m_length in
          return_normal ((v_start, v_length), new_env)
          |: SemanticsRule.SliceLength
      (* End *)
      (* Begin SliceRange *)
      | Slice_Range (e_top, e_start) ->
          let*^ m_top, env1 = eval_expr env e_top in
          let*^ m_start, new_env = eval_expr env1 e_start in
          let* v_top = m_top and* v_start = m_start in
          let* v_length = B.binop MINUS v_top v_start >>= B.binop PLUS one in
          return_normal ((v_start, v_length), new_env)
          |: SemanticsRule.SliceRange
      (* End *)
      (* Begin SliceStar *)
      | Slice_Star (e_factor, e_length) ->
          let*^ m_factor, env1 = eval_expr env e_factor in
          let*^ m_length, new_env = eval_expr env1 e_length in
          let* v_factor = m_factor and* v_length = m_length in
          let* v_start = B.binop MUL v_factor v_length in
          return_normal ((v_start, v_length), new_env)
          |: SemanticsRule.SliceStar
      (* End *)
    in
    (* Begin Slices *)
    fold_par_list eval_one env |: SemanticsRule.Slices
  (* End *)

  (* Evaluation of Patterns *)
  (* ---------------------- *)

  (** [eval_pattern env pos v p] determines if [v] matches the pattern [p]. *)
  and eval_pattern env pos v : pattern -> B.value m =
    let true_ = B.v_of_literal (L_Bool true) |> return in
    let false_ = B.v_of_literal (L_Bool false) |> return in
    let disjunction = big_op false_ (B.binop BOR)
    and conjunction = big_op true_ (B.binop BAND) in
    function
    (* Begin PAll *)
    | Pattern_All -> true_ |: SemanticsRule.PAll
    (* End *)
    (* Begin PAny *)
    | Pattern_Any ps ->
        let bs = List.map (eval_pattern env pos v) ps in
        disjunction bs |: SemanticsRule.PAny
    (* End *)
    (* Begin PGeq *)
    | Pattern_Geq e ->
        let* v1 = eval_expr_sef env e in
        B.binop GEQ v v1 |: SemanticsRule.PGeq
    (* End *)
    (* Begin PLeq *)
    | Pattern_Leq e ->
        let* v1 = eval_expr_sef env e in
        B.binop LEQ v v1 |: SemanticsRule.PLeq
    (* End *)
    (* Begin PNot *)
    | Pattern_Not p1 ->
        let* b1 = eval_pattern env pos v p1 in
        B.unop BNOT b1 |: SemanticsRule.PNot
    (* End *)
    (* Begin PRange *)
    | Pattern_Range (e1, e2) ->
        let* b1 =
          let* v1 = eval_expr_sef env e1 in
          B.binop GEQ v v1
        and* b2 =
          let* v2 = eval_expr_sef env e2 in
          B.binop LEQ v v2
        in
        B.binop BAND b1 b2 |: SemanticsRule.PRange
    (* End *)
    (* Begin PSingle *)
    | Pattern_Single e ->
        let* v1 = eval_expr_sef env e in
        B.binop EQ_OP v v1 |: SemanticsRule.PSingle
    (* End *)
    (* Begin PMask *)
    | Pattern_Mask m ->
        let bv bv = L_BitVector bv |> B.v_of_literal in
        let m_set = Bitvector.mask_set m and m_unset = Bitvector.mask_unset m in
        let m_specified = Bitvector.logor m_set m_unset in
        let* nv = B.unop NOT v in
        let* v_set = B.binop AND (bv m_set) v
        and* v_unset = B.binop AND (bv m_unset) nv in
        let* v_set_or_unset = B.binop OR v_set v_unset in
        B.binop EQ_OP v_set_or_unset (bv m_specified) |: SemanticsRule.PMask
    (* End *)
    (* Begin PTuple *)
    | Pattern_Tuple ps ->
        let n = List.length ps in
        let* vs = List.init n (fun i -> B.get_index i v) |> sync_list in
        let bs = List.map2 (eval_pattern env pos) vs ps in
        conjunction bs |: SemanticsRule.PTuple

  (* End *)
  (* Evaluation of Local Declarations *)
  (* -------------------------------- *)
  and eval_local_decl s ldi env m_init_opt : env maybe_exception m =
    let () =
      if false then Format.eprintf "Evaluating %a.@." PP.pp_local_decl_item ldi
    in
    match (ldi, m_init_opt) with
    (* Begin LDDiscard *)
    | LDI_Discard, _ -> return_normal env |: SemanticsRule.LDDiscard
    (* End *)
    (* Begin LDVar *)
    | LDI_Var x, Some m ->
        m
        >>= declare_local_identifier env x
        >>= return_normal |: SemanticsRule.LDVar
    (* End *)
    (* Begin LDTyped *)
    | LDI_Typed (ldi1, _t), Some m ->
        eval_local_decl s ldi1 env (Some m) |: SemanticsRule.LDTyped
    (* End *)
    (* Begin LDUninitialisedTyped *)
    | LDI_Typed (ldi1, t), None ->
        let m = base_value env t in
        eval_local_decl s ldi1 env (Some m)
        |: SemanticsRule.LDUninitialisedTyped
    (* End *)
    (* Begin LDTuple *)
    | LDI_Tuple ldis, Some m ->
        let n = List.length ldis in
        let* vm = m in
        let liv = List.init n (fun i -> B.return vm >>= B.get_index i) in
        let folder envm ldi1 vm =
          let**| env = envm in
          eval_local_decl s ldi1 env (Some vm)
        in
        List.fold_left2 folder (return_normal env) ldis liv
        |: SemanticsRule.LDTuple
    (* End *)
    | LDI_Var _, None | LDI_Tuple _, None ->
        (* Should not happen in V1 because of TypingRule.LDUninitialisedTuple *)
        fatal_from s Error.TypeInferenceNeeded

  (* Evaluation of Statements *)
  (* ------------------------ *)

  (** [eval_stmt env s] evaluates [s] in [env]. This is either an interruption
      [Returning vs] or a continuation [env], see [eval_res]. *)
  and eval_stmt (env : env) s : stmt_eval_type =
    (if false then
       match s.desc with
       | S_Seq _ -> ()
       | _ -> Format.eprintf "@[<3>Eval@ @[%a@]@]@." PP.pp_stmt s);
    match s.desc with
    (* Begin SPass *)
    | S_Pass -> return_continue env |: SemanticsRule.SPass
    (* End *)
    (* Begin SAssignCall *)
    | S_Assign
        ( { desc = LE_Destructuring les; _ },
          { desc = E_Call (name, args, named_args); _ },
          ver )
      when List.for_all lexpr_is_var les ->
        let**| vs, env1 = eval_call (to_pos s) name env args named_args in
        let**| new_env = protected_multi_assign ver env1 s les vs in
        return_continue new_env |: SemanticsRule.SAssignCall
    (* End *)
    (* Begin SAssign *)
    | S_Assign (le, re, ver) ->
        let*^ m, env1 = eval_expr env re in
        let**| new_env = eval_lexpr ver le env1 m in
        return_continue new_env |: SemanticsRule.SAssign
    (* End *)
    (* Begin SReturnSome *)
    | S_Return (Some { desc = E_Tuple es; _ }) ->
        let**| ms, new_env = eval_expr_list_m env es in
        let scope = IEnv.get_scope new_env in
        let folder acc m =
          let*| i, vs = acc in
          let* v = m in
          let* () = B.on_write_identifier (return_identifier i) scope v in
          return (i + 1, v :: vs)
        in
        let*| _i, vs = List.fold_left folder (return (0, [])) ms in
        return_return new_env (List.rev vs) |: SemanticsRule.SReturnSome
    (* End *)
    (* Begin SReturnOne *)
    | S_Return (Some e) ->
        let** v, env1 = eval_expr env e in
        let* () =
          B.on_write_identifier (return_identifier 0) (IEnv.get_scope env1) v
        in
        return_return env1 [ v ] |: SemanticsRule.SReturnOne
    (* Begin SReturnNone *)
    | S_Return None -> return_return env [] |: SemanticsRule.SReturnNone
    (* End *)
    (* Begin SSeq *)
    | S_Seq (s1, s2) ->
        let*> env1 = eval_stmt env s1 in
        eval_stmt env1 s2 |: SemanticsRule.SSeq
    (* End *)
    (* Begin SCall *)
    | S_Call (name, args, named_args) ->
        let**| returned, env' = eval_call (to_pos s) name env args named_args in
        let () = assert (returned = []) in
        return_continue env' |: SemanticsRule.SCall
    (* End *)
    (* Begin SCond *)
    | S_Cond (e, s1, s2) ->
        let*^ v, env' = eval_expr env e in
        choice_with_branch_effect v e s1 s2 (eval_block env')
        |: SemanticsRule.SCond
    (* Begin SCase *)
    | S_Case _ -> case_to_conds s |> eval_stmt env |: SemanticsRule.SCase
    (* End *)
    (* Begin SAssert *)
    | S_Assert e ->
        let*^ v, env1 = eval_expr env e in
        let*= b = choice v true false in
        if b then return_continue env1
        else fatal_from e @@ Error.AssertionFailed e |: SemanticsRule.SAssert
    (* End *)
    (* Begin SWhile *)
    | S_While (e, body) ->
        let env = IEnv.tick_push env in
        eval_loop true env e body |: SemanticsRule.SWhile
    (* End *)
    (* Begin SRepeat *)
    | S_Repeat (body, e) ->
        let*> env1 = eval_block env body in
        let env2 = IEnv.tick_push_bis env1 in
        eval_loop false env2 e body |: SemanticsRule.SRepeat
    (* End *)
    (* Begin SFor *)
    | S_For (id, e1, dir, e2, s) ->
        let* v1 = eval_expr_sef env e1 and* v2 = eval_expr_sef env e2 in
        (* By typing *)
        let undet = B.is_undetermined v1 || B.is_undetermined v2 in
        let*| env1 = declare_local_identifier env id v1 in
        let env2 = if undet then IEnv.tick_push_bis env1 else env1 in
        let loop_msg =
          if undet then Printf.sprintf "for %s" id
          else
            Printf.sprintf "for %s = %s %s %s" id (B.debug_value v1)
              (PP.pp_for_direction dir) (B.debug_value v2)
        in
        let*> env3 = eval_for loop_msg undet env2 id v1 dir v2 s in
        let env4 = if undet then IEnv.tick_pop env3 else env3 in
        IEnv.remove_local id env4 |> return_continue |: SemanticsRule.SFor
    (* End *)
    (* Begin SThrowNone *)
    | S_Throw None -> return (Throwing (None, env)) |: SemanticsRule.SThrowNone
    (* End *)
    (* Begin SThrowSomeTyped *)
    | S_Throw (Some (e, Some t)) ->
        let** v, new_env = eval_expr env e in
        let name = throw_identifier () and scope = Scope_Global false in
        let* () = B.on_write_identifier name scope v in
        return (Throwing (Some ((v, name, scope), t), new_env))
        |: SemanticsRule.SThrowSomeTyped
    (* End *)
    (* Begin SThrowSome *)
    | S_Throw (Some (_e, None)) ->
        fatal_from s Error.TypeInferenceNeeded |: SemanticsRule.SThrowSome
    (* End *)
    (* Begin STry *)
    | S_Try (s1, catchers, otherwise_opt) ->
        let s_m = eval_block env s1 in
        eval_catchers env catchers otherwise_opt s_m |: SemanticsRule.STry
    (* End *)
    (* Begin SDeclSome *)
    | S_Decl (_ldk, ldi, Some e) ->
        let*^ m, env1 = eval_expr env e in
        let**| new_env = eval_local_decl s ldi env1 (Some m) in
        return_continue new_env |: SemanticsRule.SDeclSome
    (* End *)
    (* Begin SDeclNone *)
    | S_Decl (_dlk, ldi, None) ->
        let**| new_env = eval_local_decl s ldi env None in
        return_continue new_env |: SemanticsRule.SDeclNone
    (* End *)
    | S_Print { args; debug } ->
        let* vs = List.map (eval_expr_sef env) args |> sync_list in
        let () =
          if debug then
            let open Format in
            let pp_value fmt v = B.debug_value v |> pp_print_string fmt in
            eprintf "@[@<2>%a:@ @[%a@]@ ->@ %a@]@." PP.pp_pos s
              (pp_print_list ~pp_sep:pp_print_space PP.pp_expr)
              args
              (pp_print_list ~pp_sep:pp_print_space pp_value)
              vs
          else (
            List.map B.debug_value vs |> String.concat " " |> print_string;
            print_newline ())
        in
        return_continue env |: SemanticsRule.SDebug

  (* Evaluation of Blocks *)
  (* -------------------- *)
  (* Begin Block *)
  and eval_block env stm =
    let block_env = IEnv.push_scope env in
    let*> block_env1 = eval_stmt block_env stm in
    IEnv.pop_scope env block_env1 |> return_continue |: SemanticsRule.Block
  (* End *)

  (* Evaluation of while and repeat loops *)
  (* ------------------------------------ *)
  (* Begin Loop *)
  and eval_loop is_while env e_cond body : stmt_eval_type =
    (* Name for warn messages. *)
    let loop_name = if is_while then "While loop" else "Repeat loop" in
    (* Continuation in the positive case. *)
    let loop env =
      let*> env1 = eval_block env body in
      eval_loop is_while env1 e_cond body
    in
    (* First we evaluate the condition *)
    let*^ cond_m, env = eval_expr env e_cond in
    (* Depending if we are in a while or a repeat,
       we invert that condition. *)
    let cond_m = if is_while then cond_m else cond_m >>= B.unop BNOT in
    (* If needs be, we tick the unrolling stack before looping. *)
    B.delay cond_m @@ fun cond cond_m ->
    let binder = bind_maybe_unroll loop_name (B.is_undetermined cond) in
    (* Real logic: if condition is validated, we loop,
       otherwise we continue to the next statement. *)
    choice_with_branch_effect cond_m e_cond loop return_continue
      (binder (return_continue env))
    |: SemanticsRule.Loop
  (* End *)

  (* Evaluation of for loops *)
  (* ----------------------- *)
  (* Begin For *)
  and eval_for loop_msg undet (env : env) index_name v_start dir v_end body :
      stmt_eval_type =
    (* Evaluate the condition: "Is the for loop terminated?" *)
    let cond_m =
      let comp_for_dir = match dir with Up -> LT | Down -> GT in
      let* () = B.on_read_identifier index_name (IEnv.get_scope env) v_start in
      B.binop comp_for_dir v_end v_start
    in
    (* Increase the loop counter *)
    let step env index_name v_start dir =
      let op_for_dir = match dir with Up -> PLUS | Down -> MINUS in
      let* () = B.on_read_identifier index_name (IEnv.get_scope env) v_start in
      let* v_step = B.binop op_for_dir v_start one in
      let* new_env = assign_local_identifier env index_name v_step in
      return (v_step, new_env)
    in
    (* Continuation in the positive case. *)
    let loop env =
      bind_maybe_unroll "For loop" undet (eval_block env body) @@ fun env1 ->
      let*| v_step, env2 = step env1 index_name v_start dir in
      eval_for loop_msg undet env2 index_name v_step dir v_end body
    in
    (* Real logic: if condition is validated, we continue to the next
       statement, otherwise we loop. *)
    choice_with_branch_effect_msg cond_m loop_msg return_continue loop
      (fun kont -> kont env)
    |: SemanticsRule.For
  (* End *)

  (* Evaluation of Catchers *)
  (* ---------------------- *)
  and eval_catchers env catchers otherwise_opt s_m : stmt_eval_type =
    (* rethrow_implicit handles the implicit throwing logic, that is for
       statement like:
          try throw_my_exception ()
          catch
            when MyException => throw;
          end
       It edits the thrown value only in the case of an implicit throw and
       we have a explicitely thrown exception in the context. More formally:
       [rethrow_implicit to_throw m] is:
         - [m] if [m] is [Normal _]
         - [m] if [m] is [Throwing (Some _, _)]
         - [Throwing (Some to_throw, g)] if  [m] is [Throwing (None, g)] *)
    (* Begin RethrowImplicit *)
    let rethrow_implicit (v, v_ty) res =
      B.bind_seq res @@ function
      | Throwing (None, env_throw1) ->
          Throwing (Some (v, v_ty), env_throw1) |> return
      | _ -> res |: SemanticsRule.RethrowImplicit
      (* End *)
    in
    (* [catcher_matches t c] returns true if the catcher [c] match the raised
       exception type [t]. *)
    (* Begin FindCatcher *)
    let catcher_matches =
      let static_env = { StaticEnv.empty with global = env.global.static } in
      fun v_ty (_e_name, e_ty, _stmt) ->
        Types.type_satisfies static_env v_ty e_ty |: SemanticsRule.FindCatcher
      (* End *)
    in
    (* Main logic: *)
    (* If an explicit throw has been made in the [try] block: *)
    B.bind_seq s_m @@ function
    (*  Begin CatchNoThrow *)
    | Normal _ | Throwing (None, _) -> s_m |: SemanticsRule.CatchNoThrow
    (* End *)
    | Throwing (Some (v, v_ty), env_throw) -> (
        (* We compute the environment in which to compute the catch statements. *)
        let env1 =
          if IEnv.same_scope env env_throw then env_throw
          else { local = env.local; global = env_throw.global }
        in
        match List.find_opt (catcher_matches v_ty) catchers with
        (* If any catcher matches the exception type: *)
        | Some catcher -> (
            (* Begin Catch *)
            match catcher with
            | None, _e_ty, s ->
                eval_block env1 s
                |> rethrow_implicit (v, v_ty)
                |: SemanticsRule.Catch
            (* Begin CatchNamed *)
            | Some name, _e_ty, s ->
                (* If the exception is declared to be used in the
                   catcher, we update the environment before executing [s]. *)
                let*| env2 =
                  read_value_from v |> declare_local_identifier_m env1 name
                in
                (let*> env3 = eval_block env2 s in
                 IEnv.remove_local name env3 |> return_continue)
                |> rethrow_implicit (v, v_ty)
                |: SemanticsRule.CatchNamed
                (* End *))
        | None -> (
            (* Otherwise we try to execute the otherwise statement, or we
               return the exception. *)
            match otherwise_opt with
            (* Begin CatchOtherwise *)
            | Some s ->
                eval_block env1 s
                |> rethrow_implicit (v, v_ty)
                |: SemanticsRule.CatchOtherwise
            (* Begin CatchNone *)
            | None -> s_m |: SemanticsRule.CatchNone))
  (* End *)
  (* Evaluation of Function Calls *)
  (* ---------------------------- *)

  (** [eval_call pos name env args named_args] evaluate the call to function
      [name] with arguments [args] and parameters [named_args] *)
  (* Begin Call *)
  and eval_call pos name env args named_args =
    let names, nargs1 = List.split named_args in
    let*^ vargs, env1 = eval_expr_list_m env args in
    let*^ nargs2, env2 = eval_expr_list_m env1 nargs1 in
    let* vargs = vargs and* nargs2 = nargs2 in
    let nargs3 = List.combine names nargs2 in
    let**| ms, global = eval_subprogram env2.global name pos vargs nargs3 in
    let ms2 = List.map read_value_from ms and new_env = { env2 with global } in
    return_normal (ms2, new_env) |: SemanticsRule.Call
  (* End *)

  (* Evaluation of Subprograms *)
  (* ----------------------- *)

  (** [eval_subprogram genv name pos actual_args params] evaluate the function named [name]
      in the global environment [genv], with [actual_args] the actual arguments, and
      [params] the parameters deduced by type equality. *)
  and eval_subprogram (genv : IEnv.global) name pos
      (actual_args : B.value m list) params : func_eval_type =
    match IMap.find_opt name genv.funcs with
    (* Begin FUndefIdent *)
    | None ->
        fatal_from pos @@ Error.UndefinedIdentifier name
        |: SemanticsRule.FUndefIdent
    (* End *)
    (* Begin FPrimitive *)
    | Some (r, { body = SB_Primitive; _ }) ->
        let scope = Scope_Local (name, !r) in
        let () = incr r in
        let body = Hashtbl.find primitive_runtimes name in
        let* ms = body actual_args in
        let _, vsm =
          List.fold_right
            (fun m (i, acc) ->
              let x = return_identifier i in
              let m' =
                let*| v =
                  let* v = m in
                  let* () = B.on_write_identifier x scope v in
                  return (v, x, scope)
                and* vs = acc in
                return (v :: vs)
              in
              (i + 1, m'))
            ms
            (0, return [])
        in
        let*| vs = vsm in
        return_normal (vs, genv) |: SemanticsRule.FPrimitive
    (* End *)
    (* Begin FBadArity *)
    | Some (_, { args = arg_decls; _ })
      when List.compare_lengths actual_args arg_decls <> 0 ->
        fatal_from pos
        @@ Error.BadArity (name, List.length arg_decls, List.length actual_args)
        |: SemanticsRule.FBadArity
    (* End *)
    (* Begin FCall *)
    | Some (r, { body = SB_ASL body; args = arg_decls; _ }) ->
        (let () = if false then Format.eprintf "Evaluating %s.@." name in
         let scope = Scope_Local (name, !r) in
         let () = incr r in
         let env1 = IEnv.{ global = genv; local = empty_scoped scope } in
         let one_arg envm (x, _) m = declare_local_identifier_mm envm x m in
         let env2 =
           List.fold_left2 one_arg (return env1) arg_decls actual_args
         in
         let one_narg envm (x, m) =
           let*| env = envm in
           if IEnv.mem x env then return env
           else declare_local_identifier_m env x m
         in
         let*| env3 = List.fold_left one_narg env2 params in
         let**| res = eval_stmt env3 body in
         let () =
           if false then Format.eprintf "Finished evaluating %s.@." name
         in
         match res with
         | Continuing env4 -> return_normal ([], env4.global)
         | Returning (xs, ret_genv) ->
             let vs =
               List.mapi (fun i v -> (v, return_identifier i, scope)) xs
             in
             return_normal (vs, ret_genv))
        |: SemanticsRule.FCall
  (* End *)

  (** [multi_assign env [le_1; ... ; le_n] [m_1; ... ; m_n]] is
      [env[le_1 --> m_1] ... [le_n --> m_n]]. *)
  (* Begin LEMultiAssign *)
  and multi_assign ver env les monads : env maybe_exception m =
    let folder envm le vm =
      let**| env = envm in
      eval_lexpr ver le env vm
    in
    List.fold_left2 folder (return_normal env) les monads
    |: SemanticsRule.LEMultiAssign
  (* End *)

  (** As [multi_assign], but checks that [les] and [monads] have the same
      length. *)
  and protected_multi_assign ver env pos les monads : env maybe_exception m =
    if List.compare_lengths les monads != 0 then
      fatal_from pos
      @@ Error.BadArity
           ("tuple construction", List.length les, List.length monads)
    else multi_assign ver env les monads

  (* Base Value *)
  (* ---------- *)
  and base_value env t =
    let t_struct = Types.get_structure (IEnv.to_static env) t in
    let lit v = B.v_of_literal v |> return in
    match t_struct.desc with
    | T_Bool -> L_Bool false |> lit
    | T_Bits (e, _) ->
        let* v = eval_expr_sef env e in
        let length =
          match B.v_to_int v with None -> unsupported_expr e | Some i -> i
        in
        L_BitVector (Bitvector.zeros length) |> lit
    | T_Enum li -> (
        try IMap.find (List.hd li) env.global.static.constant_values |> lit
        with Not_found -> fatal_from t Error.TypeInferenceNeeded)
    | T_Int UnConstrained -> m_zero
    | T_Int (UnderConstrained _) ->
        failwith "Cannot request the base value of a under-constrained integer."
    | T_Int (WellConstrained []) ->
        failwith
          "A well constrained integer cannot have an empty list of constraints."
    | T_Int (WellConstrained cs) -> (
        let leq x y = choice (B.binop LEQ x y) true false in
        let is_neg v = leq v v_zero in
        let abs v =
          let* b = is_neg v in
          if b then B.unop NEG v else return v
        in
        let m_none = return None in
        let abs_min v1 v2 =
          match (v1, v2) with
          | None, v | v, None -> return v
          | Some v1, Some v2 ->
              let* abs_v1 = abs v1 and* abs_v2 = abs v2 in
              let* v = choice (B.binop LEQ abs_v1 abs_v2) v1 v2 in
              return (Some v)
        in
        let big_abs_min = big_op m_none abs_min in
        let one_c = function
          | Constraint_Exact e ->
              let* v = eval_expr_sef env e in
              return (Some v)
          | Constraint_Range (e1, e2) -> (
              let* v1 = eval_expr_sef env e1 and* v2 = eval_expr_sef env e2 in
              let* b = leq v1 v2 in
              if not b then m_none
              else
                let* b1 = is_neg v1 and* b2 = is_neg v2 in
                match (b1, b2) with
                | true, false -> return (Some v_zero)
                | false, true ->
                    assert false (* caught by the [if not b] earlier *)
                | true, true -> return (Some v2)
                | false, false -> return (Some v1))
        in
        let* v = List.map one_c cs |> big_abs_min in
        match v with
        | None -> fatal_from t (Error.BaseValueEmptyType t)
        | Some v -> return v)
    | T_Named _ -> assert false
    | T_Real -> L_Real Q.zero |> lit
    | T_Exception fields | T_Record fields ->
        List.map
          (fun (name, t_field) ->
            let* v = base_value env t_field in
            return (name, v))
          fields
        |> sync_list >>= B.create_record
    | T_String -> L_String "" |> lit
    | T_Tuple li ->
        List.map (base_value env) li |> sync_list >>= B.create_vector
    | T_Array (length, ty) ->
        let* v = base_value env ty in
        let* i_length =
          match length with
          | ArrayLength_Enum (_, i) -> return i
          | ArrayLength_Expr e -> (
              let* length = eval_expr_sef env e in
              match B.v_to_int length with
              | None -> unsupported_expr e
              | Some i -> return i)
        in
        List.init i_length (Fun.const v) |> B.create_vector

  (* Begin TopLevel *)
  let run_typed_env env (ast : AST.t) (static_env : StaticEnv.env) : B.value m =
    let*| env = build_genv env eval_expr_sef base_value static_env ast in
    let*| res = eval_subprogram env "main" dummy_annotated [] [] in
    match res with
    | Normal ([ v ], _genv) -> read_value_from v
    | Normal _ -> Error.(fatal_unknown_pos (MismatchedReturnValue "main"))
    | Throwing (v_opt, _genv) ->
        let msg =
          match v_opt with
          | None -> "implicitely thrown out of a try-catch."
          | Some ((v, _, _scope), ty) ->
              Format.asprintf "%a %s" PP.pp_ty ty (B.debug_value v)
        in
        Error.fatal_unknown_pos (Error.UncaughtException msg)

  let run_typed ast env = run_typed_env [] ast env

  let run_env (env : (AST.identifier * B.value) list) (ast : AST.t) : B.value m
      =
    let ast = List.rev_append primitive_decls ast in
    let ast = Builder.with_stdlib ast in
    let ast, static_env =
      Typing.type_check_ast C.type_checking_strictness ast StaticEnv.empty
    in
    let () =
      if false then Format.eprintf "@[<v 2>Typed AST:@ %a@]@." PP.pp_t ast
    in
    run_typed_env env ast static_env

  let run ast = run_env [] ast |: SemanticsRule.TopLevel
  (* End TopLevel *)
end
