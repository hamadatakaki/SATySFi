open Types
open Display

exception UndefinedVariable    of Range.t * var_name
exception UndefinedConstructor of Range.t * var_name
exception InclusionError       of Typeenv.t * mono_type * mono_type
exception ContradictionError   of Typeenv.t * mono_type * mono_type
exception InternalInclusionError
exception InternalContradictionError


let print_for_debug_typecheck msg =
(*
  print_endline msg ;
*)
  ()


let rec occurs (tvid : Tyvarid.t) ((_, tymain) : mono_type) =
  let iter = occurs tvid in
  let iter_list = List.fold_left (fun b ty -> b || iter ty) false in
  match tymain with
  | TypeVariable(tvref) ->
      begin
        match !tvref with
        | Link(tyl)   -> iter tyl
        | Bound(_)    -> false
        | Free(tvidx) ->
            if Tyvarid.eq tvidx tvid then true else
              let lev = Tyvarid.get_level tvid in
              let levx = Tyvarid.get_level tvidx in
              let () =
                if Tyvarid.less_than lev levx then
                  tvref := Free(Tyvarid.set_level tvidx lev)
                else
                  ()
              in
                false
      end
  | FuncType(tydom, tycod)         -> iter tydom || iter tycod
  | ProductType(tylist)            -> iter_list tylist
  | ListType(tysub)                -> iter tysub
  | RefType(tysub)                 -> iter tysub
  | VariantType(tylist, _)         -> iter_list tylist
  | SynonymType(tylist, _, tyreal) -> iter_list tylist || iter tyreal
  | RecordType(tyasc)              -> iter_list (Assoc.to_value_list tyasc)
    | ( UnitType
      | BoolType
      | IntType
      | StringType )               -> false


