(*
  This is the file that handles turning Reason JSX' agnostic function call into
  a ReasonReact-specific function call. Aka, this is a macro, using OCaml's ppx
  facilities; https://whitequark.org/blog/2014/04/16/a-guide-to-extension-
  points-in-ocaml/
  You wouldn't use this file directly; it's used by BuckleScript's
  bsconfig.json. Specifically, there's a field called `react-jsx` inside the
  field `reason`, which enables this ppx through some internal call in bsb
*)

(*
  There are two different transforms that can be selected in this file (v2 and v3):
  v2:
  transform `[@JSX] div(~props1=a, ~props2=b, ~children=[foo, bar], ())` into
  `ReactDOMRe.createElement("div", ~props={"props1": 1, "props2": b}, [|foo,
  bar|])`.
  transform `[@JSX] div(~props1=a, ~props2=b, ~children=foo, ())` into
  `ReactDOMRe.createElementVariadic("div", ~props={"props1": 1, "props2": b}, foo)`.
  transform the upper-cased case
  `[@JSX] Foo.createElement(~key=a, ~ref=b, ~foo=bar, ~children=[], ())` into
  `ReasonReact.element(~key=a, ~ref=b, Foo.make(~foo=bar, [||]))`
  transform `[@JSX] [foo]` into
  `ReactDOMRe.createElement(ReasonReact.fragment, [|foo|])`
  v3:
  transform `[@JSX] div(~props1=a, ~props2=b, ~children=[foo, bar], ())` into
  `ReactDOMRe.createDOMElementVariadic("div", ReactDOMRe.domProps(~props1=1, ~props2=b), [|foo, bar|])`.
  transform the upper-cased case
  `[@JSX] Foo.createElement(~key=a, ~ref=b, ~foo=bar, ~children=[], ())` into
  `React.createElement(Foo.make, Foo.makeProps(~key=a, ~ref=b, ~foo=bar, ()))`
  transform the upper-cased case
  `[@JSX] Foo.createElement(~foo=bar, ~children=[foo, bar], ())` into
  `React.createElementVariadic(Foo.make, Foo.makeProps(~foo=bar, ~children=React.null, ()), [|foo, bar|])`
  transform `[@JSX] [foo]` into
  `ReactDOMRe.createElement(ReasonReact.fragment, [|foo|])`
*)

open Ast_helper
open Ast_mapper
open Asttypes
open Parsetree
open Longident

let rec find_opt p = function
  | [] -> None
  | x :: l -> if p x then Some x else find_opt p l

#if OCAML_VERSION >= (4,3,0)

let nolabel = Nolabel
let labelled str = Labelled str
let optional str = Optional str
let isOptional str = match str with
| Optional _ -> true
| _ -> false
let isLabelled str = match str with
| Labelled _ -> true
| _ -> false
let getLabel str = match str with
| Optional str | Labelled str -> str
| Nolabel -> ""
let optionIdent = Lident "option"

let argIsKeyRef = function
  | (Labelled ("key" | "ref"), _) | (Optional ("key" | "ref"), _) -> true
  | _ -> false
let constantString ~loc str = Ast_helper.Exp.constant ~loc (Pconst_string (str, None))

#else

let nolabel = ""
let labelled str = str
let optional str = "?" ^ str
let isOptional str = str <> "" && str.[0] = '?'
let isLabelled str = str <> "" && not (isOptional str)
let getLabel str = if (isOptional str) then (String.sub str 1 ((String.length str) - 1)) else str
let optionIdent = Ldot (Lident "*predef*","option")

let argIsKeyRef = function
  | (("key" | "ref"), _) | (("?key" | "?ref"), _) -> true
  | _ -> false
let constantString ~loc str = Ast_helper.Exp.constant ~loc (Asttypes.Const_string (str, None))

#endif
let safeTypeFromValue valueStr =
let valueStr = getLabel valueStr in
match String.sub valueStr 0 1 with
| "_" -> "T" ^ valueStr
| _ -> valueStr
let keyType loc = Typ.constr ~loc {loc; txt=optionIdent} [Typ.constr ~loc {loc; txt=Lident "string"} []]

type 'a children = | ListLiteral of 'a | Exact of 'a
type componentConfig = {
  propsName: string;
}

(* if children is a list, convert it to an array while mapping each element. If not, just map over it, as usual *)
let transformChildrenIfListUpper ~loc ~mapper theList =
  let rec transformChildren_ theList accum =
    (* not in the sense of converting a list to an array; convert the AST
       reprensentation of a list to the AST reprensentation of an array *)
    match theList with
    | {pexp_desc = Pexp_construct ({txt = Lident "[]"}, None)} -> begin
      match accum with
      | [singleElement] -> Exact singleElement
      | accum -> ListLiteral (List.rev accum |> Exp.array ~loc)
      end
    | {pexp_desc = Pexp_construct (
        {txt = Lident "::"},
        Some {pexp_desc = Pexp_tuple (v::acc::[])}
      )} ->
      transformChildren_ acc ((mapper.expr mapper v)::accum)
    | notAList -> Exact (mapper.expr mapper notAList)
  in
  transformChildren_ theList []

let transformChildrenIfList ~loc ~mapper theList =
  let rec transformChildren_ theList accum =
    (* not in the sense of converting a list to an array; convert the AST
       reprensentation of a list to the AST reprensentation of an array *)
    match theList with
    | {pexp_desc = Pexp_construct ({txt = Lident "[]"}, None)} ->
      List.rev accum |> Exp.array ~loc
    | {pexp_desc = Pexp_construct (
        {txt = Lident "::"},
        Some {pexp_desc = Pexp_tuple (v::acc::[])}
      )} ->
      transformChildren_ acc ((mapper.expr mapper v)::accum)
    | notAList -> mapper.expr mapper notAList
  in
  transformChildren_ theList []

let extractChildren ?(removeLastPositionUnit=false) ~loc propsAndChildren =
  let rec allButLast_ lst acc = match lst with
    | [] -> []
#if OCAML_VERSION >= (4,3,0)
    | (Nolabel, {pexp_desc = Pexp_construct ({txt = Lident "()"}, None)})::[] -> acc
    | (Nolabel, _)::rest -> raise (Invalid_argument "JSX: found non-labelled argument before the last position")
