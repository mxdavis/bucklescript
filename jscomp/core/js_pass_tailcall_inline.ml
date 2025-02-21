(* Copyright (C) 2015-2016 Bloomberg Finance L.P.
 * 
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * In addition to the permissions granted to you by the LGPL, you may combine
 * or link a "work that uses the Library" with a publicly distributed version
 * of this file to produce a combined library or application, then distribute
 * that combined work under the terms of your choosing, with no requirement
 * to comply with the obligations normally placed on you by section 4 of the
 * LGPL version 3 (or the corresponding section of a later version of the LGPL
 * should you choose to use a later version).
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 * 
 * You should have received a copy of the GNU Lesser General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA 02111-1307, USA. *)






(* When we inline a function call, if we don't do a beta-reduction immediately, there is 
   a chance that it is ignored, (we can not assume that each pass is robust enough)

   After we do inlining, it makes sense to do another constant folding and propogation 
 *)

(* Check: shall we inline functions with while loop? if it is used only once, 
   it makes sense to inline it
*)

module S = Js_stmt_make
module E = Js_exp_make


(** Update ident info use cases, it is a non pure function, 
    it will annotate [program] with some meta data
    TODO: Ident Hash could be improved, 
    since in this case it can not be global?  

*)
let count_collects () = 
  object (self)
    inherit Js_fold.fold as super
    (* collect used status*)
    val stats : int ref Hash_ident.t = Hash_ident.create 83
    (* collect all def sites *)
    val defined_idents : J.variable_declaration Hash_ident.t = Hash_ident.create 83

    val mutable my_export_set  : Set_ident.t = Set_ident.empty


    method add_use id = 
      match Hash_ident.find_opt stats id with
      | None -> Hash_ident.add stats id (ref 1)
      | Some v -> incr v 
    method! program x = 
      my_export_set <- x.export_set ; 

      super#program x
    method! variable_declaration 
        ({ident; value ; property  ; ident_info }  as v)
      =  
      Hash_ident.add defined_idents ident v; 
      match value with 
      | None -> 
        self
      | Some x
        -> self#expression x 
    method! ident id = self#add_use id; self
    method get_stats = 
      Hash_ident.iter defined_idents (fun ident v  -> 
          if Set_ident.mem my_export_set ident then 
            Js_op_util.update_used_stats v.ident_info Exported
          else 
            let pure = 
              match v.value  with 
              | None -> false  (* can not happen *)
              | Some x -> Js_analyzer.no_side_effect_expression x in
            match Hash_ident.find_opt stats ident with 
            | None -> 
              Js_op_util.update_used_stats v.ident_info 
                (if pure then Dead_pure else Dead_non_pure)
            | Some num -> 
              if !num = 1 then 
                Js_op_util.update_used_stats v.ident_info 
                  (if pure then Once_pure else Used) 
        ) ; defined_idents
  end


let get_stats (program : J.program) : J.variable_declaration Hash_ident.t
  =  ((count_collects ()) #program program) #get_stats


(* 1. recursive value ? let rec x = 1 :: x
    non-terminating
    2. duplicative identifiers ..
    remove it at the same time is a bit unsafe,
    since we have to guarantee that the one use
    case is substituted
    we already have this? in [defined_idents]
*)

(** There is a side effect when traversing dead code, since 
    we assume that substitue a node would mark a node as dead node,

    so if we traverse a dead node, this would get a wrong result.
    it does happen in such scenario
    {[
      let generic_basename is_dir_sep current_dir_name name =
        let rec find_end n =
          if n < 0 then String.sub name 0 1
          else if is_dir_sep name n then find_end (n - 1)
          else find_beg n (n + 1)
        and find_beg n p =
          if n < 0 then String.sub name 0 p
          else if is_dir_sep name n then String.sub name (n + 1) (p - n - 1)
          else find_beg (n - 1) p
        in
        if name = ""
        then current_dir_name
        else find_end (String.length name - 1)
    ]}
    [find_beg] can potentially be expanded in [find_end] and in [find_end]'s expansion, 
    if the order is not correct, or even worse, only the wrong one [find_beg] in [find_end] get expanded 
    (when we forget to recursive apply), then some code non-dead [find_beg] will be marked as dead, 
    while it is still called 
*)
let subst (export_set : Set_ident.t) stats  = 
  object (self)
    inherit Js_map.map as super
    method! statement st = 
      match st.statement_desc with 
      | Variable 
          {value = _ ;
           ident_info = {used_stats = Dead_pure}
          } 

        ->
        S.block []
      | Variable { ident_info = {used_stats = Dead_non_pure} ;
                   value = Some v  ; _ }        
        -> S.exp v
      | _ -> super#statement st 
    method! variable_declaration 
        ({ident; value = _ ; property = _ ; ident_info = _}  as v)
      =  
      (* TODO: replacement is a bit shaky, the problem is the lambda we stored is
         not consistent after we did some subsititution, and the dead code removal
         does rely on this (otherwise, when you do beta-reduction you have to regenerate names)
      *)
      let v = super # variable_declaration v in
      Hash_ident.add stats ident v; (* see #278 before changes *)
      v
    method! block bs = 
      match bs with
      | ({statement_desc = 
            Variable ({value =
                         Some ({expression_desc = Fun _; _ } as v )
                      } as vd) ; comment = _} as st) :: rest  -> 
        let is_export = Set_ident.mem export_set vd.ident in
        if is_export then 
          self#statement st :: self#block rest 
        else 
          begin 
            match Hash_ident.find_opt stats vd.ident with 
            (* TODO: could be improved as [mem] *)
            | None -> 
              if Js_analyzer.no_side_effect_expression v 
              then S.exp v  :: self#block rest 
              else self#block rest 

            | Some _ -> self#statement st  :: self#block rest 
          end

      | {statement_desc = 
           Return {return_value = 
                     {expression_desc = 
                        Call({expression_desc = Var (Id id)},args,_info)}} }
        as st 
        :: rest 
        -> 
        begin match Hash_ident.find_opt stats id with 

          | Some ({ value = 
                      Some {expression_desc = Fun (false, params, block, _env) ; comment = _}; 
                    (*TODO: don't inline method tail call yet, 
                      [this] semantics are weird 
                    *)              
                    property = (Alias | StrictOpt | Strict);
                    ident_info = {used_stats = Once_pure };
                    ident = _
                  } as v)
            when Ext_list.same_length params args 
            -> 
            (* Ext_log.dwarn  __LOC__ "%s is dead \n %s " id.name  *)
            (*   (Js_dump.string_of_block [st]); *)
            Js_op_util.update_used_stats v.ident_info Dead_pure;
            let block  = 
              Ext_list.fold_right2 
                params args  ( self#block block) (* see #278 before changes*)
                (fun param arg acc ->  
                   S.define_variable ~kind:Variable param arg :: acc)                                                
            in
            (* Mark a function as dead means it will never be scanned, 
               here we inline the function
            *)
            Ext_list.append block (self#block rest)
          | (None | Some _) ->
            self#statement st :: self#block rest
        end
      | x :: xs 
        ->
        self#statement x :: self#block xs
      | [] 
        -> 
        []

  end


let tailcall_inline (program : J.program) = 
  let stats = get_stats program in
  let export_set = program.export_set in
  (subst export_set stats )#program program

    
