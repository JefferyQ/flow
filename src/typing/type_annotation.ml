(**
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

module Ast = Flow_ast

open Utils_js
open Reason
open Type
open Env.LookupMode

module FlowError = Flow_error
module Flow = Flow_js
module T = Ast.Type

(* AST helpers *)

let qualified_name =
  let rec loop acc = Ast.Type.Generic.Identifier.(function
    | Unqualified (_, name) ->
      let parts = name::acc in
      String.concat "." parts
    | Qualified (_, { qualification; id = (_, name) }) ->
      loop (name::acc) qualification
  ) in
  loop []

let ident_name (_, name) = name

let error_type cx loc msg =
  Flow.add_output cx msg;
  (loc, AnyT.at AnyError loc), Typed_ast.Type.error

let is_suppress_type cx type_name =
  SSet.mem type_name (Context.suppress_types cx)

let check_type_arg_arity cx loc params n f =
  match params with
  | None ->
    if n = 0 then
      f ()
    else
      error_type cx loc (FlowError.ETypeParamArity (loc, n))
  | Some (_, l) ->
    if n = List.length l && n <> 0 then
      f ()
    else
      error_type cx loc (FlowError.ETypeParamArity (loc, n))

let mk_custom_fun cx loc targs (id_loc, name) kind =
  check_type_arg_arity cx loc targs 0 (fun () ->
    let reason = mk_reason RFunctionType loc in
    let t = CustomFunT (reason, kind) in
    (loc, t),
    Ast.Type.(Generic {
      Generic.id = Generic.Identifier.Unqualified ((id_loc, t), name);
      targs = None
    })
  )

let mk_react_prop_type cx loc targs id kind =
  mk_custom_fun cx loc targs id
    (ReactPropType (React.PropType.Complex kind))

let add_unclear_type_error_if_not_lib_file cx loc =
  match ALoc.source loc with
    | Some file when not @@ File_key.is_lib_file file ->
      Flow_js.add_output cx (FlowError.EUnclearType loc)
    | _ -> ()

let add_deprecated_type_error_if_not_lib_file cx loc =
  match ALoc.source loc with
    | Some file when not @@ File_key.is_lib_file file ->
      Flow_js.add_output cx (FlowError.EDeprecatedType loc)
    | _ -> ()

let polarity = Ast.Variance.(function
  | Some (_, Plus) -> Positive
  | Some (_, Minus) -> Negative
  | None -> Neutral
)
(**********************************)
(* Transform annotations to types *)
(**********************************)

(* converter *)
let rec convert cx tparams_map = Ast.Type.(function

| loc, (Any as t_ast) ->
  add_unclear_type_error_if_not_lib_file cx loc;
  (loc, AnyT.at Annotated loc), t_ast

| loc, (Mixed as t_ast) -> (loc, MixedT.at loc), t_ast

| loc, (Empty as t_ast) -> (loc, EmptyT.at loc), t_ast

| loc, (Void as t_ast) -> (loc, VoidT.at loc), t_ast

| loc, (Null as t_ast) -> (loc, NullT.at loc), t_ast

| loc, (Number as t_ast) -> (loc, NumT.at loc), t_ast

| loc, (String as t_ast) -> (loc, StrT.at loc), t_ast

| loc, (Boolean as t_ast) -> (loc, BoolT.at loc), t_ast

| loc, Nullable t ->
    let (_, t), _ as t_ast = convert cx tparams_map t in
    let reason = annot_reason (mk_reason (RMaybe (desc_of_t t)) loc) in
    (loc, DefT (reason, MaybeT t)), Nullable t_ast

| loc, Union (t0, t1, ts) ->
  let (_, t0), _ as t0_ast = convert cx tparams_map t0 in
  let (_, t1), _ as t1_ast = convert cx tparams_map t1 in
  let ts, ts_ast = convert_list cx tparams_map ts in
  let rep = UnionRep.make t0 t1 (ts) in
  (loc, DefT (mk_reason RUnionType loc, UnionT rep)),
  Union (t0_ast, t1_ast, ts_ast)

| loc, Intersection (t0, t1, ts) ->
  let (_, t0), _ as t0_ast = convert cx tparams_map t0 in
  let (_, t1), _ as t1_ast = convert cx tparams_map t1 in
  let ts, ts_ast = convert_list cx tparams_map ts in
  let rep = InterRep.make t0 t1 ts in
  (loc, DefT (mk_reason RIntersectionType loc, IntersectionT rep)),
  Intersection (t0_ast, t1_ast, ts_ast)

| loc, Typeof x ->
  begin match x with
  | q_loc, Generic {
      Generic.id = qualification;
      targs = None
    } ->
      let valtype, qualification_ast = convert_qualification
        ~lookup_mode:ForTypeof cx "typeof-annotation" qualification in
      let desc = RTypeof (qualified_name qualification) in
      let reason = mk_reason desc loc in
      (loc, Flow.mk_typeof_annotation cx reason valtype),
      Typeof ((q_loc, valtype), Generic { Generic.id = qualification_ast; targs = None })
  | loc, _ ->
    error_type cx loc (FlowError.EUnexpectedTypeof loc)
  end

| loc, Tuple ts ->
  let tuple_types, ts_ast = convert_list cx tparams_map ts in
  let reason = annot_reason (mk_reason RTupleType loc) in
  let element_reason = mk_reason RTupleElement loc in
  let elemt = match tuple_types with
  | [] -> EmptyT.why element_reason
  | [t] -> t
  | t0::t1::ts ->
    (* If a tuple should be viewed as an array, what would the element type of
       the array be?

       Using a union here seems appealing but is wrong: setting elements
       through arbitrary indices at the union type would be unsound, since it
       might violate the projected types of the tuple at their corresponding
       positions. This also shows why `mixed` doesn't work, either.

       On the other hand, using the empty type would prevent writes, but admit
       unsound reads.

       The correct solution is to safely case a tuple type to a covariant
       array interface whose element type would be a union. Until we have
       that, we use the following closest approximation, that behaves like a
       union as a lower bound but `any` as an upper bound.
    *)
    AnyWithLowerBoundT (DefT (element_reason, UnionT (UnionRep.make t0 t1 ts)))
  in
  (loc, DefT (reason, ArrT (TupleAT (elemt, tuple_types)))), Tuple ts_ast

| loc, Array t ->
  let r = mk_reason RArrayType loc in
  let (_, elemt), _ as t_ast = convert cx tparams_map t in
  (loc, DefT (r, ArrT (ArrayAT (elemt, None)))), Array t_ast

| loc, (StringLiteral { Ast.StringLiteral.value; _ } as t_ast) ->
  (loc, mk_singleton_string loc value), t_ast

| loc, (NumberLiteral { Ast.NumberLiteral.value; raw } as t_ast) ->
  (loc, mk_singleton_number loc value raw), t_ast

| loc, (BooleanLiteral value as t_ast) ->
  (loc, mk_singleton_boolean loc value), t_ast

(* TODO *)
| loc, Generic { Generic.id = (Generic.Identifier.Qualified (qid_loc,
       { Generic.Identifier.qualification; id; }) as qid); targs } ->
  let m, qualification_ast =
    convert_qualification cx "type-annotation" qualification in
  let id_loc, name = id in
  let reason = mk_reason (RType name) loc in
  let id_reason = mk_reason (RType name) id_loc in
  let qid_reason = mk_reason (RType (qualified_name qid)) qid_loc in
  let t_unapplied = Tvar.mk_where cx qid_reason (fun t ->
    let id_info = name, t, Type_table.Other in
    Type_table.set_info id_loc id_info (Context.type_table cx);
    let use_op = Op (GetProperty qid_reason) in
    Flow.flow cx (m, GetPropT (use_op, qid_reason, Named (id_reason, name), t));
  ) in
  let t, targs = mk_nominal_type cx reason tparams_map (t_unapplied, targs) in
  (loc, t),
  Generic {
    Generic.id = Generic.Identifier.Qualified (qid_loc, {
      Generic.Identifier.qualification = qualification_ast;
      id = (id_loc, t_unapplied), name;
    });
    targs
  }

(* type applications: name < params > *)
| loc, Generic {
    Generic.id = Generic.Identifier.Unqualified (name_loc, name as ident);
    targs
  } ->

  let convert_type_params () =
    match targs with
    | None -> [], None
    | Some (loc, targs) ->
      let elemts, targs = convert_list cx tparams_map targs in
      elemts, Some (loc, targs)
  in

  let reconstruct_ast t ?id_t targs =
    (loc, t), Generic { Generic.
      id = Generic.Identifier.Unqualified ((name_loc, Option.value id_t ~default:t), name);
      targs;
  } in

  let use_op reason =
    Op (TypeApplication { type' = reason }) in

  begin match name with

  (* Temporary base types with literal information *)
  | "$TEMPORARY$number" ->
    check_type_arg_arity cx loc targs 1 (fun () ->
      let elemts, targs = convert_type_params () in
      match List.hd elemts with
        | DefT (r, SingletonNumT num_lit) ->
          reconstruct_ast
            (DefT (replace_reason_const RNumber r, NumT (Literal (None, num_lit))))
            targs
        | _ -> error_type cx loc (FlowError.EUnexpectedTemporaryBaseType loc)
    )

  | "$TEMPORARY$string" ->
    check_type_arg_arity cx loc targs 1 (fun () ->
      let elemts, targs = convert_type_params () in
      match List.hd elemts with
        | DefT (r, SingletonStrT str_lit) ->
          reconstruct_ast
            (DefT (replace_reason_const RString r, StrT (Literal (None, str_lit))))
            targs
        | _ -> error_type cx loc (FlowError.EUnexpectedTemporaryBaseType loc)
    )

  | "$TEMPORARY$boolean" ->
    check_type_arg_arity cx loc targs 1 (fun () ->
      let elemts, targs = convert_type_params () in
      match List.hd elemts with
        | DefT (r, SingletonBoolT bool) ->
          reconstruct_ast
            (DefT (replace_reason_const RBoolean r, BoolT (Some bool)))
            targs
        | _ -> error_type cx loc (FlowError.EUnexpectedTemporaryBaseType loc)
    )

  | "$TEMPORARY$Object$freeze" ->
    check_type_arg_arity cx loc targs 1 (fun () ->
      let ts, targs = convert_type_params () in
      let t = List.hd ts in
      let reason_arg = mk_reason (RFrozen RObjectLit) loc in
      let tout = Tvar.mk_where cx reason_arg (fun tvar ->
        Flow.flow cx (t, ObjFreezeT (reason_arg, tvar));
      ) in
      (* TODO fix targs *)
      reconstruct_ast tout targs
    )

  | "$TEMPORARY$object" ->
    check_type_arg_arity cx loc targs 1 (fun () ->
      let ts, targs = convert_type_params () in
      let t = List.hd ts in
      let tout = match t with
        | ExactT (_, DefT (r, ObjT o)) ->
          let r = replace_reason_const RObjectLit r in
          DefT (r, ObjT { o with flags = { o.flags with exact = true } })
        | _ -> t
      in
      reconstruct_ast tout targs
  )

  | "$TEMPORARY$array" ->
    check_type_arg_arity cx loc targs 1 (fun () ->
      let elemts, targs = convert_type_params () in
      let elemt = List.hd elemts in
      reconstruct_ast
        (DefT (mk_reason RArrayLit loc, ArrT (ArrayAT (elemt, None))))
        targs
  )

  (* Array<T> *)
  | "Array" ->
    check_type_arg_arity cx loc targs 1 (fun () ->
      let elemts, targs = convert_type_params () in
      let elemt = List.hd elemts in
      reconstruct_ast
        (DefT (mk_reason RArrayType loc, ArrT (ArrayAT (elemt, None))))
        targs
    )

  (* $ReadOnlyArray<T> is the supertype of all tuples and all arrays *)
  | "$ReadOnlyArray" ->
    check_type_arg_arity cx loc targs 1 (fun () ->
      let elemts, targs = convert_type_params () in
      let elemt = List.hd elemts in
      reconstruct_ast
        (DefT (annot_reason (mk_reason RROArrayType loc), ArrT (ROArrayAT (elemt))))
        targs
    )

  (* These utilities are no longer supported *)
  (* $Supertype<T> acts as any over supertypes of T *)
  | "$Supertype" ->
    FlowError.EDeprecatedUtility (loc, name) |> Flow_js.add_output cx;
    check_type_arg_arity cx loc targs 1 (fun () ->
      let ts, targs = convert_type_params () in
      let t = List.hd ts in
      reconstruct_ast (AnyWithLowerBoundT t) targs
    )

  (* $Subtype<T> acts as any over subtypes of T *)
  | "$Subtype" ->
    FlowError.EDeprecatedUtility (loc, name) |> Flow_js.add_output cx;
    check_type_arg_arity cx loc targs 1 (fun () ->
      let ts, targs = convert_type_params () in
      let t = List.hd ts in
      reconstruct_ast (AnyWithUpperBoundT t) targs
    )

  (* $PropertyType<T, 'x'> acts as the type of 'x' in object type T *)
  | "$PropertyType" ->
    check_type_arg_arity cx loc targs 2 (fun () ->
      match convert_type_params () with
      | ([t; DefT (_, SingletonStrT key)], targs) ->
        let reason = mk_reason (RType "$PropertyType") loc in
        reconstruct_ast
          (EvalT (t, TypeDestructorT
            (use_op reason, reason, PropertyType key), mk_id()))
          targs
      | _ ->
        error_type cx loc (FlowError.EPropertyTypeAnnot loc)
    )

  (* $ElementType<T, string> acts as the type of the string elements in object
     type T *)
  | "$ElementType" ->
    check_type_arg_arity cx loc targs 2 (fun () ->
      match convert_type_params () with
      | ([t; e], targs) ->
        let reason = mk_reason (RType "$ElementType") loc in
        reconstruct_ast
          (EvalT (t, TypeDestructorT
            (use_op reason, reason, ElementType e), mk_id()))
          targs
      | _ -> assert false
    )

  (* $NonMaybeType<T> acts as the type T without null and void *)
  | "$NonMaybeType" ->
    check_type_arg_arity cx loc targs 1 (fun () ->
      let ts, targs = convert_type_params () in
      let t = List.hd ts in
      let reason = mk_reason (RType "$NonMaybeType") loc in
      reconstruct_ast
        (EvalT (t, TypeDestructorT
          (use_op reason, reason, NonMaybeType), mk_id()))
        targs
    )

  (* $Shape<T> matches the shape of T *)
  | "$Shape" ->
    check_type_arg_arity cx loc targs 1 (fun () ->
      let ts, targs = convert_type_params () in
      let t = List.hd ts in
      reconstruct_ast (ShapeT t) targs
    )

  (* $Diff<T, S> *)
  | "$Diff" ->
    check_type_arg_arity cx loc targs 2 (fun () ->
      let t1, t2, targs = match convert_type_params () with
      | [t1; t2], targs -> t1, t2, targs
      | _ -> assert false in
      let reason = mk_reason (RType "$Diff") loc in
      reconstruct_ast
        (EvalT (t1, TypeDestructorT (use_op reason, reason,
          RestType (Type.Object.Rest.IgnoreExactAndOwn, t2)), mk_id ()))
        targs
    )

  (* $ReadOnly<T> *)
  | "$ReadOnly" ->
    check_type_arg_arity cx loc targs 1 (fun () ->
      let ts, targs = convert_type_params () in
      let t = List.hd ts in
      let reason = mk_reason (RType "$ReadOnly") loc in
      reconstruct_ast
        (EvalT (
          t,
          TypeDestructorT (
            use_op reason,
            reason,
            ReadOnlyType
          ),
          mk_id ()
        ))
        targs
    )

  (* $Keys<T> is the set of keys of T *)
  (** TODO: remove $Enum **)
  | "$Keys" | "$Enum" ->
    check_type_arg_arity cx loc targs 1 (fun () ->
      let ts, targs = convert_type_params () in
      let t = List.hd ts in
      reconstruct_ast
        (KeysT (mk_reason RKeySet loc, t))
        targs
    )

  (* $Values<T> is a union of all the own enumerable value types of T *)
  | "$Values" ->
    check_type_arg_arity cx loc targs 1 (fun () ->
      let ts, targs = convert_type_params () in
      let t = List.hd ts in
      let reason = mk_reason (RType "$Values") loc in
      reconstruct_ast
        (EvalT (t, TypeDestructorT
          (use_op reason, reason, ValuesType), mk_id()))
        targs
    )

  | "$Exact" ->
    check_type_arg_arity cx loc targs 1 (fun () ->
      let ts, targs = convert_type_params () in
      let t = List.hd ts in
      let desc = RExactType (desc_of_t t) in
      reconstruct_ast (ExactT (mk_reason desc loc, t)) targs
    )

  | "$Rest" ->
    check_type_arg_arity cx loc targs 2 (fun () ->
      let t1, t2, targs = match convert_type_params () with
      | [t1; t2], targs -> t1, t2, targs
      | _ -> assert false in
      let reason = mk_reason (RType "$Rest") loc in
      reconstruct_ast
        (EvalT (t1, TypeDestructorT (use_op reason, reason,
          RestType (Type.Object.Rest.Sound, t2)), mk_id ()))
        targs
    )

  (* $Exports<'M'> is the type of the exports of module 'M' *)
  (** TODO: use `import typeof` instead when that lands **)
  | "$Exports" ->
    check_type_arg_arity cx loc targs 1 (fun () ->
      match targs with
      | Some (targs_loc, (str_loc, StringLiteral { Ast.StringLiteral.value; raw })::_) ->
          let desc = RModule value in
          let reason = mk_reason desc loc in
          let remote_module_t =
            Env.get_var_declared_type cx (internal_module_name value) loc
          in
          let str_t = mk_singleton_string str_loc value in
          reconstruct_ast
            (Tvar.mk_where cx reason (fun t ->
              Flow.flow cx (remote_module_t, CJSRequireT(reason, t, Context.is_strict cx))
            ))
            (Some (
              targs_loc,
              [ (str_loc, str_t),  StringLiteral { Ast.StringLiteral.value; raw } ]
            ))
      | _ ->
          error_type cx loc (FlowError.EExportsAnnot loc)
    )

  | "$Call" ->
    (match convert_type_params () with
    | fn::args, targs ->
      let reason = mk_reason RFunctionCallType loc in
      reconstruct_ast
        (EvalT (fn, TypeDestructorT (use_op reason, reason, CallType args), mk_id ()))
        targs
    | _ ->
      error_type cx loc (FlowError.ETypeParamMinArity (loc, 1)))

  | "$TupleMap" ->
    check_type_arg_arity cx loc targs 2 (fun () ->
      let t1, t2, targs = match convert_type_params () with
      | [t1; t2], targs -> t1, t2, targs
      | _ -> assert false in
      let reason = mk_reason RTupleMap loc in
      reconstruct_ast
        (EvalT (t1, TypeDestructorT (use_op reason, reason, TypeMap (TupleMap t2)), mk_id ()))
        targs
    )

  | "$ObjMap" ->
    check_type_arg_arity cx loc targs 2 (fun () ->
      let t1, t2, targs = match convert_type_params () with
      | [t1; t2], targs -> t1, t2, targs
      | _ -> assert false in
      let reason = mk_reason RObjectMap loc in
      reconstruct_ast
        (EvalT (t1, TypeDestructorT (use_op reason, reason, TypeMap (ObjectMap t2)), mk_id ()))
        targs
    )

  | "$ObjMapi" ->
    check_type_arg_arity cx loc targs 2 (fun () ->
      let t1, t2, targs = match convert_type_params () with
      | [t1; t2], targs -> t1, t2, targs
      | _ -> assert false in
      let reason = mk_reason RObjectMapi loc in
      reconstruct_ast
        (EvalT (t1, TypeDestructorT (use_op reason, reason, TypeMap (ObjectMapi t2)), mk_id ()))
        targs
    )

  | "$CharSet" ->
    check_type_arg_arity cx loc targs 1 (fun () ->
      match targs with
    | Some (targs_loc, [ str_loc, StringLiteral { Ast.StringLiteral.value; raw } ]) ->
        let str_t = mk_singleton_string str_loc value in
        let chars = String_utils.CharSet.of_string value in
        let char_str = String_utils.CharSet.to_string chars in (* sorts them *)
        let reason = mk_reason (RCustom (spf "character set `%s`" char_str)) loc in
        reconstruct_ast
          (DefT (reason, CharSetT chars))
          (Some (
            targs_loc,
            [ (str_loc, str_t), StringLiteral { Ast.StringLiteral.value; raw } ]
          ))
      | _ ->
        error_type cx loc (FlowError.ECharSetAnnot loc)
    )

  | "this" ->
    if SMap.mem "this" tparams_map then
      (* We model a this type like a type parameter. The bound on a this
         type reflects the interface of `this` exposed in the current
         environment. Currently, we only support this types in a class
         environment: a this type in class C is bounded by C. *)
      check_type_arg_arity cx loc targs 0 (fun () ->
        reconstruct_ast (Flow.reposition cx loc (SMap.find_unsafe "this" tparams_map)) None
      )
    else (
      Flow.add_output cx (FlowError.EUnexpectedThisType loc);
      (loc, AnyT.locationless AnyError), Any (* why locationless? *)
    )

  (* Class<T> is the type of the class whose instances are of type T *)
  | "Class" ->
    check_type_arg_arity cx loc targs 1 (fun () ->
      let ts, targs = convert_type_params () in
      let t = List.hd ts in
      let reason = mk_reason (RStatics (desc_of_t t)) loc in
      reconstruct_ast (DefT (reason, ClassT t)) targs
    )

  | "Function" | "function" ->
    add_unclear_type_error_if_not_lib_file cx loc;
    check_type_arg_arity cx loc targs 0 (fun () ->
      let reason = mk_reason RFunctionType loc in
      reconstruct_ast (AnyT.make Annotated reason) None
    )

  | "Object" ->
    add_unclear_type_error_if_not_lib_file cx loc;
    check_type_arg_arity cx loc targs 0 (fun () ->
      let reason = mk_reason RObjectType loc in
      reconstruct_ast (AnyT.make Annotated reason) None
    )

  | "Function$Prototype$Apply" ->
    check_type_arg_arity cx loc targs 0 (fun () ->
      let reason = mk_reason RFunctionType loc in
      reconstruct_ast (FunProtoApplyT reason) None
    )

  | "Function$Prototype$Bind" ->
    check_type_arg_arity cx loc targs 0 (fun () ->
      let reason = mk_reason RFunctionType loc in
      reconstruct_ast (FunProtoBindT reason) None
    )

  | "Function$Prototype$Call" ->
    check_type_arg_arity cx loc targs 0 (fun () ->
      let reason = mk_reason RFunctionType loc in
      reconstruct_ast (FunProtoCallT reason) None
    )

  | "Object$Assign" ->
      mk_custom_fun cx loc targs ident ObjectAssign
  | "Object$GetPrototypeOf" ->
      mk_custom_fun cx loc targs ident ObjectGetPrototypeOf
  | "Object$SetPrototypeOf" ->
      mk_custom_fun cx loc targs ident ObjectSetPrototypeOf

  | "$Compose" ->
      mk_custom_fun cx loc targs ident (Compose false)
  | "$ComposeReverse" ->
      mk_custom_fun cx loc targs ident (Compose true)

  | "React$AbstractComponent" ->
      check_type_arg_arity cx loc targs 2 (fun () ->
        let ts, targs = convert_type_params () in
        let config = List.nth ts 0 in
        let instance = List.nth ts 1 in
        reconstruct_ast (DefT (mk_reason (RCustom "AbstractComponent") loc,
          ReactAbstractComponentT {config; instance})) targs
      )
  | "React$Config" ->
      check_type_arg_arity cx loc targs 2 (fun () ->
        let ts, targs = convert_type_params () in
        let props = List.nth ts 0 in
        let default_props = List.nth ts 1 in
        let reason = mk_reason RReactConfig loc in
        reconstruct_ast
          (EvalT (props, TypeDestructorT
          (use_op reason, reason,
            ReactConfigType default_props), mk_id ()))
          targs
      )

  | "React$PropType$Primitive" ->
      check_type_arg_arity cx loc targs 1 (fun () ->
        let ts, targs = convert_type_params () in
        let t = List.hd ts in
        let prop_type = (ReactPropType (React.PropType.Primitive (false, t))) in
        let (_, prop_t), _ = mk_custom_fun cx loc None ident prop_type in
        reconstruct_ast prop_t targs
      )
  | "React$PropType$Primitive$Required" ->
      check_type_arg_arity cx loc targs 1 (fun () ->
        let ts, targs = convert_type_params () in
        let t = List.hd ts in
        let prop_type = (ReactPropType (React.PropType.Primitive (true, t))) in
        let (_, prop_t), _ = mk_custom_fun cx loc None ident prop_type in
        reconstruct_ast prop_t targs
      )
  | "React$PropType$ArrayOf" ->
      mk_react_prop_type cx loc targs ident React.PropType.ArrayOf
  | "React$PropType$InstanceOf" ->
      mk_react_prop_type cx loc targs ident React.PropType.InstanceOf
  | "React$PropType$ObjectOf" ->
      mk_react_prop_type cx loc targs ident React.PropType.ObjectOf
  | "React$PropType$OneOf" ->
      mk_react_prop_type cx loc targs ident React.PropType.OneOf
  | "React$PropType$OneOfType" ->
      mk_react_prop_type cx loc targs ident React.PropType.OneOfType
  | "React$PropType$Shape" ->
      mk_react_prop_type cx loc targs ident React.PropType.Shape
  | "React$CreateClass" ->
      mk_custom_fun cx loc targs ident ReactCreateClass
  | "React$CreateElement" ->
      mk_custom_fun cx loc targs ident ReactCreateElement
  | "React$CloneElement" ->
      mk_custom_fun cx loc targs ident ReactCloneElement
  | "React$ElementFactory" ->
      check_type_arg_arity cx loc targs 1 (fun () ->
        let t = match convert_type_params () with
          | [t], _ -> t
          | _ -> assert false in
        mk_custom_fun cx loc None ident (ReactElementFactory t)
      )
  | "React$ElementProps" ->
    check_type_arg_arity cx loc targs 1 (fun () ->
      let ts, targs = convert_type_params () in
      let t = List.hd ts in
      let reason = mk_reason (RType "React$ElementProps") loc in
      reconstruct_ast
        (EvalT (t, TypeDestructorT
        (use_op reason, reason,
          ReactElementPropsType), mk_id ()))
        targs
    )
  | "React$ElementConfig" ->
    check_type_arg_arity cx loc targs 1 (fun () ->
      let ts, targs = convert_type_params () in
      let t = List.hd ts in
      let reason = mk_reason (RType "React$ElementConfig") loc in
      reconstruct_ast
        (EvalT (t, TypeDestructorT (
          use_op reason, reason, ReactElementConfigType), mk_id ()
        ))
        targs
    )
  | "React$ElementRef" ->
    check_type_arg_arity cx loc targs 1 (fun () ->
      let ts, targs = convert_type_params () in
      let t = List.hd ts in
      let reason = mk_reason (RType "React$ElementRef") loc in
      reconstruct_ast
        (EvalT (t, TypeDestructorT (
          use_op reason, reason, ReactElementRefType), mk_id ()
        ))
        targs
    )

  | "$Facebookism$Idx" ->
      mk_custom_fun cx loc targs ident Idx
  | "$Facebookism$TypeAssertIs" ->
      mk_custom_fun cx loc targs ident TypeAssertIs
  | "$Facebookism$TypeAssertThrows" ->
      mk_custom_fun cx loc targs ident TypeAssertThrows
  | "$Facebookism$TypeAssertWraps" ->
      mk_custom_fun cx loc targs ident TypeAssertWraps

  | "$Flow$DebugPrint" ->
      mk_custom_fun cx loc targs ident DebugPrint
  | "$Flow$DebugThrow" ->
      mk_custom_fun cx loc targs ident DebugThrow
  | "$Flow$DebugSleep" ->
      mk_custom_fun cx loc targs ident DebugSleep

  (* You can specify in the .flowconfig the names of types that should be
   * treated like any<actualType>. So if you have
   * suppress_type=$FlowFixMe
   *
   * Then you can do
   *
   * var x: $FlowFixMe<number> = 123;
   *)
  (* TODO move these to type aliases once optional type args
     work properly in type aliases: #7007731 *)
  | type_name when is_suppress_type cx type_name ->
    (* Optional type params are info-only, validated then forgotten. *)
    let _, targs = convert_type_params () in
    reconstruct_ast (AnyT.at Annotated loc) targs

  (* in-scope type vars *)
  | _ when SMap.mem name tparams_map ->
    check_type_arg_arity cx loc targs 0 (fun () ->
      let t = Flow.reposition cx loc (SMap.find_unsafe name tparams_map) in
      let id_info = name, t, Type_table.Other in
      Type_table.set_info name_loc id_info (Context.type_table cx);
      reconstruct_ast t None
    )

  | "$Pred" ->
    let fun_reason = mk_reason (RCustom "abstract predicate function") loc in
    let static_reason = mk_reason (RCustom "abstract predicate static") loc in
    let out_reason = mk_reason (RCustom "open predicate") loc in

    check_type_arg_arity cx loc targs 1 (fun () ->
      match convert_type_params () with
      | [DefT (_, SingletonNumT (f, _))], targs ->
        let n = Pervasives.int_of_float f in
        let key_strs =
          ListUtils.range 0 n |>
          Core_list.map ~f:(fun i -> Some ("x_" ^ Pervasives.string_of_int i)) in
        let emp = Key_map.empty in
        let tins = Unsoundness.at FunctionPrototype loc |> ListUtils.repeat n in
        let tout = OpenPredT (out_reason, MixedT.at loc, emp, emp) in
        reconstruct_ast
          (DefT (fun_reason, FunT (
            dummy_static static_reason,
            mk_reason RPrototype loc |> Unsoundness.function_proto_any,
            mk_functiontype fun_reason tins tout
              ~rest_param:None ~def_reason:fun_reason
              ~params_names:key_strs ~is_predicate:true
          )))
          targs

      | _ ->
        error_type cx loc (FlowError.EPredAnnot loc)
    )

  | "$Refine" ->
    check_type_arg_arity cx loc targs 3 (fun () ->
      match convert_type_params () with
      | [base_t; fun_pred_t; DefT (_, SingletonNumT (f, _))], targs ->
          let idx = Pervasives.int_of_float f in
          let reason = mk_reason (RCustom "refined type") loc in
          let pred = LatentP (fun_pred_t, idx) in
          reconstruct_ast
            (EvalT (base_t, DestructuringT (reason, Refine pred), mk_id()))
            targs
      | _ ->
        error_type cx loc (FlowError.ERefineAnnot loc)
    )

  (* other applications with id as head expr *)
  | _ ->
    let reason = mk_reason (RType name) loc in
    let c = type_identifier cx name name_loc in
    let id_info = name, c, Type_table.Other in
    Type_table.set_info name_loc id_info (Context.type_table cx);
    let t, targs = mk_nominal_type cx reason tparams_map (c, targs) in
    reconstruct_ast t ~id_t:c targs

  end

| loc, Function { Function.
    params = (params_loc, { Function.Params.params; rest });
    return;
    tparams;
  } ->
  let tparams, tparams_map, tparams_ast =
    mk_type_param_declarations cx ~tparams_map tparams in

  let tparams_list = Type.TypeParams.to_list tparams in

  let rev_params, rev_param_asts = List.fold_left (fun (params_acc, asts_acc) (param_loc, param) ->
    let { Function.Param.name; annot; optional } = param in
    let (_, t), _ as annot_ast = convert cx tparams_map annot in
    let t = if optional then Type.optional t else t in
    let name = Option.map ~f:(fun (loc, name) ->
      let id_info = name, t, Type_table.Other in
      Type_table.set_info ~extra_tparams:tparams_list loc id_info (Context.type_table cx);
      (loc, t), name
    ) name in
    (Option.map ~f:ident_name name, t) :: params_acc,
    (param_loc, {
      Function.Param.name;
      annot = annot_ast;
      optional
    }) :: asts_acc
  ) ([], []) params in

  let reason = mk_reason RFunctionType loc in

  let rest_param, rest_param_ast = match rest with
  | Some (rest_loc, { Function.RestParam.argument = (param_loc, param) }) ->
    let { Function.Param.name; annot; optional } = param in
    let (_, rest), _ as annot_ast = convert cx tparams_map annot in
    Some (Option.map ~f:ident_name name, loc_of_t rest, rest),
    Some (rest_loc, {
      Function.RestParam.argument = (param_loc, {
        Function.Param.name = Option.map ~f:(fun (loc, name) -> (loc, rest), name) name;
        annot = annot_ast;
        optional
      });
    })
  | None -> None, None in

  let (_, return_t), _ as return_ast = convert cx tparams_map return in
  let ft =
    DefT (reason, FunT (
      dummy_static reason,
      mk_reason RPrototype loc |> Unsoundness.function_proto_any,
      {
        this_t = bound_function_dummy_this;
        params = List.rev rev_params;
        rest_param;
        return_t;
        is_predicate = false;
        closure_t = 0;
        changeset = Changeset.empty;
        def_reason = reason;
      }))
  in
  let id = Context.make_nominal cx in
  (loc, poly_type_of_tparams id tparams ft),
  Function {
    Function.params = (params_loc, {
      Function.Params.params = List.rev rev_param_asts;
      rest = rest_param_ast;
    });
    return = return_ast;
    tparams = tparams_ast;
  }

| loc, Object { Object.exact; properties; inexact } ->
  let reason_desc = RObjectType in
  let callable = List.exists (function
    | Object.CallProperty (_, { Object.CallProperty.static; _ }) -> not static
    | _ -> false
  ) properties in
  let mk_object ~exact (call_props, dict, props_map, proto, call_deprecated) =
    let call = match List.rev call_props with
      | [] ->
        (* Note that call properties using the call property syntax always override
           $call properties. Previously, if both were present, the $call property
           was ignored, but is now left as a named property. *)
        call_deprecated
      | [t] -> Some t
      | t0::t1::ts ->
        let callable_reason = mk_reason (RCustom "callable object type") loc in
        let rep = InterRep.make t0 t1 ts in
        let t = DefT (callable_reason, IntersectionT rep) in
        Some t
    in
    (* Previously, call properties were stored in the props map under the key
       $call. Unfortunately, this made it possible to specify call properties
       using this syntax in object types, and some libraries adopted this
       syntax.

       Note that call properties using the call property syntax always override
       $call properties. Previously, if both were present, the $call property
       was ignored, but is now left as a named property. *)
    let props_map, call =
      if call <> None then props_map, call
      else match SMap.get "$call" props_map with
      | Some (Field (_, t, (Positive | Neutral))) ->
        SMap.remove "$call" props_map, Some t
      | _ -> props_map, call
    in
    (* Use the same reason for proto and the ObjT so we can walk the proto chain
       and use the root proto reason to build an error. *)
    let props_map, proto = match proto with
      | Some t ->
        (* The existence of a callable property already implies that
         * __proto__ = Function.prototype. Treat __proto__ as a property *)
        if callable
        then
          SMap.add "__proto__" (Field (None, t, Neutral)) props_map,
          FunProtoT (locationless_reason RFunctionPrototype)
        else
          props_map, t
      | None ->
        props_map,
        if callable
        then FunProtoT (locationless_reason RFunctionPrototype)
        else ObjProtoT (locationless_reason RObjectPrototype)
    in
    let call = Option.map call ~f:(Context.make_call_prop cx) in
    let pmap = Context.make_property_map cx props_map in
    let flags = {
      sealed = Sealed;
      exact;
      frozen = false
    } in
    DefT (mk_reason reason_desc loc,
      ObjT (mk_objecttype ~flags ~dict ~call pmap proto))
  in
  let property loc prop props proto call_deprecated =
    match prop with
    | { Object.Property.
        key; value = Object.Property.Init value; optional; variance; _method; _
      } ->
      begin match key with
      (* Previously, call properties were stored in the props map under the key
         $call. Unfortunately, this made it possible to specify call properties
         using this syntax in object types, and some libraries adopted this
         syntax.

         Note that call properties using the call property syntax always override
         $call properties. Previously, if both were present, the $call property
         was ignored, but is now left as a named property. *)
      | Ast.Expression.Object.Property.Identifier (loc, "$call") ->
          Flow.add_output cx Flow_error.(EDeprecatedCallSyntax loc);
          let (_, t), _ as value_ast = convert cx tparams_map value in
          let t = if optional then Type.optional t else t in
          let key = Ast.Expression.Object.Property.Identifier ((loc, t), "$call") in
          props, proto, Some t,
          { prop with Object.Property.key; value = Object.Property.Init value_ast }
      | Ast.Expression.Object.Property.Literal
          (loc, { Ast.Literal.value = Ast.Literal.String name; _ })
      | Ast.Expression.Object.Property.Identifier (loc, name) ->
          Type_inference_hooks_js.dispatch_obj_prop_decl_hook cx name loc;
          let (_, t), _ as value_ast = convert cx tparams_map value in
          let prop_ast t = { prop with Object.Property.
            key = begin match key with
              | Ast.Expression.Object.Property.Literal (_, lit) ->
                Ast.Expression.Object.Property.Literal ((loc, t), lit)
              | Ast.Expression.Object.Property.Identifier _ ->
                Ast.Expression.Object.Property.Identifier ((loc, t), name)
              | _ -> assert_false "branch invariant"
            end;
            value = Object.Property.Init value_ast;
          } in
          if name = "__proto__" && not (_method || optional) && variance = None
          then
            let reason = mk_reason RPrototype (fst value) in
            let proto = Tvar.mk_where cx reason (fun tout ->
              Flow.flow cx (t, ObjTestProtoT (reason, tout))
            ) in
            let prop_ast = prop_ast proto in
            let proto = Some (Flow.mk_typeof_annotation cx reason proto) in
            props, proto, call_deprecated, prop_ast
          else
            let t = if optional then Type.optional t else t in
            let id_info = name, t, Type_table.Other in
            Type_table.set_info loc id_info (Context.type_table cx);
            let polarity = if _method then Positive else polarity variance in
            let props = SMap.add name (Field (Some loc, t, polarity)) props in
            props, proto, call_deprecated, (prop_ast t)
      | Ast.Expression.Object.Property.Literal (loc, _)
      | Ast.Expression.Object.Property.PrivateName (loc, _)
      | Ast.Expression.Object.Property.Computed (loc, _)
          ->
        Flow.add_output cx (FlowError.EUnsupportedKeyInObjectType loc);
        props, proto, call_deprecated, Typed_ast.Type.Object.Property.error
      end

    (* unsafe getter property *)
    | { Object.Property.
        key = Ast.Expression.Object.Property.Identifier (id_loc, name);
        value = Object.Property.Get (loc, f);
        _method; _ } ->
      Flow_js.add_output cx (FlowError.EUnsafeGettersSetters loc);
      let function_type, f_ast =
        match convert cx tparams_map (loc, Ast.Type.Function f) with
        | (_, function_type), Ast.Type.Function f_ast -> function_type, f_ast
        | _ -> assert false
      in
      let return_t = Type.extract_getter_type function_type in
      let id_info = name, return_t, Type_table.Other in
      Type_table.set_info id_loc id_info (Context.type_table cx);
      let props = Properties.add_getter name (Some id_loc) return_t props in
      props, proto, call_deprecated,
      { prop with Object.Property.
        key = Ast.Expression.Object.Property.Identifier ((id_loc, return_t), name);
        value = Object.Property.Get (loc, f_ast);
      }
    (* unsafe setter property *)
    | { Object.Property.
        key = Ast.Expression.Object.Property.Identifier (id_loc, name);
        value = Object.Property.Set (loc, f);
        _method; _ } ->
      Flow_js.add_output cx (FlowError.EUnsafeGettersSetters loc);
      let function_type, f_ast =
        match convert cx tparams_map (loc, Ast.Type.Function f) with
        | (_, function_type), Ast.Type.Function f_ast -> function_type, f_ast
        | _ -> assert false
      in
      let param_t = Type.extract_setter_type function_type in
      let id_info = name, param_t, Type_table.Other in
      Type_table.set_info id_loc id_info (Context.type_table cx);
      let props = Properties.add_setter name (Some id_loc) param_t props in
      props, proto, call_deprecated,
      { prop with Object.Property.
        key = Ast.Expression.Object.Property.Identifier ((id_loc, param_t), name);
        value = Object.Property.Set (loc, f_ast);
      }
    | { Object.Property.
        value = Object.Property.Get _ | Object.Property.Set _; _ } ->
      Flow.add_output cx
        Flow_error.(EUnsupportedSyntax (loc, ObjectPropertyGetSet));
      props, proto, call_deprecated, Typed_ast.Type.Object.Property.error
  in
  let add_call c = function
    | None -> Some ([c], None, SMap.empty, None, None)
    | Some (cs, d, pmap, proto, _) ->
      (* Note that call properties using the call property syntax always override
         $call properties. Previously, if both were present, the $call property
         was ignored, but is now left as a named property. *)
      Some (c::cs, d, pmap, proto, None)
  in
  let make_dict ({ Object.Indexer.id; key; value; variance; _ } as indexer) =
    let (_, key), _ as key_ast = convert cx tparams_map key in
    let (_, value), _ as value_ast = convert cx tparams_map value in
    Some { Type.
      dict_name = Option.map ~f:snd id;
      key;
      value;
      dict_polarity = polarity variance;
    },
    { indexer with Object.Indexer.key = key_ast; value = value_ast; }
  in
  let add_dict loc indexer = function
    | None ->
      let dict, indexer_ast = make_dict indexer in
      Some ([], dict, SMap.empty, None, None), indexer_ast
    | Some (cs, None, pmap, proto, call_deprecated) ->
      let dict, indexer_ast = make_dict indexer in
      Some (cs, dict, pmap, proto, call_deprecated), indexer_ast
    | Some (_, Some _, _, _, _) as o ->
      Flow.add_output cx
        FlowError.(EUnsupportedSyntax (loc, MultipleIndexers));
      o, Typed_ast.Type.Object.Indexer.error
  in
  let add_prop loc p = function
    | None ->
      let pmap, proto, call_deprecated, p_ast = property loc p SMap.empty None None in
      Some ([], None, pmap, proto, call_deprecated), p_ast
    | Some (cs, d, pmap, proto, call_deprecated) ->
      let pmap, proto, call_deprecated, p_ast = property loc p pmap proto call_deprecated in
      Some (cs, d, pmap, proto, call_deprecated), p_ast
  in
  let o, ts, spread, rev_prop_asts = List.fold_left Object.(
    fun (o, ts, spread, rev_prop_asts) -> function
    | CallProperty (loc, { CallProperty.value = (value_loc, ft); static }) ->
      let t, ft_ast = match convert cx tparams_map (loc, Ast.Type.Function ft) with
        | (_, t), Ast.Type.Function ft_ast -> t, ft_ast
        | _ -> assert false
      in
      let prop_ast = CallProperty (loc, { CallProperty.value = value_loc, ft_ast; static }) in
      add_call t o, ts, spread, prop_ast::rev_prop_asts
    | Indexer (loc, i) ->
      let o, i_ast = add_dict loc i o in
      o, ts, spread, Indexer (loc, i_ast)::rev_prop_asts
    | Property (loc, p) ->
      let o, p_ast = add_prop loc p o in
      o, ts, spread, Property (loc, p_ast)::rev_prop_asts
    | InternalSlot (loc, slot) ->
      let { Object.InternalSlot.
        id = (_, name);
        value;
        static=_; (* object props are never static *)
        optional;
        _method=_;
      } = slot in
      if name = "call" then
        let (_, t), _ as value_ast = convert cx tparams_map value in
        let t = if optional then Type.optional t else t in
        add_call t o, ts, spread,
        InternalSlot (loc, { slot with Object.InternalSlot.value = value_ast })::rev_prop_asts
      else (
        Flow.add_output cx FlowError.(
          EUnsupportedSyntax (loc, UnsupportedInternalSlot {
            name;
            static = false;
          }));
        o, ts, spread, InternalSlot (loc, Typed_ast.Type.Object.InternalSlot.error)::rev_prop_asts
      )
    | SpreadProperty (loc, { Object.SpreadProperty.argument }) ->
      let ts = match o with
      | None -> ts
      | Some o -> (mk_object ~exact:true o)::ts
      in
      let (_, o), _ as argument_ast = convert cx tparams_map argument in
      None, o::ts, true,
      SpreadProperty (loc, { SpreadProperty.argument = argument_ast })::rev_prop_asts
  ) (None, [], false, []) properties in
  let ts = match o with
  | None -> ts
  | Some o -> mk_object ~exact:spread o::ts
  in (
  loc,
  match ts with
  | [] ->
    let t = mk_object ~exact ([], None, SMap.empty, None, None) in
    if exact
    then ExactT (mk_reason (RExactType reason_desc) loc, t)
    else t
  | [t] when not spread ->
    if exact
    then ExactT (mk_reason (RExactType reason_desc) loc, t)
    else t
  | t::ts ->
    let open Type.Object.Spread in
    let reason = mk_reason RObjectType loc in
    let target = Annot {make_exact = exact} in
    EvalT (t, TypeDestructorT (unknown_use, reason, SpreadType (target, ts)), mk_id ())
  ), Object { Object.exact; properties = List.rev rev_prop_asts; inexact }

| loc, Interface {Interface.extends; body} ->
  let body_loc, {Ast.Type.Object.properties; exact; inexact = _inexact } = body in
  let reason = mk_reason RInterfaceType loc in
  let iface_sig, extend_asts =
    let id = ALoc.none in
    let extends, extend_asts = extends
      |> Core_list.map ~f:(mk_interface_super cx tparams_map)
      |> List.split
    in
    let super =
      let callable = List.exists Ast.Type.Object.(function
        | CallProperty (_, { CallProperty.static; _ }) -> not static
        | _ -> false
      ) properties in
      Class_sig.Interface { extends; callable }
    in
    Class_sig.empty id reason None tparams_map super, extend_asts
  in
  let iface_sig, property_asts =
    add_interface_properties cx tparams_map properties iface_sig in
  Class_sig.generate_tests cx (fun iface_sig ->
    Class_sig.check_super cx reason iface_sig;
    Class_sig.check_implements cx reason iface_sig
  ) iface_sig |> ignore;
  (loc, Class_sig.thistype cx iface_sig),
  Interface { Interface.
    body = body_loc, { Object.
      exact;
      inexact = false;
      properties = property_asts;
    };
    extends = extend_asts;
  }

| loc, Exists ->
  add_deprecated_type_error_if_not_lib_file cx loc;
  (* Do not evaluate existential type variables when map is non-empty. This
     ensures that existential type variables under a polymorphic type remain
     unevaluated until the polymorphic type is applied. *)
  let force = SMap.is_empty tparams_map in
  let reason = derivable_reason (mk_reason RExistential loc) in
  if force then begin
    let tvar = Tvar.mk cx reason in
    Type_table.set_info loc ("Star", tvar, Type_table.Exists) (Context.type_table cx);
    (loc, tvar), Exists
  end
  else (loc, ExistsT reason), Exists
)

and convert_list =
  let rec loop (ts, tasts) cx tparams_map = function
  | [] -> (List.rev ts, List.rev tasts)
  | ast::asts ->
    let (_, t), _ as tast = convert cx tparams_map ast in
    loop (t::ts, tast::tasts) cx tparams_map asts
  in
  fun cx tparams_map asts ->
    loop ([], []) cx tparams_map asts

and convert_opt cx tparams_map ast_opt =
  let tast_opt = Option.map ~f:(convert cx tparams_map) ast_opt in
  let t_opt = Option.map ~f:(fun ((_, x), _) -> x) tast_opt in
  t_opt, tast_opt

and convert_qualification ?(lookup_mode=ForType) cx reason_prefix
  = Ast.Type.Generic.Identifier.(function
  | Qualified (loc, { qualification; id; }) as qualified ->
    let m, qualification =
      convert_qualification ~lookup_mode cx reason_prefix qualification in
    let id_loc, name = id in
    let desc = RCustom (spf "%s `%s`" reason_prefix (qualified_name qualified)) in
    let reason = mk_reason desc loc in
    let id_reason = mk_reason desc id_loc in
    let t = Tvar.mk_where cx reason (fun t ->
      let id_info = name, t, Type_table.Other in
      Type_table.set_info id_loc id_info (Context.type_table cx);
      let use_op = Op (GetProperty (mk_reason (RType (qualified_name qualified)) loc)) in
      Flow.flow cx (m, GetPropT (use_op, id_reason, Named (id_reason, name), t));
    ) in
    t, Qualified (loc, { qualification; id = (id_loc, t), name; })

  | Unqualified (loc, name) ->
    let t = Env.get_var ~lookup_mode cx name loc in
    let id_info = name, t, Type_table.Other in
    Type_table.set_info loc id_info (Context.type_table cx);
    t, Unqualified ((loc, t), name)
)

and mk_func_sig =
  let open Ast.Type.Function in
  let add_param cx tparams_map (x, rev_param_asts) (loc, param) =
    let { Param.name = id; annot; optional } = param in
    let (_, t), _ as annot = convert cx tparams_map annot in
    Func_params.add_simple cx ~optional loc id t x,
    (loc, { Param.
      name = Option.map ~f:(fun (loc, name) -> (loc, t), name) id;
      annot;
      optional
    })::rev_param_asts
  in
  let add_rest cx tparams_map (loc, param) x =
    let { Param.name = id; annot; optional } = param in
    let (_, t), _ as annot = convert cx tparams_map annot in
    Func_params.add_rest cx loc id t x,
    (loc, { Param.
      name = Option.map ~f:(fun (loc, name) -> (loc, t), name) id;
      annot;
      optional
    })
  in
  let convert_params cx tparams_map (loc, {Params.params; rest}) =
    let params, rev_param_asts =
      List.fold_left (add_param cx tparams_map) (Func_params.empty, []) params in
    match rest with
    | Some (rest_loc, { RestParam.argument }) ->
      let params, argument = add_rest cx tparams_map argument params in
      params, (
        loc,
        { Params.
          params = List.rev rev_param_asts;
          rest = Some (rest_loc, { RestParam.argument; })
        }
      )
    | None ->
      params, (loc, { Params.params = List.rev rev_param_asts; rest = None; })
  in
  fun cx tparams_map loc func ->
    let tparams, tparams_map, tparams_ast =
      mk_type_param_declarations cx ~tparams_map func.tparams in
    Type_table.with_typeparams (TypeParams.to_list tparams) (Context.type_table cx) @@ fun _ ->
    let fparams, params_ast = convert_params cx tparams_map func.Ast.Type.Function.params in
    let (_, return_t), _ as return_ast = convert cx tparams_map func.return in
    { Func_sig.
      reason = mk_reason RFunctionType loc;
      kind = Func_sig.Ordinary;
      tparams;
      tparams_map;
      fparams;
      body = None;
      return_t;
    }, { Ast.Type.Function.
      tparams = tparams_ast;
      params = params_ast;
      return = return_ast;
    }

and mk_type cx tparams_map reason = function
  | None ->
      let t =
        if Context.is_weak cx
        then Unsoundness.why WeakContext reason
        else Tvar.mk cx reason
      in
      Hashtbl.replace (Context.annot_table cx) (aloc_of_reason reason |> ALoc.to_loc) t;
      t, None

  | Some annot ->
      let (_, t), _ as annot_ast = convert cx tparams_map annot in
      t, Some annot_ast

and mk_type_annotation cx tparams_map reason = function
| T.Missing loc ->
  let t, _ = mk_type cx tparams_map reason None in
  t, T.Missing (loc, t)
| T.Available annot ->
  let t, ast_annot = mk_type_available_annotation cx tparams_map annot in
  t, T.Available ast_annot

and mk_type_available_annotation cx tparams_map (loc, annot) =
  let (_, t), _ as annot_ast = convert cx tparams_map annot in
  t, (loc, annot_ast)

and mk_singleton_string loc key =
  let reason = mk_reason (RStringLit key) loc in
  DefT (reason, SingletonStrT key)

and mk_singleton_number loc num raw =
  let reason = mk_reason (RNumberLit raw) loc in
  DefT (reason, SingletonNumT (num, raw))

and mk_singleton_boolean loc b =
  let reason = mk_reason (RBooleanLit b) loc in
  DefT (reason, SingletonBoolT b)

(* Given the type of expression C and type arguments T1...Tn, return the type of
   values described by C<T1,...,Tn>, or C when there are no type arguments. *)
and mk_nominal_type cx reason tparams_map (c, targs) =
  let reason = annot_reason reason in
  match targs with
  | None ->
      Flow.mk_instance cx reason c, None
  | Some (loc, targs) ->
      let annot_loc = aloc_of_reason reason in
      let targs, targs_ast = convert_list cx tparams_map targs in
      typeapp ~annot_loc c targs, Some (loc, targs_ast)

(* take a list of AST type param declarations,
   do semantic checking and create types for them. *)
and mk_type_param_declarations cx ?(tparams_map=SMap.empty) tparams =
  let open Ast.Type.ParameterDeclaration in
  let add_type_param (tparams, tparams_map, bounds_map, rev_asts) (loc, type_param) =
    let { TypeParam.name = name_loc, name as id; bound; variance; default; } = type_param in
    let reason = mk_reason (RType name) name_loc in
    let bound, bound_ast = match bound with
    | Ast.Type.Missing loc ->
        let t = DefT (reason, MixedT Mixed_everything) in
        t, Ast.Type.Missing (loc, t)
    | Ast.Type.Available (bound_loc, u) ->
        let bound, bound_ast = mk_type cx tparams_map reason (Some u) in
        let bound_ast = match bound_ast with
        | Some ast -> Ast.Type.Available (bound_loc, ast)
        | None -> Ast.Type.Missing (bound_loc, bound)
        in
        bound, bound_ast
    in
    let default, default_ast = match default with
    | None -> None, None
    | Some default ->
        let t, default_ast = mk_type cx tparams_map reason (Some default) in
        Flow.flow_t cx (Flow.subst cx bounds_map t,
                           Flow.subst cx bounds_map bound);
        Some t, default_ast in
    let polarity = polarity variance in
    let tparam = { reason; name; bound; polarity; default; } in
    let t = BoundT (reason, name, polarity) in
    let id_info = name, t, Type_table.Other in

    let name_ast =
      let loc, ident = id in
      (loc, t), ident
    in

    let ast = (loc, t), {
      TypeParam.name = name_ast;
      bound = bound_ast;
      variance;
      default = default_ast
    } in
    let tparams = tparam :: tparams in
    Type_table.set_info ~extra_tparams:tparams name_loc id_info (Context.type_table cx);
    tparams,
    SMap.add name t tparams_map,
    SMap.add name (Flow.subst cx bounds_map bound) bounds_map,
    ast :: rev_asts
  in
  match tparams with
  | None -> None, tparams_map, None
  | Some (tparams_loc, tparams) ->
    let rev_tparams, tparams_map, _, rev_asts =
      List.fold_left add_type_param ([], tparams_map, SMap.empty, []) tparams
    in
    let tparams_ast = Some (tparams_loc, List.rev rev_asts) in
    let tparams = match List.rev rev_tparams with
    | [] -> None
    | hd::tl -> Some (tparams_loc, (hd, tl))
    in
    tparams, tparams_map, tparams_ast

and type_identifier cx name loc =
  if Type_inference_hooks_js.dispatch_id_hook cx name loc
  then Unsoundness.at InferenceHooks loc
  else if name = "undefined"
  then VoidT.at loc
  else Env.var_ref ~lookup_mode:ForType cx name loc

and mk_interface_super cx tparams_map (loc, {Ast.Type.Generic.id; targs}) =
  let lookup_mode = Env.LookupMode.ForType in
  let c, id = convert_qualification ~lookup_mode cx "extends" id in
  let typeapp, targs = match targs with
  | None -> (loc, c, None), None
  | Some (targs_loc, targs) ->
    let ts, targs_ast = convert_list cx tparams_map targs in
    (loc, c, Some ts), Some (targs_loc, targs_ast)
  in
  typeapp, (loc, { Ast.Type.Generic.id; targs })

and add_interface_properties cx tparams_map properties s =
  let open Class_sig in
  let x, rev_prop_asts =
    List.fold_left Ast.Type.Object.(fun (x, rev_prop_asts) -> function
    | CallProperty (loc, { CallProperty.value = value_loc, ft; static }) ->
      let (_, t), ft = convert cx tparams_map (loc, Ast.Type.Function ft) in
      let ft = match ft with Ast.Type.Function ft -> ft | _ -> assert false in
      append_call ~static t x,
      CallProperty (loc, { CallProperty.
        value = value_loc, ft;
        static;
      })::rev_prop_asts
    | Indexer (loc, { Indexer.static; _ })
      when mem_field ~static "$key" x ->
      Flow.add_output cx
        Flow_error.(EUnsupportedSyntax (loc, MultipleIndexers));
      x, Indexer (loc, Typed_ast.Type.Object.Indexer.error)::rev_prop_asts
    | Indexer (loc, indexer) ->
      let { Indexer.key; value; static; variance; _ } = indexer in
      let k, _ as key = convert cx tparams_map key in
      let v, _ as value = convert cx tparams_map value in
      let polarity = polarity variance in
      add_indexer ~static polarity ~key:k ~value:v x,
      Indexer (loc, { indexer with Indexer.key; value; })::rev_prop_asts
    | Property (loc, ({ Property.
        key; value; static; proto; optional; _method; variance;
      } as prop)) ->
      if optional && _method
      then Flow.add_output cx Flow_error.(EInternal (loc, OptionalMethod));
      let polarity = polarity variance in
      let x, prop = Ast.Expression.Object.(
        match _method, key, value with
        | _, Property.Literal (loc, _), _
        | _, Property.PrivateName (loc, _), _
        | _, Property.Computed (loc, _), _ ->
            Flow.add_output cx (Flow_error.EUnsupportedSyntax (loc, Flow_error.IllegalName));
            x, (loc, Typed_ast.Type.Object.Property.error)

        (* Previously, call properties were stored in the props map under the key
           $call. Unfortunately, this made it possible to specify call properties
           using this syntax in interfaces, declared classes, and even normal classes.

           Note that $call properties always override the call property syntax.
           As before, if both are present, the $call property is used and the call
           property is ignored. *)
        | _, (Property.Identifier (id_loc, "$call")),
            Ast.Type.Object.Property.Init value when not proto ->
            Flow.add_output cx Flow_error.(EDeprecatedCallSyntax id_loc);
            let (_, t), _ as value_ast = convert cx tparams_map value in
            let t = if optional then Type.optional t else t in
            add_call_deprecated ~static t x,
            Ast.Type.(loc, { prop with Object.Property.
              key = Property.Identifier ((id_loc, t), "$call");
              value = Object.Property.Init value_ast;
            })

        | true, (Property.Identifier (id_loc, name)),
            Ast.Type.Object.Property.Init (func_loc, Ast.Type.Function func) ->
            let fsig, func_ast = mk_func_sig cx tparams_map loc func in
            let ft = Func_sig.methodtype cx fsig in
            let append_method = match static, name with
            | false, "constructor" -> append_constructor (Some id_loc)
            | _ -> append_method ~static name id_loc
            in
            append_method fsig x,
            Ast.Type.(loc, { prop with Object.Property.
              key = Property.Identifier ((id_loc, ft), name);
              value = Object.Property.Init ((func_loc, ft), Function func_ast);
            })

        | true, Property.Identifier _, _ ->
            Flow.add_output cx
              Flow_error.(EInternal (loc, MethodNotAFunction));
            x, (loc, Typed_ast.Type.Object.Property.error)

        | false, (Property.Identifier (id_loc, name)),
            Ast.Type.Object.Property.Init value ->
            let (_, t), _ as value_ast = convert cx tparams_map value in
            let t = if optional then Type.optional t else t in
            let add = if proto then add_proto_field else add_field ~static in
            add name id_loc polarity (Annot t) x,
            Ast.Type.(loc, { prop with Object.Property.
              key = Property.Identifier ((id_loc, t), name);
              value = Object.Property.Init value_ast;
            })

        (* unsafe getter property *)
        | _, (Property.Identifier (id_loc, name)),
            Ast.Type.Object.Property.Get (get_loc, func) ->
            Flow_js.add_output cx (Flow_error.EUnsafeGettersSetters loc);
            let fsig, func_ast = mk_func_sig cx tparams_map loc func in
            let prop_t = fsig.Func_sig.return_t in
            add_getter ~static name id_loc fsig x,
            Ast.Type.(loc, { prop with Object.Property.
              key = Property.Identifier ((id_loc, prop_t), name);
              value = Object.Property.Get (get_loc, func_ast);
            })

        (* unsafe setter property *)
        | _, (Property.Identifier (id_loc, name)),
            Ast.Type.Object.Property.Set (set_loc, func) ->
            Flow_js.add_output cx (Flow_error.EUnsafeGettersSetters loc);
            let fsig, func_ast = mk_func_sig cx tparams_map loc func in
            let prop_t = match fsig with
            | { Func_sig.tparams=None; fparams; _ } ->
              (match Func_params.value fparams with
              | [_, t] -> t
              | _ -> AnyT.at AnyError id_loc (* error case: report any ok *))
            | _ -> AnyT.at AnyError id_loc (* error case: report any ok *) in
            add_setter ~static name id_loc fsig x,
            Ast.Type.(loc, { prop with Object.Property.
              key = Property.Identifier ((id_loc, prop_t), name);
              value = Object.Property.Set (set_loc, func_ast);
            })
        )
      in
      x, Ast.Type.Object.Property prop :: rev_prop_asts

    | InternalSlot (loc, slot) ->
      let { InternalSlot.
        id = _, name;
        value;
        optional;
        static;
        _method;
      } = slot in
      if name = "call" then
        let (_, t), _ as value = convert cx tparams_map value in
        let t = if optional then Type.optional t else t in
        append_call ~static t x,
        InternalSlot (loc, { slot with InternalSlot.value })::rev_prop_asts
      else (
        Flow.add_output cx Flow_error.(
          EUnsupportedSyntax (loc, UnsupportedInternalSlot {
            name;
            static;
          }));
        x, InternalSlot (loc, Typed_ast.Type.Object.InternalSlot.error)::rev_prop_asts
      )

    | SpreadProperty (loc, _) ->
      Flow.add_output cx Flow_error.(EInternal (loc, InterfaceTypeSpread));
      x,
      SpreadProperty (loc, Typed_ast.Type.Object.SpreadProperty.error)::rev_prop_asts
  ) (s, []) properties
  in
  x, List.rev rev_prop_asts

let mk_super cx tparams_map loc c targs =
  match targs with
  | None -> (loc, c, None), None
  | Some (targs_loc, targs) ->
    let ts, targs_ast = convert_list cx tparams_map targs in
    (loc, c, Some ts), Some (targs_loc, targs_ast)

let mk_interface_sig cx reason decl =
  let open Class_sig in
  let { Ast.Statement.Interface.
    id = id_loc, id_name;
    tparams;
    body = (body_loc, { Ast.Type.Object.properties; exact; inexact = _inexact });
    extends;
    _;
  } = decl in

  let self = Tvar.mk cx reason in

  let tparams, tparams_map, tparams_ast =
    mk_type_param_declarations cx tparams in

  let id_info = id_name, self, Type_table.Other in
  Type_table.set_info id_loc id_info (Context.type_table cx);

  let iface_sig, extends_ast =
    let id = id_loc in
    let extends, extends_ast =
      extends
      |> Core_list.map ~f:(mk_interface_super cx tparams_map)
      |> List.split in
    let super =
      let callable = List.exists Ast.Type.Object.(function
        | CallProperty (_, { CallProperty.static; _ }) -> not static
        | _ -> false
      ) properties in
      Interface { extends; callable }
    in
    empty id reason tparams tparams_map super, extends_ast
  in

  (* TODO: interfaces don't have a name field, or even statics *)
  let iface_sig = add_name_field iface_sig in

  let iface_sig, properties = add_interface_properties cx tparams_map properties iface_sig in

  iface_sig, self,
  { Ast.Statement.Interface.
    id = (id_loc, self), id_name;
    tparams = tparams_ast;
    extends = extends_ast;
    body = body_loc, { Ast.Type.Object.exact; properties; inexact = false };
  }

let mk_declare_class_sig =
  let open Class_sig in

  let mk_mixins cx tparams_map (loc, {Ast.Type.Generic.id; targs}) =
    let name = qualified_name id in
    let r = mk_reason (RType name) loc in
    let i, id =
      let lookup_mode = Env.LookupMode.ForValue in
      convert_qualification ~lookup_mode cx "mixins" id
    in
    let props_bag = Tvar.mk_derivable_where cx r (fun tvar ->
      Flow.flow cx (i, Type.MixinT (r, tvar))
    ) in
    let t, targs = mk_super cx tparams_map loc props_bag targs in
    t, (loc, { Ast.Type.Generic.id; targs })
  in

  let is_object_builtin_libdef (loc, name) =
    name = "Object" &&
    match ALoc.source loc with
    | None -> false
    | Some source -> File_key.is_lib_file source
  in

  fun cx reason decl ->
    let { Ast.Statement.DeclareClass.
      id = (id_loc, id_name) as ident;
      tparams;
      body = body_loc, { Ast.Type.Object.properties; exact; inexact = _inexact };
      extends;
      mixins;
      implements;
    } = decl in

    let self = Tvar.mk cx reason in

    let tparams, tparams_map, tparam_asts =
      mk_type_param_declarations cx tparams in

    let id_info = id_name, self, Type_table.Other in
    Type_table.set_info id_loc id_info (Context.type_table cx);

    let _, tparams, tparams_map = Class_sig.add_this self cx reason tparams tparams_map in

    Type_table.with_typeparams (TypeParams.to_list tparams) (Context.type_table cx) @@ fun _ ->

    let iface_sig, extends_ast, mixins_ast, implements_ast =
      let id = id_loc in
      let extends, extends_ast =
        match extends with
        | Some (loc, {Ast.Type.Generic.id; targs}) ->
          let lookup_mode = Env.LookupMode.ForValue in
          let i, id =
            convert_qualification ~lookup_mode cx "mixins" id in
          let t, targs = mk_super cx tparams_map loc i targs in
          Some t, Some (loc, { Ast.Type.Generic.id; targs })
        | None ->
          None, None
      in
      let mixins, mixins_ast =
        mixins
        |> Core_list.map ~f:(mk_mixins cx tparams_map)
        |> List.split
      in
      let implements, implements_ast =
        implements
        |> Core_list.map ~f:(fun (loc, i) ->
            let { Ast.Class.Implements.id = (id_loc, name); targs } = i in
            let c = Env.get_var ~lookup_mode:Env.LookupMode.ForType cx name id_loc in
            let typeapp, targs = match targs with
            | None -> (loc, c, None), None
            | Some (targs_loc, targs) ->
              let ts, targs_ast = convert_list cx tparams_map targs in
              (loc, c, Some ts), Some (targs_loc, targs_ast)
            in
            typeapp, (loc, { Ast.Class.Implements.id = (id_loc, c), name; targs })
        )
        |> List.split in
      let super =
        let extends = match extends with
        | None -> Implicit { null = is_object_builtin_libdef ident }
        | Some extends -> Explicit extends
        in
        Class { extends; mixins; implements }
      in
      empty id reason tparams tparams_map super,
      extends_ast, mixins_ast, implements_ast
    in

    (* All classes have a static "name" property. *)
    let iface_sig = add_name_field iface_sig in

    let iface_sig, properties =
      add_interface_properties cx tparams_map properties iface_sig in

    (* Add a default ctor if we don't have a ctor and won't inherit one from a super *)
    let iface_sig =
      if mem_constructor iface_sig || extends <> None || mixins <> [] then
        iface_sig
      else
        let reason = replace_reason_const RDefaultConstructor reason in
        add_default_constructor reason iface_sig
    in
    iface_sig, self,
    { Ast.Statement.DeclareClass.
      id = (id_loc, self), id_name;
      tparams = tparam_asts;
      body = body_loc, { Ast.Type.Object.properties; exact; inexact = false };
      extends = extends_ast;
      mixins = mixins_ast;
      implements = implements_ast;
    }