let rec unify_sub ((rng1, tymain1) as ty1 : mono_type) ((rng2, tymain2) as ty2 : mono_type) =
  let unify_list = List.iter (fun (t1, t2) -> unify_sub t1 t2) in
  let () = print_for_debug_typecheck ("| unify " ^ (string_of_mono_type_basic ty1) ^ " == " ^ (string_of_mono_type_basic ty2)) in (* for debug *)
    match (tymain1, tymain2) with

    | (SynonymType(_, _, tyreal1), _) -> unify_sub tyreal1 ty2
    | (_, SynonymType(_, _, tyreal2)) -> unify_sub ty1 tyreal2

    | ( (UnitType, UnitType)
      | (BoolType, BoolType)
      | (IntType, IntType)
      | (StringType, StringType) ) -> ()

    | (FuncType(tydom1, tycod1), FuncType(tydom2, tycod2)) ->
        begin
          unify_sub tydom1 tydom2 ;
          unify_sub tycod1 tycod2 ;
        end

    | (ProductType(tylist1), ProductType(tylist2)) ->
        begin
          try
            unify_list (List.combine tylist1 tylist2)
          with
          | Invalid_argument(_) -> (* -- not of the same length -- *)
              raise InternalContradictionError
        end

    | (RecordType(tyasc1), RecordType(tyasc2)) ->
        if not (Assoc.domain_same tyasc1 tyasc2) then
          raise InternalContradictionError
        else
          unify_list (Assoc.combine_value tyasc1 tyasc2)

    | (VariantType(tyarglist1, tyid1), VariantType(tyarglist2, tyid2))
        when tyid1 = tyid2 ->
          unify_list (List.combine tyarglist1 tyarglist2)

    | (ListType(tysub1), ListType(tysub2)) -> unify_sub tysub1 tysub2

    | (RefType(tysub1), RefType(tysub2))   -> unify_sub tysub1 tysub2

    | (TypeVariable({contents= Link(tyl1)}), _) -> unify_sub tyl1 (rng2, tymain2)

    | (_, TypeVariable({contents= Link(tyl2)})) -> unify_sub (rng1, tymain1) tyl2

    | ( (TypeVariable({contents= Bound(_)}), _)
      | (_, TypeVariable({contents= Bound(_)})) ) ->
          failwith ("unify_sub: bound type variable in " ^ (string_of_mono_type_basic ty1) ^ " (" ^ (Range.to_string rng1) ^ ")" ^ " or " ^ (string_of_mono_type_basic ty2) ^ " (" ^ (Range.to_string rng2) ^ ")")

    | (TypeVariable({contents= Free(tvid1)} as tvref1), TypeVariable({contents= Free(tvid2)} as tvref2)) ->
        if Tyvarid.eq tvid1 tvid2 then
          ()
        else
          let (tvid1q, tvid2q) =
            if Tyvarid.is_quantifiable tvid1 && Tyvarid.is_quantifiable tvid2 then
              (tvid1, tvid2)
            else
              (Tyvarid.set_quantifiability Unquantifiable tvid1, Tyvarid.set_quantifiability Unquantifiable tvid2)
          in
          let (tvid1l, tvid2l) =
            let lev1 = Tyvarid.get_level tvid1q in
            let lev2 = Tyvarid.get_level tvid2q in
              if Tyvarid.less_than lev1 lev2 then
                (tvid1q, Tyvarid.set_level tvid2q lev1)
              else if Tyvarid.less_than lev2 lev1 then
                (Tyvarid.set_level tvid1q lev2, tvid2q)
              else
                (tvid1q, tvid2q)
          in
          let () =
            begin
              tvref1 := Free(tvid1l) ;
              tvref2 := Free(tvid2l) ;
            end
          in
          let (oldtvref, newtvref, newtvid, newty) =
            if Range.is_dummy rng1 then (tvref1, tvref2, tvid2l, ty2) else (tvref2, tvref1, tvid1l, ty1)
          in
                let _ = print_for_debug_typecheck                                                                 (* for debug *)
                  ("    substituteVV " ^ (string_of_mono_type_basic (Range.dummy "", TypeVariable(oldtvref)))     (* for debug *)
                   ^ " with " ^ (string_of_mono_type_basic newty)) in                                             (* for debug *)
          let () = ( oldtvref := Link(newty) ) in
          let kd1 = Tyvarid.get_kind tvid1l in
          let kd2 = Tyvarid.get_kind tvid2l in
          let (eqnlst, kdunion) =
            match (kd1, kd2) with
            | (UniversalKind, UniversalKind)       -> ([], UniversalKind)
            | (RecordKind(asc1), UniversalKind)    -> ([], RecordKind(asc1))
            | (UniversalKind, RecordKind(asc2))    -> ([], RecordKind(asc2))
            | (RecordKind(asc1), RecordKind(asc2)) ->
                let kdunion = RecordKind(Assoc.union asc1 asc2) in
                  (Assoc.intersection asc1 asc2, kdunion)
          in
          begin
            newtvref := Free(Tyvarid.set_kind newtvid kdunion) ;
            unify_list eqnlst ;
          end

      | (TypeVariable({contents= Free(tvid1)} as tvref1), RecordType(tyasc2)) ->
          let kd1 = Tyvarid.get_kind tvid1 in
          let binc =
            match kd1 with
            | UniversalKind      -> true
            | RecordKind(tyasc1) -> Assoc.domain_included tyasc1 tyasc2
          in
          let chk = occurs tvid1 ty2 in
            if chk then
              raise InternalInclusionError
            else if not binc then
              raise InternalContradictionError
            else
              let newty2 = if Range.is_dummy rng1 then (rng2, tymain2) else (rng1, tymain2) in
                    let _ = print_for_debug_typecheck                             (* for debug *)
                      ("    substituteVR " ^ (string_of_mono_type_basic ty1)      (* for debug *)
                       ^ " with " ^ (string_of_mono_type_basic newty2)) in        (* for debug *)
              let eqnlst =
                match kd1 with
                | UniversalKind      -> []
                | RecordKind(tyasc1) -> Assoc.intersection tyasc1 tyasc2
              in
              begin
                tvref1 := Link(newty2) ;
                unify_list eqnlst ;
              end

      | (TypeVariable({contents= Free(tvid1)} as tvref1), _) ->
          let chk = occurs tvid1 ty2 in
            if chk then
              raise InternalInclusionError
            else
              let newty2 = if Range.is_dummy rng1 then (rng2, tymain2) else (rng1, tymain2) in
                      let _ = print_for_debug_typecheck                             (* for debug *)
                        ("    substituteVX " ^ (string_of_mono_type_basic ty1)      (* for debug *)
                         ^ " with " ^ (string_of_mono_type_basic newty2)) in        (* for debug *)
                tvref1 := Link(newty2)

      | (_, TypeVariable(_)) -> unify_sub ty2 ty1

      | _ -> raise InternalContradictionError


