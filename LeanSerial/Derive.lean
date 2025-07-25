import Lean
import Lean.Elab.Command
import Lean.Elab.Deriving.Basic
import LeanSerial.Core

open Lean Elab Meta Term Command

structure ConstructorData where
  encodePattern : TSyntax `term
  encodeElems : Array (TSyntax `term)
  name : String
  ctorApp : TSyntax `term
  decodeStmts : Array (TSyntax `doElem)

private def mkFieldName (i : Nat) : Name := Name.mkSimple s!"field{i}"

private def mkAuxFunctionName (name: String) (typeId : TSyntax `ident) : Ident :=
  mkIdent (Name.mkSimple s!"{name}_impl_{typeId}")

private def generateContainerEncode (fieldType : Expr) (fieldTerm : TSyntax `term) (encodeFnName : Ident) : CommandElabM (TSyntax `term) := do
  match fieldType with
  | .app (.const `List _) _ =>
    `(LeanSerial.SerialValue.compound "List" (($fieldTerm).map $encodeFnName:ident |>.toArray))
  | .app (.const `Array _) _ =>
    `(LeanSerial.SerialValue.compound "Array" (($fieldTerm).map $encodeFnName:ident))
  | .app (.const `Option _) _ =>
    `(Option.casesOn $fieldTerm
        (LeanSerial.SerialValue.compound "Option" #[LeanSerial.SerialValue.str "none"])
        (fun x => LeanSerial.SerialValue.compound "Option" #[LeanSerial.SerialValue.str "some", $encodeFnName:ident x]))
  | .app (.app (.const `Prod _) _) _ =>
    `(LeanSerial.SerialValue.compound "Prod" #[$encodeFnName:ident ($fieldTerm).fst, $encodeFnName:ident ($fieldTerm).snd])
  | .app (.app (.const `Sum _) _) _ =>
    `(Sum.casesOn $fieldTerm
        (fun x => LeanSerial.SerialValue.compound "Sum" #[LeanSerial.SerialValue.str "inl", $encodeFnName:ident x])
        (fun x => LeanSerial.SerialValue.compound "Sum" #[LeanSerial.SerialValue.str "inr", $encodeFnName:ident x]))
  | _ => throwError "Invalid container type"

private def generateContainerDecode (fieldType : Expr) (fieldId : Ident) (index : Nat) (decodeFnName : Ident) : CommandElabM (List (TSyntax `doElem)) := do
  match fieldType with
  | .app (.const `List _) _ => pure [
      ← `(doElem| let containerSv := args[$(quote index)]!),
      ← `(doElem| let containerArgs ← LeanSerial.decodeCompound "List" containerSv),
      ← `(doElem| let listResult ← containerArgs.mapM $decodeFnName:ident),
      ← `(doElem| let $fieldId := listResult.toList)
    ]
  | .app (.const `Array _) _ => pure [
      ← `(doElem| let containerSv := args[$(quote index)]!),
      ← `(doElem| let containerArgs ← LeanSerial.decodeCompound "Array" containerSv),
      ← `(doElem| let $fieldId ← containerArgs.mapM $decodeFnName:ident)
    ]
  | .app (.const `Option _) _ => pure [
      ← `(doElem| let containerSv := args[$(quote index)]!),
      ← `(doElem| let containerArgs ← LeanSerial.decodeCompound "Option" containerSv),
      ← `(doElem| let $fieldId ← do
        if containerArgs.size == 1 && containerArgs[0]! == LeanSerial.SerialValue.str "none" then
          return .none
        else if containerArgs.size == 2 && containerArgs[0]! == LeanSerial.SerialValue.str "some" then do
          let val ← $decodeFnName:ident containerArgs[1]!
          return (.some val)
        else
          throw "Invalid Option format")
    ]
  | .app (.app (.const `Prod _) _) _ => pure [
      ← `(doElem| let containerSv := args[$(quote index)]!),
      ← `(doElem| let containerArgs ← LeanSerial.decodeCompound "Prod" containerSv),
      ← `(doElem| let $fieldId ← do
        if containerArgs.size == 2 then do
          let fst ← $decodeFnName:ident containerArgs[0]!
          let snd ← $decodeFnName:ident containerArgs[1]!
          return (fst, snd)
        else
          throw "Invalid Prod format")
    ]
  | .app (.app (.const `Sum _) _) _ => pure [
      ← `(doElem| let containerSv := args[$(quote index)]!),
      ← `(doElem| let containerArgs ← LeanSerial.decodeCompound "Sum" containerSv),
      ← `(doElem| let $fieldId ← do
        if containerArgs.size == 2 then
          if containerArgs[0]! == LeanSerial.SerialValue.str "inl" then do
            let val ← $decodeFnName:ident containerArgs[1]!
            return (.inl val)
          else if containerArgs[0]! == LeanSerial.SerialValue.str "inr" then do
            let val ← $decodeFnName:ident containerArgs[1]!
            return (.inr val)
          else
            throw "Invalid Sum tag"
        else
          throw "Invalid Sum format")
    ]
  | _ => throwError "Invalid container type"

private def extractTypeParameters (inductVal : InductiveVal) : CommandElabM (Array Name) := do
  if inductVal.numParams = 0 then
    return #[]

  let firstCtorName := inductVal.ctors[0]!
  let ctorInfo ← getConstInfoCtor firstCtorName

  liftTermElabM do
    forallTelescopeReducing ctorInfo.type fun xs _ => do
      let mut typeParams : Array Name := #[]
      for i in [:inductVal.numParams] do
        let x := xs[i]!
        let localDecl ← x.fvarId!.getDecl
        typeParams := typeParams.push localDecl.userName
      return typeParams

private def mkConstructorData (typeId : TSyntax `ident) (inductVal : InductiveVal) (ctor : ConstructorVal) : CommandElabM ConstructorData := do
  let ctorId := mkIdent ctor.name

  if ctor.numFields = 0 then
    return {
      encodePattern := ⟨ctorId⟩,
      encodeElems := #[],
      name := ctor.name.toString,
      ctorApp := ⟨ctorId⟩,
      decodeStmts := #[]
    }

  let fieldIds := (Array.range ctor.numFields).map (mkIdent ∘ mkFieldName)
  let fieldTerms := fieldIds.map fun fieldId => ⟨fieldId⟩

  let encodeFnName := mkAuxFunctionName "encode" typeId
  let decodeFnName := mkAuxFunctionName "decode" typeId

  let ctorInfo ← getConstInfoCtor ctor.name
  let fieldTypes ← liftTermElabM do
    forallTelescopeReducing ctorInfo.type fun xs _ => do
      let mut types : Array Expr := #[]
      for i in [:ctor.numFields] do
        let x := xs[inductVal.numParams + i]!
        let localDecl ← x.fvarId!.getDecl
        types := types.push localDecl.type
      return types

  let result ← fieldTerms.zip fieldIds |>.zip fieldTypes |>.mapIdxM fun i ((fieldTerm, fieldId), fieldType) => do
    let isDirectRecursive := fieldType.isAppOf inductVal.name
    let isSimpleContainer := match fieldType with
      | .app (.const name _) inner =>
        (name == `List || name == `Array || name == `Option) && inner.isAppOf inductVal.name
      | .app (.app (.const name _) _) inner =>
        (name == `Prod || name == `Sum) && inner.isAppOf inductVal.name
      | _ => false

    let encodeElem ← if isDirectRecursive then
      `($encodeFnName:ident $fieldTerm)
    else if isSimpleContainer then
      generateContainerEncode fieldType fieldTerm encodeFnName
    else
      `(LeanSerial.encode $fieldTerm)

    let decodeStmt ← if isDirectRecursive then
      pure #[← `(doElem| let $fieldId ← $decodeFnName:ident args[$(quote i)]!)]
    else if isSimpleContainer then
      let stmts ← generateContainerDecode fieldType fieldId i decodeFnName
      pure stmts.toArray
    else
      pure #[← `(doElem| let $fieldId ← LeanSerial.decode args[$(quote i)]!)]

    return (encodeElem, decodeStmt)

  let (encodeElems, decodeStmts) := result.unzip
  let decodeStmts := decodeStmts.flatten

  let ctorApp ← fieldTerms.foldlM (fun acc fieldTerm => `($acc $fieldTerm)) (⟨ctorId⟩ : TSyntax `term)

  let encodePattern ←
    if ctor.numFields = 0 then
      pure ⟨ctorId⟩
    else
      `($(ctorId) $fieldTerms*)

  return {
    encodePattern := encodePattern,
    encodeElems := encodeElems,
    name := ctor.name.toString.replace ".mk" "",
    ctorApp := ctorApp,
    decodeStmts := decodeStmts
  }

private def mkSerializableQuotation (typeId : TSyntax `ident) (constructorData : Array ConstructorData) (constructorInfos : Array ConstructorVal) (isRecursive : Bool) (typeParams : Array Name) : CommandElabM (Array (TSyntax `command)) := do
  let encodeMatches := constructorData.map fun cd =>
    (cd.encodePattern, cd.encodeElems, cd.name)

  let encodeArms ← encodeMatches.mapM fun (_, elems, name) =>
    `(LeanSerial.SerialValue.compound $(quote name) #[$(elems),*])

  let decodeArms ← constructorData.mapIdxM fun i data => do
    let numFields := constructorInfos[i]!.numFields
    `(doSeq|
      if args.size = $(quote numFields) then do
        $[$(data.decodeStmts):doElem]*
        .ok $(data.ctorApp)
      else
        .error "Field count mismatch")

  let decodePatterns ← constructorData.mapM fun data => `($(quote data.name))
  let encodePatterns := constructorData.map (·.encodePattern)

  let encodeFnName := mkAuxFunctionName "encode" typeId
  let decodeFnName := mkAuxFunctionName "decode" typeId

  let polyTypeApp ← if typeParams.isEmpty then
    pure ⟨typeId⟩
  else
    let paramIds := typeParams.map mkIdent
    `($typeId $paramIds*)
  let instConstraints ← typeParams.mapM fun param => do
    let paramId := mkIdent param
    `(bracketedBinder| [LeanSerial.Serializable $paramId])

  let encodeDef ← if isRecursive then
    if typeParams.isEmpty then
      `(partial def $encodeFnName (v : $typeId) : LeanSerial.SerialValue :=
          match v with
          $[| $encodePatterns => $encodeArms]*)
    else
      `(partial def $encodeFnName $instConstraints:bracketedBinder* (v : $polyTypeApp) : LeanSerial.SerialValue :=
          match v with
          $[| $encodePatterns => $encodeArms]*)
  else
    if typeParams.isEmpty then
      `(def $encodeFnName (v : $typeId) : LeanSerial.SerialValue :=
          match v with
          $[| $encodePatterns => $encodeArms]*)
    else
      `(def $encodeFnName $instConstraints:bracketedBinder* (v : $polyTypeApp) : LeanSerial.SerialValue :=
          match v with
          $[| $encodePatterns => $encodeArms]*)

  let decodeDef ← if isRecursive then
    if typeParams.isEmpty then
      `(partial def $decodeFnName (sv : LeanSerial.SerialValue) : Except String $typeId := do
          let .compound ctor args := sv | .error "Expected compound value"
          match ctor with
          $[| $decodePatterns => $decodeArms]*
          | _ => .error "Unknown constructor")
    else
      `(partial def $decodeFnName $instConstraints:bracketedBinder* (sv : LeanSerial.SerialValue) : Except String $polyTypeApp := do
          let .compound ctor args := sv | .error "Expected compound value"
          match ctor with
          $[| $decodePatterns => $decodeArms]*
          | _ => .error "Unknown constructor")
  else
    if typeParams.isEmpty then
      `(def $decodeFnName (sv : LeanSerial.SerialValue) : Except String $typeId := do
          let .compound ctor args := sv | .error "Expected compound value"
          match ctor with
          $[| $decodePatterns => $decodeArms]*
          | _ => .error "Unknown constructor")
    else
      `(def $decodeFnName $instConstraints:bracketedBinder* (sv : LeanSerial.SerialValue) : Except String $polyTypeApp := do
          let .compound ctor args := sv | .error "Expected compound value"
          match ctor with
          $[| $decodePatterns => $decodeArms]*
          | _ => .error "Unknown constructor")

  let inst ← if typeParams.isEmpty then
    `(instance : LeanSerial.Serializable $typeId where
        encode := $encodeFnName
        decode := $decodeFnName)
  else
    `(instance $instConstraints:bracketedBinder* : LeanSerial.Serializable $polyTypeApp where
        encode := $encodeFnName
        decode := $decodeFnName)

  return #[encodeDef, decodeDef, inst]

def mkSerializableInstance (typeName : Name) : CommandElabM Unit := do
  let env ← getEnv

  let some constInfo := env.find? typeName
    | throwError s!"Type {typeName} not found in environment. Make sure the type is properly imported and defined."

  match constInfo with
  | ConstantInfo.inductInfo inductVal =>
    let typeId := mkIdent typeName
    let typeParams ← extractTypeParameters inductVal

    let constructorInfosArray ← inductVal.ctors.toArray.mapM fun ctorName => do
      let some (ConstantInfo.ctorInfo ctorVal) := env.find? ctorName
        | throwError s!"Constructor {ctorName} not found for inductive type {typeName}. This is likely an internal error."
      return ctorVal

    if constructorInfosArray.isEmpty then
      throwError s!"Inductive type {typeName} has no constructors. Empty inductive types cannot be serialized."

    let constructorData ← constructorInfosArray.mapM (mkConstructorData typeId inductVal ·)
    let cmds ← mkSerializableQuotation typeId constructorData constructorInfosArray inductVal.isRec typeParams

    cmds.forM elabCommand
  | _ =>
    throwError s!"Type {typeName} is not an inductive type. Serializable instances can only be created for inductive types."

initialize
  registerDerivingHandler ``LeanSerial.Serializable fun declNames => do
    for declName in declNames do
      mkSerializableInstance declName
    return true
