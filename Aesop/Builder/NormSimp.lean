/-
Copyright (c) 2022 Jannis Limperg. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Jannis Limperg
-/

import Aesop.Builder.Basic

open Lean
open Lean.Meta

namespace Aesop.RuleBuilder

def normSimpUnfold : RuleBuilder :=
  ofGlobalRuleBuilder builderName λ _ decl => do
    try {
      let thms : SimpTheorems := {}
      let thms ← thms.addDeclToUnfold decl
      return .globalSimp {
        builder := builderName
        entries := thms.simpEntries
      }
    } catch e => {
      throwError "aesop: unfold builder: exception while trying to add {decl} as declaration to unfold:{indentD e.toMessageData}"
    }
  where
    builderName := BuilderName.unfold

def normSimpLemmas : RuleBuilder := λ input => do
  match input.kind with
  | .global decl =>
    try {
      let thms : SimpTheorems := {}
      let thms ← thms.addConst decl
      return .global $ .globalSimp {
        builder := builderName
        entries := thms.simpEntries
      }
    } catch e => {
      throwError "aesop: simp builder: exception while trying to add {decl} as a simp theorem:{indentD e.toMessageData}"
    }
  | .«local» fvarUserName goal =>
    goal.withContext do
      let type ← instantiateMVars (← getLocalDeclFromUserName fvarUserName).type
      unless ← isProp type do
        throwError "aesop: simp builder: simp rules must be propositions but {fvarUserName} has type{indentExpr type}"
      return .«local» goal (.localSimp { builder := builderName, fvarUserName })
  where
    builderName := BuilderName.simp

end Aesop.RuleBuilder