let unify_ (tyenv : Typeenv.t) (ty1 : mono_type) (ty2 : mono_type) =
  try
    unify_sub ty1 ty2
  with
  | InternalInclusionError     -> raise (InclusionError(tyenv, ty1, ty2))
  | InternalContradictionError -> raise (ContradictionError(tyenv, ty1, ty2))


let final_tyenv    : Typeenv.t ref = ref (Typeenv.from_list [])


let rec typecheck
    (qtfbl : quantifiability) (lev : Tyvarid.level)
    (tyenv : Typeenv.t) ((rng, utastmain) : untyped_abstract_tree) =
  let typecheck_iter ?l:(l = lev) ?q:(q = qtfbl) t u = typecheck q l t u in
  let unify = unify_ tyenv in
  match utastmain with
  | UTStringEmpty         -> (StringEmpty        , (rng, StringType))
  | UTBreakAndIndent      -> (SoftBreakAndIndent , (rng, StringType))
  | UTNumericConstant(nc) -> (NumericConstant(nc), (rng, IntType)   )
  | UTStringConstant(sc)  -> (StringConstant(sc) , (rng, StringType))
  | UTBooleanConstant(bc) -> (BooleanConstant(bc), (rng, BoolType)  )
  | UTUnitConstant        -> (UnitConstant       , (rng, UnitType)  )
  | UTFinishStruct        ->
      begin
        final_tyenv := tyenv ;
        (FinishStruct, (Range.dummy "finish-struct", UnitType))
      end

  | UTFinishHeaderFile    ->
      begin
        final_tyenv := tyenv ;
        (FinishHeaderFile, (Range.dummy "finish-header-file", UnitType))
      end

  | UTContentOf(mdlnmlst, varnm) ->
      begin
        try
          let pty = Typeenv.find tyenv mdlnmlst varnm in
          let tyfree = instantiate lev qtfbl pty in
          let tyres = overwrite_range_of_type tyfree rng in
          let () = print_for_debug_typecheck ("#Content " ^ varnm ^ " : " ^ (string_of_poly_type_basic pty) ^ " = " ^ (string_of_mono_type_basic tyres) ^ " (" ^ (Range.to_string rng) ^ ")") in (* for debug *)
              (ContentOf(varnm), tyres)
        with
        | Not_found -> raise (UndefinedVariable(rng, varnm))
      end

  | UTConstructor(constrnm, utast1) ->
      begin
        try
          let (tyarglist, tyid, tyc) = Typeenv.find_constructor qtfbl tyenv lev constrnm in
          let () = print_for_debug_typecheck ("#Constructor " ^ constrnm ^ " of " ^ (string_of_mono_type_basic tyc) ^ " in ... " ^ (string_of_mono_type_basic (rng, VariantType([], tyid))) ^ "(" ^ (Typeenv.find_type_name tyenv tyid) ^ ")") in (* for debug *)
          let (e1, ty1) = typecheck_iter tyenv utast1 in
          let () = unify ty1 tyc in
          let tyres = (rng, VariantType(tyarglist, tyid)) in
            (Constructor(constrnm, e1), tyres)
        with
        | Not_found -> raise (UndefinedConstructor(rng, constrnm))
      end

  | UTConcat(utast1, utast2) ->
      let (e1, ty1) = typecheck_iter tyenv utast1 in
      let () = unify ty1 (get_range utast1, StringType) in
      let (e2, ty2) = typecheck_iter tyenv utast2 in
      let () = unify ty2 (get_range utast2, StringType) in
        (Concat(e1, e2), (rng, StringType))

  | UTApply(utast1, utast2) ->
      let (e1, ty1) = typecheck_iter tyenv utast1 in
      let (e2, ty2) = typecheck_iter tyenv utast2 in
      let _ = print_for_debug_typecheck ("#Apply " ^ (string_of_utast (rng, utastmain))) in (* for debug *)
      begin
        match ty1 with
        | (_, FuncType(tydom, tycod)) ->
            let () = unify tydom ty2 in
            let _ = print_for_debug_typecheck ("1 " ^ (string_of_ast (Apply(e1, e2))) ^ " : " (* for debug *)
                                               ^ (string_of_mono_type_basic tycod)) in        (* for debug *)
            let tycodnew = overwrite_range_of_type tycod rng in
              (Apply(e1, e2), tycodnew)
        | _ ->
            let tvid = Tyvarid.fresh UniversalKind qtfbl lev () in
            let beta = (rng, TypeVariable(ref (Free(tvid)))) in
            let () = unify ty1 (get_range utast1, FuncType(ty2, beta)) in
            let _ = print_for_debug_typecheck ("2 " ^ (string_of_ast (Apply(e1, e2))) ^ " : " ^ (string_of_mono_type_basic beta) ^ " = " ^ (string_of_mono_type_basic beta)) in (* for debug *)
                (Apply(e1, e2), beta)
      end

  | UTLambdaAbstract(varrng, varnm, utast1) ->
      let tvid = Tyvarid.fresh UniversalKind qtfbl lev () in
      let beta = (varrng, TypeVariable(ref (Free(tvid)))) in
      let (e1, ty1) = typecheck_iter (Typeenv.add tyenv varnm (Poly(beta))) utast1 in
        let tydom = beta in
        let tycod = ty1 in
          (LambdaAbstract(varnm, e1), (rng, FuncType(tydom, tycod)))

  | UTLetIn(utmutletcons, utast2) ->
      let (tyenvnew, _, mutletcons) = make_type_environment_by_let qtfbl lev tyenv utmutletcons in
      let (e2, ty2) = typecheck_iter tyenvnew utast2 in
        (LetIn(mutletcons, e2), ty2)

  | UTIfThenElse(utastB, utast1, utast2) ->
      let (eB, tyB) = typecheck_iter tyenv utastB in
      let () = unify tyB (Range.dummy "if-bool", BoolType) in
      let (e1, ty1) = typecheck_iter tyenv utast1 in
      let (e2, ty2) = typecheck_iter tyenv utast2 in
      let () = unify ty2 ty1 in
        (IfThenElse(eB, e1, e2), ty1)