#else
    | ("", {pexp_desc = Pexp_construct ({txt = Lident "()"}, None)})::[] -> acc
    | ("", _)::_rest -> raise (Invalid_argument "JSX: found non-labelled argument before the last position")
#endif
    | arg::rest -> allButLast_ rest (arg::acc)
  in
  let allButLast lst = allButLast_ lst [] |> List.rev in
  match (List.partition (fun (label, _) -> label = labelled "children") propsAndChildren) with
  | ([], props) ->
    (* no children provided? Place a placeholder list *)
    (Exp.construct ~loc {loc; txt = Lident "[]"} None, if removeLastPositionUnit then allButLast props else props)
  | ([(_, childrenExpr)], props) ->
    (childrenExpr, if removeLastPositionUnit then allButLast props else props)
  | _ -> raise (Invalid_argument "JSX: somehow there's more than one `children` label")

(* Helper method to look up the [@react.component] attribute *)
let hasAttr (loc, _) =
  loc.txt = "react.component"

(* Helper method to filter out any attribute that isn't [@react.component] *)
let otherAttrsPure (loc, _) =
  loc.txt <> "react.component"

(* Iterate over the attributes and try to find the [@react.component] attribute *)
let hasAttrOnBinding {pvb_attributes} = find_opt hasAttr pvb_attributes <> None

(* Filter the [@react.component] attribute and immutably replace them on the binding *)
let filterAttrOnBinding binding = {binding with pvb_attributes = List.filter otherAttrsPure binding.pvb_attributes}

(* Finds the name of the variable the binding is assigned to, otherwise raises Invalid_argument *)
let getFnName binding =
  match binding with
  | {pvb_pat = {
      ppat_desc = Ppat_var {txt}
    }} -> txt
  | _ -> raise (Invalid_argument "react.component calls cannot be destructured.")

(* Lookup the value of `props` otherwise raise Invalid_argument error *)
let getPropsNameValue _acc (loc, exp) =
    match (loc, exp) with
    | ({ txt = Lident "props" }, { pexp_desc = Pexp_ident {txt = Lident str} }) -> { propsName = str }
    | ({ txt }, _) -> raise (Invalid_argument ("react.component only accepts props as an option, given: " ^ Longident.last txt))

(* Lookup the `props` record or string as part of [@react.component] and store the name for use when rewriting *)
let getPropsAttr payload =
  let defaultProps = {propsName = "Props"} in
  match payload with
  | Some(PStr(
    {pstr_desc = Pstr_eval ({
      pexp_desc = Pexp_record (recordFields, None)
      }, _)}::_rest
      )) ->
      List.fold_left getPropsNameValue defaultProps recordFields
  | Some(PStr({pstr_desc = Pstr_eval ({pexp_desc = Pexp_ident {txt = Lident "props"}}, _)}::_rest)) -> {propsName = "props"}
  | Some(PStr({pstr_desc = Pstr_eval (_, _)}::_rest)) -> raise (Invalid_argument ("react.component accepts a record config with props as an options."))
  | _ -> defaultProps

(* Plucks the label, loc, and type_ from an AST node *)
let pluckLabelDefaultLocType (label, default, _, _, loc, type_) = (label, default, loc, type_)

(* Lookup the filename from the location information on the AST node and turn it into a valid module identifier *)
let filenameFromLoc (pstr_loc: Location.t) =
  let fileName = match pstr_loc.loc_start.pos_fname with
  | "" -> !Location.input_name
  | fileName -> fileName
  in
  let fileName = try
      Filename.chop_extension (Filename.basename fileName)
    with | Invalid_argument _-> fileName in
#if OCAML_VERSION >= (4,3,0)
  let fileName = String.capitalize_ascii fileName in
#else
  let fileName = String.capitalize fileName in
#endif
  fileName

(* Build a string representation of a module name with segments separated by $ *)
let makeModuleName fileName nestedModules fnName =
  let fullModuleName = match (fileName, nestedModules, fnName) with
  (* TODO: is this even reachable? It seems like the fileName always exists *)
  | ("", nestedModules, "make") -> nestedModules
  | ("", nestedModules, fnName) -> List.rev (fnName :: nestedModules)
  | (fileName, nestedModules, "make") -> fileName :: (List.rev nestedModules)
  | (fileName, nestedModules, fnName) -> fileName :: (List.rev (fnName :: nestedModules))
  in
  let fullModuleName = String.concat "$" fullModuleName in
  fullModuleName

(*
  AST node builders
  These functions help us build AST nodes that are needed when transforming a [@react.component] into a
  constructor and a props external
*)

(* Build an AST node representing all named args for the `external` definition for a component's props *)
let rec recursivelyMakeNamedArgsForExternal list args =
  match list with
  | (label, default, loc, interiorType)::tl ->
    recursivelyMakeNamedArgsForExternal tl (Typ.arrow
    ~loc
    label
    (match (label, interiorType, default) with
    (* ~foo=1 *)
    | (label, None, Some _) ->
#if OCAML_VERSION >= (4,3,0)
    {
      ptyp_desc = Ptyp_var (safeTypeFromValue label);
      ptyp_loc = loc;
      ptyp_attributes = [];
    }
#else
    {
      ptyp_loc = loc;
      ptyp_attributes = [];
      ptyp_desc = Ptyp_constr ({loc; txt=optionIdent}, [{
        ptyp_desc = Ptyp_var (safeTypeFromValue label);
        ptyp_loc = loc;
        ptyp_attributes = [];
      }]);
    }
#endif
    (* ~foo: int=1 *)
    | (label, Some type_, Some _) ->
#if OCAML_VERSION >= (4,3,0)
    type_
#else
    {
      type_ with
      ptyp_desc = Ptyp_constr ({loc; txt=optionIdent}, [type_]);
    }
#endif
    (* ~foo: option(int)=? *)
    | (label, Some ({ptyp_desc = Ptyp_constr ({txt=(Lident "option")}, [type_])}), _)
    | (label, Some ({ptyp_desc = Ptyp_constr ({txt=(Ldot (Lident "*predef*", "option"))}, [type_])}), _)
    (* ~foo: int=? - note this isnt valid. but we want to get a type error *)
    | (label, Some type_, _) when isOptional label ->
#if OCAML_VERSION >= (4,3,0)
    type_
#else
    {
      type_ with
      ptyp_desc = Ptyp_constr ({loc; txt=optionIdent}, [type_]);
    }
#endif
    (* ~foo=? *)
    | (label, None, _) when isOptional label ->
#if OCAML_VERSION >= (4,3,0)
    {
      ptyp_desc = Ptyp_var (safeTypeFromValue label);
      ptyp_loc = loc;
      ptyp_attributes = [];
    }
#else
    {
      ptyp_loc = loc;
      ptyp_attributes = [];
      ptyp_desc = Ptyp_constr ({loc; txt=optionIdent}, [{
        ptyp_desc = Ptyp_var (safeTypeFromValue label);
        ptyp_loc = loc;
        ptyp_attributes = [];
      }]);
    }
#endif
    (* ~foo *)
    | (label, None, _) ->
    {
      ptyp_desc = Ptyp_var (safeTypeFromValue label);
      ptyp_loc = loc;
      ptyp_attributes = [];
    }
    | (label, Some type_, _) ->
    type_
    )
    args)
  | [] -> args

(* Build an AST node for the [@bs.obj] representing props for a component *)
let makePropsValue fnName loc namedArgListWithKeyAndRef propsType =
  let propsName = fnName ^ "Props" in {
  pval_name = {txt = propsName; loc};
  pval_type =
      recursivelyMakeNamedArgsForExternal
        namedArgListWithKeyAndRef
        (Typ.arrow
          nolabel
          {
            ptyp_desc = Ptyp_constr ({txt= Lident("unit"); loc}, []);
            ptyp_loc = loc;
            ptyp_attributes = [];
          }
          propsType
        );
  pval_prim = [""];
  pval_attributes = [({txt = "bs.obj"; loc = loc}, PStr [])];
  pval_loc = loc;
}

(* Build an AST node representing an `external` with the definition of the [@bs.obj] *)
let makePropsExternal fnName loc namedArgListWithKeyAndRef propsType =
  {
    pstr_loc = loc;
    pstr_desc = Pstr_primitive (makePropsValue fnName loc namedArgListWithKeyAndRef propsType)
  }

(* Build an AST node for the signature of the `external` definition *)
let makePropsExternalSig fnName loc namedArgListWithKeyAndRef propsType =
  {
    psig_loc = loc;
    psig_desc = Psig_value (makePropsValue fnName loc namedArgListWithKeyAndRef propsType)
  }

(* Build an AST node for the props name when converted to a Js.t inside the function signature  *)
let makePropsName ~loc name =
  {
    ppat_desc = Ppat_var {txt = name; loc};
    ppat_loc = loc;
    ppat_attributes = [];
  }

#if OCAML_VERSION >= (4,3,0)
let makeObjectField loc (str, attrs, type_) =
  Otag ({ loc; txt = str }, attrs, type_)
#endif

(* Build an AST node representing a "closed" Js.t object representing a component's props *)
let makePropsType ~loc namedTypeList =
  Typ.mk ~loc (
    Ptyp_constr({txt= Ldot (Lident("Js"), "t"); loc}, [{
#if OCAML_VERSION >= (4,3,0)
        ptyp_desc = Ptyp_object(
          List.map (makeObjectField loc) namedTypeList,
          Closed
        );
#else
        ptyp_desc = Ptyp_object(namedTypeList, Closed);
#endif
        ptyp_loc = loc;
        ptyp_attributes = [];
      }])
    )

(* Builds an AST node for the entire `external` definition of props *)
let makeExternalDecl fnName loc namedArgListWithKeyAndRef namedTypeList =
  makePropsExternal
    fnName
    loc
    (List.map pluckLabelDefaultLocType namedArgListWithKeyAndRef)
    (makePropsType ~loc namedTypeList)

(* TODO: some line number might still be wrong *)
let jsxMapper () =

  let jsxVersion = ref None in

  let transformUppercaseCall3 modulePath mapper loc attrs _ callArguments =
    let (children, argsWithLabels) = extractChildren ~loc ~removeLastPositionUnit:true callArguments in
    let argsForMake = argsWithLabels in
    let childrenExpr = transformChildrenIfListUpper ~loc ~mapper children in
    let recursivelyTransformedArgsForMake = argsForMake |> List.map (fun (label, expression) -> (label, mapper.expr mapper expression)) in
    let childrenArg = ref None in
    let args = recursivelyTransformedArgsForMake
      @ (match childrenExpr with
        | Exact children -> [(labelled "children", children)]
        | ListLiteral ({ pexp_desc = Pexp_array list }) when list = [] -> []
        | ListLiteral expression ->
        (* this is a hack to support react components that introspect into their children *)
        (childrenArg := Some expression;
        [(labelled "children", Exp.ident ~loc {loc; txt = Ldot (Lident "React", "null")})]))
      @ [(nolabel, Exp.construct ~loc {loc; txt = Lident "()"} None)] in
    let isCap str = let first = String.sub str 0 1 in
#if OCAML_VERSION >= (4,3,0)
    let capped = String.uppercase_ascii first in first = capped in
#else
    let capped = String.uppercase first in first = capped in
#endif
    let ident = match modulePath with
    | Lident _ -> Ldot (modulePath, "make")
    | (Ldot (_modulePath, value) as fullPath) when isCap value -> Ldot (fullPath, "make")
    | modulePath -> modulePath in
    let propsIdent = match ident with
    | Lident path -> Lident (path ^ "Props")
    | Ldot(ident, path) -> Ldot (ident, path ^ "Props")
    | _ -> raise (Invalid_argument "JSX name can't be the result of function applications") in
    let props =
    Exp.apply ~attrs ~loc (Exp.ident ~loc {loc; txt = propsIdent}) args in
    (* handle key, ref, children *)
      (* React.createElement(Component.make, props, ...children) *)
    match (!childrenArg) with
    | None ->
      (Exp.apply
        ~loc
        ~attrs
        (Exp.ident ~loc {loc; txt = Ldot (Lident "React", "createElement")})
        ([
          (nolabel, Exp.ident ~loc {txt = ident; loc});
          (nolabel, props)
        ]))
     | Some children ->
       (Exp.apply
         ~loc
         ~attrs
         (Exp.ident ~loc {loc; txt = Ldot (Lident "React", "createElementVariadic")})
         ([
           (nolabel, Exp.ident ~loc {txt = ident; loc});
           (nolabel, props);
           (nolabel, children)
         ]))
     in

    let transformLowercaseCall3 mapper loc attrs callArguments id =
      let (children, nonChildrenProps) = extractChildren ~loc callArguments in
      let componentNameExpr = constantString ~loc id in
      let childrenExpr = transformChildrenIfList ~loc ~mapper children in
      let createElementCall = match children with
        (* [@JSX] div(~children=[a]), coming from <div> a </div> *)
        | {
            pexp_desc =
             Pexp_construct ({txt = Lident "::"}, Some {pexp_desc = Pexp_tuple _ })
             | Pexp_construct ({txt = Lident "[]"}, None)
          } -> "createDOMElementVariadic"
        (* [@JSX] div(~children= value), coming from <div> ...(value) </div> *)
        | _ -> raise (Invalid_argument "A spread as a DOM element's \
          children don't make sense written together. You can simply remove the spread.")
      in
      let args = match nonChildrenProps with
        | [_justTheUnitArgumentAtEnd] ->
          [
            (* "div" *)
            (nolabel, componentNameExpr);
            (* [|moreCreateElementCallsHere|] *)
            (nolabel, childrenExpr)
          ]
        | nonEmptyProps ->
          let propsCall =
            Exp.apply
              ~loc
              (Exp.ident ~loc {loc; txt = Ldot (Lident "ReactDOMRe", "domProps")})
              (nonEmptyProps |> List.map (fun (label, expression) -> (label, mapper.expr mapper expression)))
          in
          [
            (* "div" *)
            (nolabel, componentNameExpr);
            (* ReactDOMRe.props(~className=blabla, ~foo=bar, ()) *)
            (labelled "props", propsCall);
            (* [|moreCreateElementCallsHere|] *)
            (nolabel, childrenExpr)
          ] in
      Exp.apply
        ~loc
        (* throw away the [@JSX] attribute and keep the others, if any *)
        ~attrs
        (* ReactDOMRe.createElement *)
        (Exp.ident ~loc {loc; txt = Ldot (Lident "ReactDOMRe", createElementCall)})
        args
    in

  let transformUppercaseCall modulePath mapper loc attrs _ callArguments =
    let (children, argsWithLabels) = extractChildren ~loc ~removeLastPositionUnit:true callArguments in
    let (argsKeyRef, argsForMake) = List.partition argIsKeyRef argsWithLabels in
    let childrenExpr = transformChildrenIfList ~loc ~mapper children in
    let recursivelyTransformedArgsForMake = argsForMake |> List.map (fun (label, expression) -> (label, mapper.expr mapper expression)) in
    let args = recursivelyTransformedArgsForMake @ [ (nolabel, childrenExpr) ] in
    let wrapWithReasonReactElement e = (* ReasonReact.element(~key, ~ref, ...) *)
      Exp.apply
        ~loc
        (Exp.ident ~loc {loc; txt = Ldot (Lident "ReasonReact", "element")})
        (argsKeyRef @ [(nolabel, e)]) in
    Exp.apply
      ~loc
      ~attrs
      (* Foo.make *)
      (Exp.ident ~loc {loc; txt = Ldot (modulePath, "make")})
      args
    |> wrapWithReasonReactElement in

  let transformLowercaseCall mapper loc attrs callArguments id =
    let (children, nonChildrenProps) = extractChildren ~loc callArguments in
    let componentNameExpr = constantString ~loc id in
    let childrenExpr = transformChildrenIfList ~loc ~mapper children in
    let createElementCall = match children with
      (* [@JSX] div(~children=[a]), coming from <div> a </div> *)
      | {
          pexp_desc =
           Pexp_construct ({txt = Lident "::"}, Some {pexp_desc = Pexp_tuple _ })
           | Pexp_construct ({txt = Lident "[]"}, None)
        } -> "createElement"
      (* [@JSX] div(~children=[|a|]), coming from <div> ...[|a|] </div> *)
      | { pexp_desc = (Pexp_array _) } ->
        raise (Invalid_argument "A spread + an array literal as a DOM element's \
          children would cancel each other out, and thus don't make sense written \
          together. You can simply remove the spread and the array literal.")
      (* [@JSX] div(~children= <div />), coming from <div> ...<div/> </div> *)
      | {
          pexp_attributes
        } when pexp_attributes |> List.exists (fun (attribute, _) -> attribute.txt = "JSX") ->
        raise (Invalid_argument "A spread + a JSX literal as a DOM element's \
          children don't make sense written together. You can simply remove the spread.")
      | _ -> "createElementVariadic"
    in
    let args = match nonChildrenProps with
      | [_justTheUnitArgumentAtEnd] ->
        [
          (* "div" *)
          (nolabel, componentNameExpr);
          (* [|moreCreateElementCallsHere|] *)
          (nolabel, childrenExpr)
        ]
      | nonEmptyProps ->
        let propsCall =
          Exp.apply
            ~loc
            (Exp.ident ~loc {loc; txt = Ldot (Lident "ReactDOMRe", "props")})
            (nonEmptyProps |> List.map (fun (label, expression) -> (label, mapper.expr mapper expression)))
        in
        [
          (* "div" *)
          (nolabel, componentNameExpr);
          (* ReactDOMRe.props(~className=blabla, ~foo=bar, ()) *)
          (labelled "props", propsCall);
          (* [|moreCreateElementCallsHere|] *)
          (nolabel, childrenExpr)
        ] in
    Exp.apply
      ~loc
      (* throw away the [@JSX] attribute and keep the others, if any *)
      ~attrs
      (* ReactDOMRe.createElement *)
      (Exp.ident ~loc {loc; txt = Ldot (Lident "ReactDOMRe", createElementCall)})
      args
  in

  let rec recursivelyTransformNamedArgsForMake mapper expr list =
    let expr = mapper.expr mapper expr in
    match expr.pexp_desc with
    (* TODO: make this show up with a loc. *)
#if OCAML_VERSION >= (4,3,0)
    | Pexp_fun (Labelled "key", _, _, _)
    | Pexp_fun (Optional "key", _, _, _) -> raise (Invalid_argument "Key cannot be accessed inside of a component. Don't worry - you can always key a component from its parent!")
    | Pexp_fun (Labelled "ref", _, _, _)
    | Pexp_fun (Optional "ref", _, _, _) -> raise (Invalid_argument "Ref cannot be passed as a normal prop. Please use `forwardRef` API instead.")
#else
    | Pexp_fun ("key", _, _, _)
    | Pexp_fun ("?key", _, _, _) -> raise (Invalid_argument "Key cannot be accessed inside of a component. Don't worry - you can always key a component from its parent!")
    | Pexp_fun ("ref", _, _, _)
    | Pexp_fun ("?ref", _, _, _) -> raise (Invalid_argument "Ref cannot be passed as a normal prop. Please use `forwardRef` API instead.")
#endif
    | Pexp_fun (arg, default, pattern, expression) when isOptional arg || isLabelled arg ->
      let alias = (match pattern with
      | {ppat_desc = Ppat_alias (_, {txt}) | Ppat_var {txt}} -> txt
      | {ppat_desc = Ppat_any} -> "_"
      | _ -> getLabel arg) in
      let type_ = (match pattern with
      | {ppat_desc = Ppat_constraint (_, type_)} -> Some type_
      | _ -> None) in

      recursivelyTransformNamedArgsForMake mapper expression ((arg, default, pattern, alias, pattern.ppat_loc, type_) :: list)
#if OCAML_VERSION >= (4,3,0)
    | Pexp_fun (Nolabel, _, { ppat_desc = (Ppat_construct ({txt = Lident "()"}, _) | Ppat_any)}, expression) ->
        (expression.pexp_desc, list, None)
    | Pexp_fun (Nolabel, _, { ppat_desc = Ppat_var ({txt})}, expression) ->
        (expression.pexp_desc, list, Some txt)
#else
    | Pexp_fun ("", _, { ppat_desc = (Ppat_construct ({txt = Lident "()"}, _) | Ppat_any)}, expression) ->
        (expression.pexp_desc, list, None)
    | Pexp_fun ("", _, { ppat_desc = Ppat_var ({txt})}, expression) ->
        (expression.pexp_desc, list, Some txt)
#endif
    | innerExpression -> (innerExpression, list, None)
  in


  let argToType types (name, default, _noLabelName, _alias, loc, type_) = match (type_, name, default) with
    | (Some ({ptyp_desc = Ptyp_constr ({txt=(Lident "option")}, [type_])}), name, _) when isOptional name ->
      (getLabel name, [], {
        type_ with
        ptyp_desc = Ptyp_constr ({loc=type_.ptyp_loc; txt=optionIdent}, [type_]);
      }) :: types
    | (Some type_, name, Some _default) ->
      (getLabel name, [], {
      ptyp_desc = Ptyp_constr ({loc; txt=optionIdent}, [type_]);
      ptyp_loc = loc;
      ptyp_attributes = [];
      }) :: types
    | (Some type_, name, _) ->
      (getLabel name, [], type_) :: types
    | (None, name, _) when isOptional name ->
      (getLabel name, [], {
        ptyp_desc = Ptyp_constr ({loc; txt=optionIdent}, [{
          ptyp_desc = Ptyp_var (safeTypeFromValue name);
          ptyp_loc = loc;
          ptyp_attributes = [];
        }]);
        ptyp_loc = loc;
        ptyp_attributes = [];
        }) :: types
    | (None, name, _) when isLabelled name ->
      (getLabel name, [], {
        ptyp_desc = Ptyp_var (safeTypeFromValue name);
        ptyp_loc = loc;
        ptyp_attributes = [];
        }) :: types
    | _ -> types
  in

  let argToConcreteType types (name, loc, type_) = match name with
    | name when isLabelled name ->
    (getLabel name, [], type_) :: types
    | name when isOptional name ->
#if OCAML_VERSION >= (4,3,0)
  (getLabel name, [], Typ.constr ~loc {loc; txt=optionIdent} [type_]) :: types
#else
  (getLabel name, [], type_) :: types
#endif
    | _ -> types
  in

  let nestedModules = ref([]) in
  let transformComponentDefinition mapper structure returnStructures = match structure with
  (* external *)
  | ({
      pstr_loc;
      pstr_desc = Pstr_primitive ({
        pval_name = { txt = fnName };
        pval_attributes;
        pval_type;
      } as value_description)
    } as pstr) ->
    (match List.filter hasAttr pval_attributes with
    | [] -> structure :: returnStructures
    | [_] ->
    let rec getPropTypes types ({ptyp_loc; ptyp_desc} as fullType) =
      (match ptyp_desc with
      | Ptyp_arrow (name, type_, ({ptyp_desc = Ptyp_arrow _} as rest)) when isLabelled name || isOptional name ->
        getPropTypes ((name, ptyp_loc, type_)::types) rest
#if OCAML_VERSION >= (4,3,0)
      | Ptyp_arrow (Nolabel, _type, rest) ->
#else
      | Ptyp_arrow ("", _type, rest) ->
#endif
        getPropTypes types rest
      | Ptyp_arrow (name, type_, returnValue) when isLabelled name || isOptional name ->
        (returnValue, (name, returnValue.ptyp_loc, type_)::types)
      | _ -> (fullType, types))
    in
    let (innerType, propTypes) = getPropTypes [] pval_type in
    let namedTypeList = List.fold_left argToConcreteType [] propTypes in
    let pluckLabelAndLoc (label, loc, type_) = (label, None (* default *), loc, Some type_) in
    let retPropsType = makePropsType ~loc:pstr_loc namedTypeList in
    let externalPropsDecl = makePropsExternal fnName pstr_loc ((
      optional "key",
      None,
      pstr_loc,
      Some(keyType pstr_loc)
    ) :: List.map pluckLabelAndLoc propTypes) retPropsType in
    (* can't be an arrow because it will defensively uncurry *)
    let newExternalType = Ptyp_constr (
      {loc = pstr_loc; txt = Ldot ((Lident "React"), "componentLike")},
      [retPropsType; innerType]
    ) in
    let newStructure = {
      pstr with pstr_desc = Pstr_primitive {
        value_description with pval_type = {
          pval_type with ptyp_desc = newExternalType;
        };
        pval_attributes = List.filter otherAttrsPure pval_attributes;
      }
    } in
    externalPropsDecl :: newStructure :: returnStructures
    | _ -> raise (Invalid_argument "Only one react.component call can exist on a component at one time"))
  (* let component = ... *)
  | {
      pstr_loc;
      pstr_desc = Pstr_value (
        recFlag,
        valueBindings
      )
    } ->
      let mapBinding binding = if (hasAttrOnBinding binding) then
        let fnName = getFnName binding in
        let fileName = filenameFromLoc pstr_loc in
        let fullModuleName = makeModuleName fileName !nestedModules fnName in
        let emptyLoc = Location.in_file fileName in
        let modifiedBinding binding =
          let expression = binding.pvb_expr in
          let wrapExpressionWithBinding expressionFn expression = {(filterAttrOnBinding binding) with pvb_expr = expressionFn expression} in
          (* TODO: there is a long-tail of unsupported features inside of blocks - Pexp_letmodule , Pexp_letexception , Pexp_ifthenelse *)
          let rec spelunkForFunExpression expression = (match expression with
          (* let make = (~prop) => ... *)
          | {
            pexp_desc = Pexp_fun _
          } -> ((fun expressionDesc -> {expression with pexp_desc = expressionDesc}), expression)
          (* let make = {let foo = bar in (~prop) => ...} *)
          | {
              pexp_desc = Pexp_let (recursive, vbs, returnExpression)
            } ->
            (* here's where we spelunk! *)
            let (wrapExpression, realReturnExpression) = spelunkForFunExpression returnExpression in
            ((fun expressionDesc -> {expression with pexp_desc = Pexp_let (recursive, vbs, wrapExpression expressionDesc)}), realReturnExpression)
          (* let make = React.forwardRef((~prop) => ...) *)
#if OCAML_VERSION >= (4,3,0)
          | { pexp_desc = Pexp_apply (wrapperExpression, [(Nolabel, innerFunctionExpression)]) } ->
#else
          | { pexp_desc = Pexp_apply (wrapperExpression, [("", innerFunctionExpression)]) } ->
#endif
            let (wrapExpression, realReturnExpression) = spelunkForFunExpression innerFunctionExpression in
            ((fun expressionDesc -> {
              expression with pexp_desc =
                Pexp_apply (wrapperExpression, [(nolabel, wrapExpression expressionDesc)])
              }),
              realReturnExpression
            )
          | {
              pexp_desc = Pexp_sequence (wrapperExpression, innerFunctionExpression)
            } ->
            let (wrapExpression, realReturnExpression) = spelunkForFunExpression innerFunctionExpression in
            ((fun expressionDesc -> {
              expression with pexp_desc =
                Pexp_sequence (wrapperExpression, wrapExpression expressionDesc)
              }),
              realReturnExpression
            )
          | _ -> raise (Invalid_argument "react.component calls can only be on function definitions or component wrappers (forwardRef, memo).")
          ) in
          let (wrapExpression, expression) = spelunkForFunExpression expression in
          (wrapExpressionWithBinding wrapExpression, expression)
        in
        let (bindingWrapper, expression) = modifiedBinding binding in
        let reactComponentAttribute = try
          Some(List.find hasAttr binding.pvb_attributes)
        with | Not_found -> None in
        let (attr_loc, payload) = match reactComponentAttribute with
        | Some (loc, payload) -> (loc.loc, Some payload)
        | None -> (emptyLoc, None) in
        let props = getPropsAttr payload in
        (* do stuff here! *)
        let (innerFunctionExpression, namedArgList, forwardRef) = recursivelyTransformNamedArgsForMake mapper expression [] in
        let namedArgListWithKeyAndRef = (optional("key"), None, Pat.var {txt = "key"; loc = emptyLoc}, "key", emptyLoc, Some(keyType emptyLoc)) :: namedArgList in
        let namedArgListWithKeyAndRef = match forwardRef with
        | Some(_) ->  (optional("ref"), None, Pat.var {txt = "key"; loc = emptyLoc}, "ref", emptyLoc, None) :: namedArgListWithKeyAndRef
        | None -> namedArgListWithKeyAndRef
        in
        let namedTypeList = List.fold_left argToType [] namedArgList in
        let externalDecl = makeExternalDecl fnName attr_loc namedArgListWithKeyAndRef namedTypeList in
        let makeLet innerExpression (label, default, pattern, _alias, loc, _type) =
          let labelString = (match label with | label when isOptional label || isLabelled label -> getLabel label | _ -> raise (Invalid_argument "This should never happen")) in
          let expression = (Exp.apply ~loc
            (Exp.ident ~loc {txt = (Lident "##"); loc })
            [
              (nolabel, Exp.ident ~loc {txt = (Lident props.propsName); loc });
              (nolabel, Exp.ident ~loc {
                txt = (Lident labelString);
                loc
              })
            ]
          ) in
          let expression = match (default) with
          | (Some default) -> Exp.match_ expression [
            Exp.case
              (Pat.construct {loc; txt=Lident "Some"} (Some (Pat.var ~loc {txt = labelString; loc})))
              (Exp.ident ~loc {txt = (Lident labelString); loc = { loc with Location.loc_ghost = true }});
            Exp.case
              (Pat.construct {loc; txt=Lident "None"} None)
              default
          ]
          | None -> expression in
          let letExpression = Vb.mk
            pattern
            expression in
          Exp.let_ ~loc Nonrecursive [letExpression] innerExpression in
        let innerExpression = List.fold_left makeLet (Exp.mk innerFunctionExpression) namedArgList in
        let innerExpressionWithRef = match (forwardRef) with
        | Some txt ->
          {innerExpression with pexp_desc = Pexp_fun (nolabel, None, {
            ppat_desc = Ppat_var { txt; loc = emptyLoc };
            ppat_loc = emptyLoc;
            ppat_attributes = [];
          }, innerExpression)}
        | None -> innerExpression
        in
        let fullExpression = (Pexp_fun (
          nolabel,
          None,
          {
            ppat_desc = Ppat_constraint (
              makePropsName ~loc:emptyLoc props.propsName,
              makePropsType ~loc:emptyLoc namedTypeList
            );
            ppat_loc = emptyLoc;
            ppat_attributes = [];
          },
          innerExpressionWithRef
        )) in
        let fullExpression = match (fullModuleName) with
        | ("") -> fullExpression
        | (txt) -> Pexp_let (
            Nonrecursive,
            [Vb.mk
              ~loc:emptyLoc
              (Pat.var ~loc:emptyLoc {loc = emptyLoc; txt})
              (Exp.mk ~loc:emptyLoc fullExpression)
            ],
            (Exp.ident ~loc:emptyLoc {loc = emptyLoc; txt = Lident txt})
          )
        in
        let newBinding = bindingWrapper fullExpression in
        (Some externalDecl, newBinding)
      else
        (None, binding)
      in
      let structuresAndBinding = List.map mapBinding valueBindings in
      let otherStructures (extern, binding) (externs, bindings) =
        let externs = match extern with
        | Some extern -> extern :: externs
        | None -> externs in
        (externs, binding :: bindings)
      in
      let (externs, bindings) = List.fold_right otherStructures structuresAndBinding ([], []) in
      externs @ {
        pstr_loc;
        pstr_desc = Pstr_value (
          recFlag,
          bindings
        )
      } :: returnStructures
    | structure -> structure :: returnStructures in

  let reactComponentTransform mapper structures =
  List.fold_right (transformComponentDefinition mapper) structures [] in

  let transformComponentSignature _mapper signature returnSignatures = match signature with
  | ({
      psig_loc;
      psig_desc = Psig_value ({
        pval_name = { txt = fnName };
        pval_attributes;
        pval_type;
      } as psig_desc)
    } as psig) ->
    (match List.filter hasAttr pval_attributes with
    | [] -> signature :: returnSignatures
    | [_] ->
    let rec getPropTypes types ({ptyp_loc; ptyp_desc} as fullType) =
      (match ptyp_desc with
      | Ptyp_arrow (name, type_, ({ptyp_desc = Ptyp_arrow _} as rest)) when isOptional name || isLabelled name ->
        getPropTypes ((name, ptyp_loc, type_)::types) rest
#if OCAML_VERSION >= (4,3,0)
      | Ptyp_arrow (Nolabel, _type, rest) ->
#else
      | Ptyp_arrow ("", _type, rest) ->
#endif
        getPropTypes types rest
      | Ptyp_arrow (name, type_, returnValue) when isOptional name || isLabelled name ->
        (returnValue, (name, returnValue.ptyp_loc, type_)::types)
      | _ -> (fullType, types))
    in
    let (innerType, propTypes) = getPropTypes [] pval_type in
    let namedTypeList = List.fold_left argToConcreteType [] propTypes in
    let pluckLabelAndLoc (label, loc, type_) = (label, None, loc, Some type_) in
    let retPropsType = makePropsType ~loc:psig_loc namedTypeList in
    let externalPropsDecl = makePropsExternalSig fnName psig_loc ((
      optional "key",
      None,
      psig_loc,
      Some(keyType psig_loc)
    ) :: List.map pluckLabelAndLoc propTypes) retPropsType in
        (* can't be an arrow because it will defensively uncurry *)
    let newExternalType = Ptyp_constr (
      {loc = psig_loc; txt = Ldot ((Lident "React"), "componentLike")},
      [retPropsType; innerType]
    ) in
    let newStructure = {
      psig with psig_desc = Psig_value {
        psig_desc with pval_type = {
          pval_type with ptyp_desc = newExternalType;
        };
        pval_attributes = List.filter otherAttrsPure pval_attributes;
      }
    } in
    externalPropsDecl :: newStructure :: returnSignatures
    | _ -> raise (Invalid_argument "Only one react.component call can exist on a component at one time"))
  | signature -> signature :: returnSignatures in

  let reactComponentSignatureTransform mapper signatures =
  List.fold_right (transformComponentSignature mapper) signatures [] in


  let transformJsxCall mapper callExpression callArguments attrs =
    (match callExpression.pexp_desc with
     | Pexp_ident caller ->
       (match caller with
        | {txt = Lident "createElement"} ->
          raise (Invalid_argument "JSX: `createElement` should be preceeded by a module name.")

        (* Foo.createElement(~prop1=foo, ~prop2=bar, ~children=[], ()) *)
        | {loc; txt = Ldot (modulePath, ("createElement" | "make"))} ->
          (match !jsxVersion with
#ifdef REACT_JS_JSX_V2
          | None
          | Some 2 -> transformUppercaseCall modulePath mapper loc attrs callExpression callArguments
#else
          | Some 2 -> transformUppercaseCall modulePath mapper loc attrs callExpression callArguments
          | None
#endif
          | Some 3 -> transformUppercaseCall3 modulePath mapper loc attrs callExpression callArguments
          | Some _ -> raise (Invalid_argument "JSX: the JSX version must be 2 or 3"))

        (* div(~prop1=foo, ~prop2=bar, ~children=[bla], ()) *)
        (* turn that into
          ReactDOMRe.createElement(~props=ReactDOMRe.props(~props1=foo, ~props2=bar, ()), [|bla|]) *)
        | {loc; txt = Lident id} ->
          (match !jsxVersion with
#ifdef REACT_JS_JSX_V2
          | None
          | Some 2 -> transformLowercaseCall mapper loc attrs callArguments id
#else
          | Some 2 -> transformLowercaseCall mapper loc attrs callArguments id
          | None
#endif
          | Some 3 -> transformLowercaseCall3 mapper loc attrs callArguments id
          | Some _ -> raise (Invalid_argument "JSX: the JSX version must be 2 or 3"))

        | {txt = Ldot (_, anythingNotCreateElementOrMake)} ->
          raise (
            Invalid_argument
              ("JSX: the JSX attribute should be attached to a `YourModuleName.createElement` or `YourModuleName.make` call. We saw `"
               ^ anythingNotCreateElementOrMake
               ^ "` instead"
              )
          )

        | {txt = Lapply _} ->
          (* don't think there's ever a case where this is reached *)
          raise (
            Invalid_argument "JSX: encountered a weird case while processing the code. Please report this!"
          )
       )
     | _ ->
       raise (
         Invalid_argument "JSX: `createElement` should be preceeded by a simple, direct module name."
       )
    ) in

  let signature =
    (fun mapper signature -> default_mapper.signature mapper @@ reactComponentSignatureTransform mapper signature) in

  let structure =
    (fun mapper structure -> match structure with
      (*
        match against [@bs.config {foo, jsx: ...}] at the file-level. This
        indicates which version of JSX we're using. This code stays here because
        we used to have 2 versions of JSX PPX (and likely will again in the
        future when JSX PPX changes). So the architecture for switching between
        JSX behavior stayed here. To create a new JSX ppx, copy paste this
        entire file and change the relevant parts.
        Description of architecture: in bucklescript's bsconfig.json, you can
        specify a project-wide JSX version. You can also specify a file-level
        JSX version. This degree of freedom allows a person to convert a project
        one file at time onto the new JSX, when it was released. It also enabled
        a project to depend on a third-party which is still using an old version
        of JSX
      *)
      | ({
          pstr_desc = Pstr_attribute (
            {txt = "ocaml.ppx.context"} ,
            _
          )
        }::
        {
          pstr_loc;
          pstr_desc = Pstr_attribute (
            ({txt = "bs.config"} as bsConfigLabel),
            PStr [{pstr_desc = Pstr_eval ({pexp_desc = Pexp_record (recordFields, b)} as innerConfigRecord, a)} as configRecord]
          )
        }
        ::restOfStructure ) | ({
          pstr_loc;
          pstr_desc = Pstr_attribute (
            ({txt = "bs.config"} as bsConfigLabel),
            PStr [{pstr_desc = Pstr_eval ({pexp_desc = Pexp_record (recordFields, b)} as innerConfigRecord, a)} as configRecord]
          )
        }::restOfStructure) -> begin
          let (jsxField, recordFieldsWithoutJsx) = recordFields |> List.partition (fun ({txt}, _) -> txt = Lident "jsx") in
          match (jsxField, recordFieldsWithoutJsx) with
          (* no file-level jsx config found *)
          | ([], _) -> default_mapper.structure mapper structure
          (* {jsx: 2} *)
#if OCAML_VERSION >= (4,3,0)
          | ((_, {pexp_desc = Pexp_constant (Pconst_integer (version, None))})::rest, recordFieldsWithoutJsx) -> begin
#else
          | ((_, {pexp_desc = Pexp_constant (Const_int version)})::_rest, recordFieldsWithoutJsx) -> begin
#endif
              (match version with
#if OCAML_VERSION >= (4,3,0)
              | "2" -> jsxVersion := Some 2
              | "3" -> jsxVersion := Some 3
#else
              | 2 -> jsxVersion := Some 2
              | 3 -> jsxVersion := Some 3
#endif
              | _ -> raise (Invalid_argument "JSX: the file-level bs.config's jsx version must be 2 or 3"));
              match recordFieldsWithoutJsx with
              (* record empty now, remove the whole bs.config attribute *)
              | [] -> default_mapper.structure mapper @@ reactComponentTransform mapper restOfStructure
              | fields -> default_mapper.structure mapper ({
                pstr_loc;
                pstr_desc = Pstr_attribute (
                  bsConfigLabel,
                  PStr [{configRecord with pstr_desc = Pstr_eval ({innerConfigRecord with pexp_desc = Pexp_record (fields, b)}, a)}]
                )
              }::(reactComponentTransform mapper restOfStructure))
            end
        | _ -> raise (Invalid_argument "JSX: the file-level bs.config's {jsx: ...} config accepts only a version number")
      end
      | structures -> begin
        default_mapper.structure mapper @@ reactComponentTransform mapper structures
      end
    ) in

  let expr =
    (fun mapper expression -> match expression with
       (* Does the function application have the @JSX attribute? *)
       | {
           pexp_desc = Pexp_apply (callExpression, callArguments);
           pexp_attributes
         } ->
         let (jsxAttribute, nonJSXAttributes) = List.partition (fun (attribute, _) -> attribute.txt = "JSX") pexp_attributes in
         (match (jsxAttribute, nonJSXAttributes) with
         (* no JSX attribute *)
         | ([], _) -> default_mapper.expr mapper expression
         | (_, nonJSXAttributes) -> transformJsxCall mapper callExpression callArguments nonJSXAttributes)

       (* is it a list with jsx attribute? Reason <>foo</> desugars to [@JSX][foo]*)
       | {
           pexp_desc =
            Pexp_construct ({txt = Lident "::"; loc}, Some {pexp_desc = Pexp_tuple _})
            | Pexp_construct ({txt = Lident "[]"; loc}, None);
           pexp_attributes
         } as listItems ->
          let (jsxAttribute, nonJSXAttributes) = List.partition (fun (attribute, _) -> attribute.txt = "JSX") pexp_attributes in
          (match (jsxAttribute, nonJSXAttributes) with
          (* no JSX attribute *)
          | ([], _) -> default_mapper.expr mapper expression
          | (_, nonJSXAttributes) ->
            let fragment = Exp.ident ~loc {loc; txt = Ldot (Lident "ReasonReact", "fragment")} in
            let childrenExpr = transformChildrenIfList ~loc ~mapper listItems in
            let args = [
              (* "div" *)
              (nolabel, fragment);
              (* [|moreCreateElementCallsHere|] *)
              (nolabel, childrenExpr)
            ] in
            Exp.apply
              ~loc
              (* throw away the [@JSX] attribute and keep the others, if any *)
              ~attrs:nonJSXAttributes
              (* ReactDOMRe.createElement *)
              (Exp.ident ~loc {loc; txt = Ldot (Lident "ReactDOMRe", "createElement")})
              args
         )
       (* Delegate to the default mapper, a deep identity traversal *)
       | e -> default_mapper.expr mapper e) in

  let module_binding =
    (fun mapper module_binding ->
      let _ = nestedModules := module_binding.pmb_name.txt :: !nestedModules in
      let mapped = default_mapper.module_binding mapper module_binding in
      let _ = nestedModules := List.tl !nestedModules in
      mapped
    ) in

  { default_mapper with structure; expr; signature; module_binding; }

let rewrite_implementation (code: Parsetree.structure) : Parsetree.structure =
  let mapper = jsxMapper () in
  mapper.structure mapper code
let rewrite_signature (code : Parsetree.signature) : Parsetree.signature =
  let mapper = jsxMapper () in
  mapper.signature mapper code

#ifdef BINARY
let () = Ast_mapper.register "JSX" (fun _argv -> jsxMapper ())
#endif