(* ---- imperatives ---- *)

  | UTLetMutableIn(varrng, varnm, utastI, utastA) ->
      let (tyenvI, eI, tyI) = make_type_environment_by_let_mutable lev tyenv varrng varnm utastI in
      let (eA, tyA) = typecheck_iter tyenvI utastA in
        (LetMutableIn(varnm, eI, eA), tyA)

  | UTOverwrite(varrng, varnm, utastN) ->
      let (_, tyvar) = typecheck_iter tyenv (varrng, UTContentOf([], varnm)) in
      let (eN, tyN) = typecheck_iter tyenv utastN in
      let () = unify tyvar (get_range utastN, RefType(tyN)) in
          (* --
             actually 'get_range utastnew' is not good
             since the right side expression has type 't, not 't ref 
          -- *)
        (Overwrite(varnm, eN), (rng, UnitType))

  | UTSequential(utast1, utast2) ->
      let (e1, ty1) = typecheck_iter tyenv utast1 in
      let () = unify ty1 (get_range utast1, UnitType) in
      let (e2, ty2) = typecheck_iter tyenv utast2 in
        (Sequential(e1, e2), ty2)

  | UTWhileDo(utastB, utastC) ->
      let (eB, tyB) = typecheck_iter tyenv utastB in
      let () = unify tyB (get_range utastB, BoolType) in
      let (eC, tyC) = typecheck_iter tyenv utastC in
      let () = unify tyC (get_range utastC, UnitType) in
        (WhileDo(eB, eC), (rng, UnitType))

  | UTLazyContent(utast1) ->
      let (e1, ty1) = typecheck_iter tyenv utast1 in
        (LazyContent(e1), ty1)

(* ---- final reference ---- *)

  | UTDeclareGlobalHash(utastK, utastI) ->
      let (eK, tyK) = typecheck_iter tyenv utastK in
      let () = (unify tyK (get_range utastK, StringType)) in
      let (eI, tyI) = typecheck_iter tyenv utastI in
      let () = unify tyI (get_range utastI, StringType) in
        (DeclareGlobalHash(eK, eI), (rng, UnitType))

  | UTOverwriteGlobalHash(utastK, utastN) ->
      let (eK, tyK) = typecheck_iter tyenv utastK in
      let () = unify tyK (get_range utastK, StringType) in
      let (eN, tyN) = typecheck_iter tyenv utastN in
      let () = unify tyN (get_range utastN, StringType) in
        (OverwriteGlobalHash(eK, eN), (rng, UnitType))

  | UTReferenceFinal(utast1) ->
      let (e1, ty1) = typecheck_iter tyenv utast1 in
      let () = unify ty1 (rng, StringType) in
        (ReferenceFinal(e1), (rng, StringType))

(* ---- class/id option ---- *)

  | UTApplyClassAndID(utastcls, utastid, utast1) ->
      let dr = Range.dummy "ut-apply-class-and-id" in
      let tyenv1    = Typeenv.add tyenv  "class-name" (Poly((dr, VariantType([(dr, StringType)], Typeenv.find_type_id tyenv "maybe")))) in
      let tyenv_new = Typeenv.add tyenv1 "id-name"    (Poly((dr, VariantType([(dr, StringType)], Typeenv.find_type_id tyenv "maybe")))) in
      let (ecls, _) = typecheck_iter tyenv utastcls in
      let (eid, _)  = typecheck_iter tyenv utastid in
      let (e1, ty1) = typecheck_iter tyenv_new utast1 in
        (ApplyClassAndID(ecls, eid, e1), ty1)

  | UTClassAndIDRegion(utast1) ->
      let dr = Range.dummy "ut-class-and-id-region" in
      let tyenv1    = Typeenv.add tyenv  "class-name" (Poly((dr, VariantType([(dr, StringType)], Typeenv.find_type_id tyenv "maybe")))) in (* temporary *)
      let tyenv_new = Typeenv.add tyenv1 "id-name"    (Poly((dr, VariantType([(dr, StringType)], Typeenv.find_type_id tyenv "maybe")))) in (* temporary *)
      let (e1, ty1) = typecheck_iter tyenv_new utast1 in
        (e1, ty1)

(* ---- lightweight itemize ---- *)

  | UTItemize(utitmz) ->
      let eitmz = typecheck_itemize qtfbl lev tyenv utitmz in
        (eitmz, (rng, VariantType([], Typeenv.find_type_id tyenv "itemize"))) (* temporary *)

(* ---- list ---- *)

  | UTListCons(utastH, utastT) ->
      let (eH, tyH) = typecheck_iter tyenv utastH in
      let (eT, tyT) = typecheck_iter tyenv utastT in
      let () = unify tyT (Range.dummy "list-cons", ListType(tyH)) in
      let tyres = (rng, ListType(tyH)) in
        (ListCons(eH, eT), tyres)

  | UTEndOfList ->
      let tvid = Tyvarid.fresh UniversalKind qtfbl lev () in
      let beta = (rng, TypeVariable(ref (Free(tvid)))) in
        (EndOfList, (rng, ListType(beta)))

(* ---- tuple ---- *)

  | UTTupleCons(utastH, utastT) ->
      let (eH, tyH) = typecheck_iter tyenv utastH in
      let (eT, tyT) = typecheck_iter tyenv utastT in
      let tyres =
        match tyT with
        | (_, ProductType(tylist)) -> (rng, ProductType(tyH :: tylist))
        | _                        -> assert false
      in
        (TupleCons(eH, eT), tyres)

  | UTEndOfTuple -> (EndOfTuple, (rng, ProductType([])))

(* ---- records ---- *)

  | UTRecord(flutlst) -> typecheck_record qtfbl lev tyenv flutlst rng

  | UTAccessField(utast1, fldnm) ->
      let (e1, ty1) = typecheck_iter tyenv utast1 in
      let tvidF = Tyvarid.fresh UniversalKind qtfbl lev () in
      let betaF = (rng, TypeVariable(ref (Free(tvidF)))) in
      let tvid1 = Tyvarid.fresh (RecordKind(Assoc.of_list [(fldnm, betaF)])) qtfbl lev () in
      let beta1 = (get_range utast1, TypeVariable(ref (Free(tvid1)))) in
      let () = unify beta1 ty1 in
        (AccessField(e1, fldnm), betaF)

(* ---- other fundamentals ---- *)

  | UTPatternMatch(utastO, utpmcons) ->
      let (eO, tyO) = typecheck_iter tyenv utastO in
      let tvid = Tyvarid.fresh UniversalKind qtfbl lev () in
      let beta = (Range.dummy "ut-pattern-match", TypeVariable(ref (Free(tvid)))) in
      let (pmcons, tyP) =
            typecheck_pattern_match_cons qtfbl lev tyenv utpmcons tyO beta in
        (PatternMatch(eO, pmcons), tyP)

  | UTDeclareVariantIn(mutvarntcons, utastA) ->
      let tyenvnew = Typeenv.add_mutual_cons tyenv lev mutvarntcons in
        typecheck_iter tyenvnew utastA

  | UTModule(mdlnm, sigopt, utastM, utastA) -> (* temporary; will use sigopt *)
      let tyenvinner = Typeenv.enter_new_module tyenv mdlnm in
      let (eM, _) = typecheck_iter tyenvinner utastM in
      let tyenvmid = Typeenv.sigcheck qtfbl lev (!final_tyenv) sigopt in
      let tyenvouter = Typeenv.leave_module tyenvmid in
      let (eA, tyA) = typecheck_iter tyenvouter utastA in
        (Module(mdlnm, eM, eA), tyA)


and typecheck_record
    (qtfbl : quantifiability) (lev : Tyvarid.level) (tyenv : Typeenv.t)
    (flutlst : (field_name * untyped_abstract_tree) list) (rng : Range.t)
=
  let rec aux
      (tyenv : Typeenv.t) (lst : (field_name * untyped_abstract_tree) list)
      (accelst : (field_name * abstract_tree) list) (acctylst : (field_name * mono_type) list)
  =
    match lst with
    | []                       -> (List.rev accelst, List.rev acctylst)
    | (fldnmX, utastX) :: tail ->
        let (eX, tyX) = typecheck qtfbl lev tyenv utastX in
          aux tyenv tail ((fldnmX, eX) :: accelst) ((fldnmX, tyX) :: acctylst)
  in
  let (elst, tylst) = aux tyenv flutlst [] [] in
  let tylstfinal = List.map (fun (fldnm, ty) -> (fldnm, ty)) tylst in
    (Record(Assoc.of_list elst), (rng, RecordType(Assoc.of_list tylstfinal)))


and typecheck_itemize (qtfbl : quantifiability) (lev : Tyvarid.level) (tyenv : Typeenv.t) (UTItem(utast1, utitmzlst)) =
  let (e1, ty1) = typecheck qtfbl lev tyenv utast1 in
  let () = unify_ tyenv ty1 (Range.dummy "typecheck_itemize_string", StringType) in
  let elst = typecheck_itemize_list qtfbl lev tyenv utitmzlst in
    (Constructor("Item", TupleCons(e1, TupleCons(elst, EndOfTuple))))


and typecheck_itemize_list
    (qtfbl : quantifiability) (lev : Tyvarid.level)
    (tyenv : Typeenv.t) (utitmzlst : untyped_itemize list) =
  match utitmzlst with
  | []                  -> EndOfList
  | hditmz :: tlitmzlst ->
      let ehd = typecheck_itemize qtfbl lev tyenv hditmz in
      let etl = typecheck_itemize_list qtfbl lev tyenv tlitmzlst in
        ListCons(ehd, etl)


and typecheck_pattern_match_cons
    (qtfbl : quantifiability) (lev : Tyvarid.level)
    (tyenv : Typeenv.t) (utpmcons : untyped_pattern_match_cons) (tyobj : mono_type) (tyres : mono_type) =
  let iter = typecheck_pattern_match_cons qtfbl lev in
  let unify = unify_ tyenv in
  match utpmcons with
  | UTEndOfPatternMatch -> (EndOfPatternMatch, tyres)

  | UTPatternMatchCons(utpat, utast1, tailcons) ->
      let (epat, typat, tyenvpat) = typecheck_pattern qtfbl lev tyenv utpat in
      let () = unify typat tyobj in
      let (e1, ty1) = typecheck qtfbl lev tyenvpat utast1 in
      let () = unify ty1 tyres in
      let (pmctl, tytl) =
            iter tyenv tailcons tyobj tyres in
        (PatternMatchCons(epat, e1, pmctl), tytl)

  | UTPatternMatchConsWhen(utpat, utastb, utast1, tailcons) ->
      let (epat, typat, tyenvpat) = typecheck_pattern qtfbl lev tyenv utpat in
      let () = unify typat tyobj in
      let (eB, tyB) = typecheck qtfbl lev tyenvpat utastb in
      let () = unify tyB (Range.dummy "pattern-match-cons-when", BoolType) in
      let (e1, ty1) = typecheck qtfbl lev tyenvpat utast1 in
      let () = unify ty1 tyres in
      let (pmctl, tytl) =
            iter tyenv tailcons tyobj tyres in
        (PatternMatchConsWhen(epat, eB, e1, pmctl), tytl)


and typecheck_pattern
    (qtfbl : quantifiability) (lev : Tyvarid.level)
    (tyenv : Typeenv.t) (rng, utpatmain) =
  let iter = typecheck_pattern qtfbl lev in
  let unify = unify_ tyenv in
  match utpatmain with
  | UTPNumericConstant(nc) -> (PNumericConstant(nc), (rng, IntType), tyenv)
  | UTPBooleanConstant(bc) -> (PBooleanConstant(bc), (rng, BoolType), tyenv)
  | UTPStringConstant(ut1) ->
      let (e1, ty1) = typecheck qtfbl lev tyenv ut1 in
      let () = unify (Range.dummy "pattern-string-constant", StringType) ty1 in
        (PStringConstant(e1), (rng, StringType), tyenv)

  | UTPUnitConstant        -> (PUnitConstant, (rng, UnitType), tyenv)

  | UTPListCons(utpat1, utpat2) ->
      let (epat1, typat1, tyenv1) = iter tyenv utpat1 in
      let (epat2, typat2, tyenv2) = iter tyenv1 utpat2 in
      let () = unify typat2 (Range.dummy "pattern-list-cons", ListType(typat1)) in
        (PListCons(epat1, epat2), typat2, tyenv2)

  | UTPEndOfList ->
      let tvid = Tyvarid.fresh UniversalKind qtfbl lev () in
      let beta = (rng, TypeVariable(ref (Free(tvid)))) in
        (PEndOfList, (rng, ListType(beta)), tyenv)

  | UTPTupleCons(utpat1, utpat2) ->
      let (epat1, typat1, tyenv1) = iter tyenv utpat1 in
      let (epat2, typat2, tyenv2) = iter tyenv1 utpat2 in
      let tyres =
        match typat2 with
        | (rng, ProductType(tylist)) -> (rng, ProductType(typat1 :: tylist))
        | _                          -> assert false
      in
        (PTupleCons(epat1, epat2), tyres, tyenv2)

  | UTPEndOfTuple -> (PEndOfTuple, (rng, ProductType([])), tyenv)

  | UTPWildCard ->
      let tvid = Tyvarid.fresh UniversalKind qtfbl lev () in
      let beta = (rng, TypeVariable(ref (Free(tvid)))) in
        (PWildCard, beta, tyenv)

  | UTPVariable(varnm) ->
      let tvid = Tyvarid.fresh UniversalKind qtfbl lev () in
      let beta = (rng, TypeVariable(ref (Free(tvid)))) in
        (PVariable(varnm), beta, Typeenv.add tyenv varnm (Poly(beta)))

  | UTPAsVariable(varnm, utpat1) ->
      let tvid = Tyvarid.fresh UniversalKind qtfbl lev () in
      let beta = (rng, TypeVariable(ref (Free(tvid)))) in
      let (epat1, typat1, tyenv1) = iter tyenv utpat1 in
        (PAsVariable(varnm, epat1), typat1, Typeenv.add tyenv varnm (Poly(beta)))

  | UTPConstructor(constrnm, utpat1) ->
      begin
        try
          let (tyarglist, tyid, tyc) = Typeenv.find_constructor qtfbl tyenv lev constrnm in
          let () = print_for_debug_typecheck ("P-find " ^ constrnm ^ " of " ^ (string_of_mono_type_basic tyc)) in (* for debug *)
          let (epat1, typat1, tyenv1) = iter tyenv utpat1 in
          let () = unify tyc typat1 in
            (PConstructor(constrnm, epat1), (rng, VariantType(tyarglist, tyid)), tyenv1)
        with
        | Not_found -> raise (UndefinedConstructor(rng, constrnm))
      end


and make_type_environment_by_let
    (qtfbl : quantifiability) (lev : Tyvarid.level)
    (tyenv : Typeenv.t) (utmutletcons : untyped_mutual_let_cons) =
  let rec add_mutual_variables (acctyenv : Typeenv.t) (mutletcons : untyped_mutual_let_cons) =
    let iter = add_mutual_variables in
      match mutletcons with
      | []                             -> (acctyenv, [])
      | (_, varnm, astdef) :: tailcons ->
          let tvid = Tyvarid.fresh UniversalKind qtfbl (Tyvarid.succ_level lev) () in
          let beta = (get_range astdef, TypeVariable(ref (Free(tvid)))) in
          let _ = print_for_debug_typecheck ("#AddMutualVar " ^ varnm ^ " : '" ^ (Tyvarid.show_direct tvid) ^ " :: U") in (* for debug *)
          let (tyenvfinal, tvtylst) = iter (Typeenv.add acctyenv varnm (Poly(beta))) tailcons in
            (tyenvfinal, ((varnm, beta) :: tvtylst))
  in
  let rec typecheck_mutual_contents
      (lev : Tyvarid.level)
      (tyenvforrec : Typeenv.t) (utmutletcons : untyped_mutual_let_cons) (tvtylst : (var_name * mono_type) list)
      (acctvtylstout : (var_name * mono_type) list)
  =
    let iter = typecheck_mutual_contents lev in
    let unify = unify_ tyenv in
    match (utmutletcons, tvtylst) with
    | ([], []) -> (tyenvforrec, EndOfMutualLet, List.rev acctvtylstout)

    | ((mntyopt, varnm, utast1) :: tailcons, (_, beta) :: tvtytail) ->
        let (e1, ty1) = typecheck qtfbl (Tyvarid.succ_level lev) tyenvforrec utast1 in
        begin
          match mntyopt with
          | None ->
              let () = unify ty1 beta in
                let (tyenvfinal, mutletcons_tail, tvtylstoutfinal) = iter tyenvforrec tailcons tvtytail ((varnm, beta) :: acctvtylstout) in
                  (tyenvfinal, MutualLetCons(varnm, e1, mutletcons_tail), tvtylstoutfinal)

          | Some(mnty) ->
              let tyin = Typeenv.fix_manual_type_for_inner qtfbl tyenv lev mnty in
              let () = unify ty1 beta in
              let () = unify tyin beta in
                let (tyenvfinal, mutletconstail, tvtylstoutfinal) =
                      iter tyenvforrec tailcons tvtytail ((varnm, beta (* <-doubtful *)) :: acctvtylstout) in
                    (tyenvfinal, MutualLetCons(varnm, e1, mutletconstail), tvtylstoutfinal)

          end

    | _ -> assert false
  in
  let rec make_forall_type_mutual (tyenv : Typeenv.t) (tyenv_before_let : Typeenv.t) tvtylst tvtylst_forall =
    match tvtylst with
    | []                        -> (tyenv, tvtylst_forall)
    | (varnm, tvty) :: tvtytail ->
        let prety = tvty in
          let () = print_for_debug_typecheck ("#Generalize1 " ^ varnm ^ " : " ^ (string_of_mono_type_basic prety)) in  (* for debug *)
          let pty = poly_extend erase_range_of_type (generalize lev prety) in
          let () = print_for_debug_typecheck ("#Generalize2 " ^ varnm ^ " : " ^ (string_of_poly_type_basic pty)) in (* for debug *)
          let tvtylst_forall_new = (varnm, pty) :: tvtylst_forall in
            make_forall_type_mutual (Typeenv.add tyenv varnm pty) tyenv_before_let tvtytail tvtylst_forall_new
  in
  let (tyenvforrec, tvtylstforrec) = add_mutual_variables tyenv utmutletcons in
  let (tyenv_new, mutletcons, tvtylstout) =
        typecheck_mutual_contents lev tyenvforrec utmutletcons tvtylstforrec [] in
  let (tyenv_forall, tvtylst_forall) = make_forall_type_mutual tyenv_new tyenv tvtylstout [] in
    (tyenv_forall, tvtylst_forall, mutletcons)


and make_type_environment_by_let_mutable (lev : Tyvarid.level) (tyenv : Typeenv.t) varrng varnm utastI =
  let (eI, tyI) = typecheck Unquantifiable lev tyenv utastI in
  let () = print_for_debug_typecheck ("#AddMutable " ^ varnm ^ " : " ^ (string_of_mono_type_basic (varrng, RefType(tyI)))) in (* for debug *)
  let tyenvI = Typeenv.add tyenv varnm (Poly((varrng, RefType(tyI)))) in
    (tyenvI, eI, tyI)


let main (tyenv : Typeenv.t) (utast : untyped_abstract_tree) =
    begin
      final_tyenv := tyenv ;
      let (e, ty) = typecheck Quantifiable Tyvarid.bottom_level tyenv utast in
        (ty, !final_tyenv, e)
    end
