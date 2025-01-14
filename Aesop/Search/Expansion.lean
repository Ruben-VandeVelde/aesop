/-
Copyright (c) 2022 Jannis Limperg. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Jannis Limperg
-/

import Aesop.RuleTac
import Aesop.Search.Expansion.Simp
import Aesop.Search.RuleSelection

open Lean
open Lean.Meta

namespace Aesop

variable [Aesop.Queue Q]

inductive RuleResult
  | proven
  | failed
  | succeeded
  | postponed (result : PostponedSafeRule)

def RuleResult.isSuccessful
  | proven => true
  | succeeded => true
  | failed => false
  | postponed .. => false


inductive NormRuleResult
  | succeeded (goal : MVarId) (branchState : BranchState)
      (scriptStep : UnstructuredScriptStep)
  | proven (scriptStep : UnstructuredScriptStep)
  | failed

def NormRuleResult.isSuccessful : NormRuleResult → Bool
  | succeeded .. => true
  | proven .. => true
  | failed => false

def runRuleTac (tac : RuleTac) (ruleName : RuleName)
    (preState : Meta.SavedState) (input : RuleTacInput) :
    MetaM (Sum Exception RuleTacOutput) := do
  let result ←
    try
      Sum.inr <$> preState.runMetaM' (tac input)
    catch e =>
      return Sum.inl e
  if ← Check.rules.isEnabled then
    if let (Sum.inr ruleOutput) := result then
      ruleOutput.applications.forM λ rapp => do
        if let (some err) ← rapp.check then
          throwError "{Check.rules.name}: while applying rule {ruleName}: {err}"
  return result

def runRegularRuleTac (goal : Goal) (tac : RuleTac) (ruleName : RuleName)
    (indexMatchLocations : UnorderedArraySet IndexMatchLocation)
    (branchState : RuleBranchState) (options : Options) :
    MetaM (Sum Exception RuleTacOutput) := do
  let some (postNormGoal, postNormState) := goal.postNormGoalAndMetaState? | throwError
    "aesop: internal error: expected goal {goal.id} to be normalised (but not proven by normalisation)."
  let input := {
    goal := postNormGoal
    mvars := goal.mvars
    indexMatchLocations, branchState, options
  }
  runRuleTac tac ruleName postNormState input

private def mkNormRuleScriptStep (scriptBuilder : RuleTacScriptBuilder)
    (inGoal : MVarId) (outGoal? : Option GoalWithMVars) :
    MetaM UnstructuredScriptStep := do
  let tacticSeq ← scriptBuilder.unstructured.run
  let outGoals :=
    match outGoal? with
    | none => #[]
    | some g => #[g]
  return {
    otherSolvedGoals := #[]
    tacticSeq, inGoal, outGoals
  }

-- NOTE: Must be run in the MetaM context of the relevant goal.
def runNormRuleTac (bs : BranchState) (rule : NormRule) (input : RuleTacInput) :
    MetaM NormRuleResult := do
  let preMetaState ← saveState
  let result? ← runRuleTac rule.tac.run rule.name preMetaState input
  match result? with
  | Sum.inl e =>
    aesop_trace[stepsNormalization] "Rule failed with error:{indentD e.toMessageData}"
    return .failed
  | Sum.inr result =>
    let #[rapp] := result.applications
      | err m!"rule did not produce exactly one rule application."
    restoreState rapp.postState
    if rapp.goals.isEmpty then
      aesop_trace[stepsNormalization] "Rule proved the goal."
      let step ← mkNormRuleScriptStep rapp.scriptBuilder input.goal none
      return .proven step
    let (#[g]) := rapp.goals
      | err m!"rule produced more than one subgoal."
    let postBranchState := bs.update rule result.postBranchState?
    aesop_trace[stepsNormalization] do
      aesop_trace![stepsNormalization] "Rule succeeded. New goal:{indentD $ .ofGoal g}"
      aesop_trace[stepsBranchStates] "Branch state after rule application: {postBranchState.find? rule}"
    -- FIXME redundant computation?
    let mvars ← rapp.postState.runMetaM' g.getMVarDependencies
    let step ←
      mkNormRuleScriptStep rapp.scriptBuilder input.goal (some ⟨g, mvars⟩)
    return .succeeded g postBranchState step
  where
    err {α} (msg : MessageData) : MetaM α := throwError
      "aesop: error while running norm rule {rule.name}: {msg}\nThe rule was run on this goal:{indentD $ MessageData.ofGoal input.goal}"

-- NOTE: Must be run in the MetaM context of the relevant goal.
def runNormRuleCore (goal : MVarId) (mvars : UnorderedArraySet MVarId)
    (bs : BranchState) (options : Options) (rule : IndexMatchResult NormRule) :
    MetaM NormRuleResult := do
  let branchState := bs.find rule.rule
  aesop_trace[stepsNormalization] do
    aesop_trace![stepsNormalization] "Running {rule.rule}"
    aesop_trace[stepsBranchStates] "Branch state before rule application: {branchState}"
  let ruleInput := {
    indexMatchLocations := rule.locations
    goal, mvars, branchState, options
  }
  runNormRuleTac bs rule.rule ruleInput

-- NOTE: Must be run in the MetaM context of the relevant goal.
def runNormRule (goal : MVarId) (mvars : UnorderedArraySet MVarId)
    (bs : BranchState) (options : Options) (rule : IndexMatchResult NormRule) :
    ProfileT MetaM NormRuleResult :=
  profiling (runNormRuleCore goal mvars bs options rule) λ result elapsed => do
    let rule := RuleProfileName.rule rule.rule.name
    let ruleProfile := { elapsed, successful := result.isSuccessful, rule }
    recordAndTraceRuleProfile ruleProfile

-- NOTE: Must be run in the MetaM context of the relevant goal.
def runFirstNormRule (goal : MVarId) (mvars : UnorderedArraySet MVarId)
    (branchState : BranchState) (options : Options)
    (rules : Array (IndexMatchResult NormRule)) :
    ProfileT MetaM NormRuleResult := do
  for rule in rules do
    let result ← runNormRule goal mvars branchState options rule
    if result.isSuccessful then
      return result
  return .failed

def normSimpCore (ctx : NormSimpContext)
    (localSimpRules : Array LocalNormSimpRule) (goal : MVarId)
    (mvars : UnorderedArraySet MVarId) : MetaM SimpResult := do
  goal.withContext do
    let preState ← saveState
    let result ←
      if ctx.useHyps then
        Aesop.simpAll goal ctx.toContext (disabledTheorems := {})
      else
        let lctx ← getLCtx
        let mut simpTheorems := ctx.simpTheorems
        for localRule in localSimpRules do
          let (some ldecl) := lctx.findFromUserName? localRule.fvarUserName
            | continue
          let origin := Origin.fvar ldecl.fvarId
          let (some simpTheorems') ← observing? $
            simpTheorems.addTheorem origin ldecl.toExpr
            | continue
          simpTheorems := simpTheorems'
        let ctx := { ctx with simpTheorems }
        let mut fvarIdsToSimp := Array.mkEmpty lctx.decls.size
        for ldecl in lctx do
          -- TODO exclude non-prop and dependent hyps?
          if ldecl.isImplementationDetail then
            continue
          fvarIdsToSimp := fvarIdsToSimp.push ldecl.fvarId
        Aesop.simpGoal goal ctx (fvarIdsToSimp := fvarIdsToSimp)
          (disabledTheorems := {})

    -- It can happen that simp 'solves' the goal but leaves some mvars
    -- unassigned. In this case, we treat the goal as unchanged.
    if let .solved .. := result then
      let anyMVarDropped ← mvars.anyM (notM ·.isAssignedOrDelayedAssigned)
      if anyMVarDropped then
        aesop_trace[stepsNormalization] "Normalisation simp solved the goal but dropped some metavariables. Skipping normalisation simp."
        restoreState preState
        return .unchanged goal
      else
        return result
    return result

-- NOTE: Must be run in the MetaM context of the relevant goal.
def normSimp (goal : MVarId) (mvars : UnorderedArraySet MVarId)
    (ctx : NormSimpContext) (localSimpRules : Array LocalNormSimpRule) :
    ProfileT MetaM SimpResult :=
  profiling go λ _ elapsed =>
    recordAndTraceRuleProfile { rule := .normSimp, elapsed, successful := true }
  where
    go : MetaM SimpResult := do
      if ← Check.rules.isEnabled then
        let preMetaState ← saveState
        let result ← normSimpCore ctx localSimpRules goal mvars
        let postMetaState ← saveState
        let introduced :=
          (← getIntroducedExprMVars preMetaState postMetaState).filter
            (some · != result.newGoal?)
        unless introduced.isEmpty do throwError
          "{Check.rules.name}: norm simp introduced metas:{introduced.map (·.name)}"
        let assigned :=
          (← getAssignedExprMVars preMetaState postMetaState).filter (· != goal)
        unless assigned.isEmpty do throwError
          "{Check.rules.name}: norm simp assigned metas:{introduced.map (·.name)}"
        match result with
        | .unchanged newGoal =>
          if ← newGoal.isAssignedOrDelayedAssigned then throwError
            "{Check.rules.name}: norm simp reports unchanged goal but returned mvar {newGoal.name} is already assigned"
        | .simplified newGoal .. =>
          if ← newGoal.isAssignedOrDelayedAssigned then throwError
            "{Check.rules.name}: norm simp reports simplified goal but returned mvar {newGoal.name} is already assigned"
        | .solved .. =>
          if ! (← goal.isAssignedOrDelayedAssigned) then throwError
            "{Check.rules.name}: norm simp solved the goal but did not assign the goal metavariable {goal.name}"
        return result
      else
        normSimpCore ctx localSimpRules goal mvars

private def mkNormSimpScriptStep (ctx : NormSimpContext)
    (inGoal : MVarId) (outGoal? : Option GoalWithMVars)
    (usedTheorems : Simp.UsedSimps) :
    MetaM UnstructuredScriptStep := do
  let tactic ←
    mkNormSimpOnlySyntax inGoal ctx.useHyps ctx.configStx? usedTheorems
  return {
    tacticSeq := #[tactic]
    otherSolvedGoals := #[]
    outGoals := outGoal?.toArray
    inGoal
  }

-- NOTE: Must be run in the MetaM context of the relevant goal.
partial def normalizeGoalMVar (rs : RuleSet) (normSimpContext : NormSimpContext)
    (options : Options) (goal : MVarId) (mvars : UnorderedArraySet MVarId)
    (bs : BranchState) :
    ProfileT MetaM (Option (MVarId × BranchState) × UnstructuredScript) := do
  aesop_trace[steps] "Goal before normalisation:{indentD $ .ofGoal goal}"
  let (result?, script) ← go 0 goal bs #[]
  if let (some (goal, _)) := result? then
    aesop_trace[steps] "Goal after normalisation ({goal.name}):{indentD $ .ofGoal goal}"
  return (result?, script)
  where
    go (iteration : Nat) (goal : MVarId) (bs : BranchState)
       (script : UnstructuredScript) :
       ProfileT MetaM (Option (MVarId × BranchState) × UnstructuredScript) := do
      let maxIterations := options.maxNormIterations
      if maxIterations > 0 && iteration > maxIterations then throwError
        "aesop: exceeded maximum number of normalisation iterations ({maxIterations}). This means normalisation probably got stuck in an infinite loop."
      let rules ← selectNormRules rs goal
      let (preSimpRules, postSimpRules) :=
        rules.partition λ r => r.rule.extra.penalty < (0 : Int)
      -- TODO separate pre- and post-simp rules up front for efficiency?
      let preSimpResult ← runFirstNormRule goal mvars bs options preSimpRules
      match preSimpResult with
      | .proven scriptStep =>
        return (none, script.push scriptStep)
      | .succeeded outGoal bs scriptStep =>
        go (iteration + 1) outGoal bs (script.push scriptStep)
      | .failed =>
        let simpResult ←
          if normSimpContext.enabled then
            aesop_trace[stepsNormalization] "Running normalisation simp"
            normSimp goal mvars normSimpContext rs.localNormSimpLemmas
          else
            aesop_trace[stepsNormalization] "Skipping normalisation simp"
            pure (.unchanged goal)
        match simpResult with
        | .solved usedTheorems =>
          let scriptStep ←
            mkNormSimpScriptStep normSimpContext goal none usedTheorems
          return (none, script.push scriptStep)
        | .simplified goal' usedTheorems =>
          aesop_trace[stepsNormalization] "Goal after normalisation simp:{indentD $ MessageData.ofGoal goal}"
          let mvars' := .ofArray mvars.toArray
          let scriptStep ←
            mkNormSimpScriptStep normSimpContext goal (some ⟨goal', mvars'⟩)
              usedTheorems
          go (iteration + 1) goal' bs (script.push scriptStep)
        | .unchanged goal' =>
          aesop_trace[stepsNormalization] "Goal unchanged after normalisation simp."
          let mvars' := .ofArray mvars.toArray
          let script := script.push $ .dummy goal ⟨goal', mvars'⟩
          let postSimpResult ←
            runFirstNormRule goal' mvars bs options postSimpRules
          match postSimpResult with
          | .proven scriptStep =>
            return (none, script.push scriptStep)
          | .succeeded goal' bs scriptStep =>
            go (iteration + 1) goal' bs (script.push scriptStep)
          | .failed =>
            return (some (goal', bs), script)

-- Returns true if the goal was solved by normalisation.
def normalizeGoalIfNecessary (gref : GoalRef) : SearchM Q Bool := do
  let g ← gref.get
  match g.normalizationState with
  | .provenByNormalization .. => return true
  | .normal .. => return false
  | .notNormal => pure ()
  aesop_trace[steps] "Normalising the goal"
  let ctx ← read
  let profilingEnabled ← isProfilingEnabled
  let profile ← getThe Profile
  let (((normResult?, script), profile), postState) ←
    (← gref.get).runMetaMInParentState do
      normalizeGoalMVar ctx.ruleSet ctx.normSimpContext ctx.options
        g.preNormGoal g.mvars g.branchState
      |>.run profilingEnabled profile
  modify λ s => { s with profile }
  match normResult? with
  | some (postGoal, postBranchState) =>
    gref.modify λ g =>
      g.setNormalizationState (.normal postGoal postState script)
      |>.setBranchState postBranchState
    return false
  | none =>
    aesop_trace[steps] "Normalisation solved the goal"
    gref.modify λ g =>
      g.setNormalizationState (.provenByNormalization postState script)
    gref.markProvenByNormalization
    return true

def addRapps (parentRef : GoalRef) (rule : RegularRule)
    (rapps : Array RuleApplicationWithMVarInfo)
    (postBranchState? : Option RuleBranchState) : SearchM Q RuleResult := do
  let parent ← parentRef.get
  let postBranchState :=
    rule.withRule λ r => parent.branchState.update r postBranchState?
  aesop_trace[stepsBranchStates] "Updated branch state: {rule.withRule λ r => postBranchState.find? r}"
  let successProbability := parent.successProbability * rule.successProbability

  let mut rrefs := Array.mkEmpty rapps.size
  let mut subgoals := Array.mkEmpty $ rapps.size * 3
  for h : i in [:rapps.size] do
    let rapp := rapps[i]'(by simp_all [Membership.mem])
    let rref ← addRapp {
      rapp with
      parent := parentRef
      appliedRule := rule
      branchState := postBranchState
      successProbability }
    rrefs := rrefs.push rref
    for cref in (← rref.get).children do
      for gref in (← cref.get).goals do
        subgoals := subgoals.push gref

  enqueueGoals subgoals
  rrefs.forM (·.markProven)
    -- `markProven` is a no-op if the rapp is not, in fact, proven. We must
    -- perform this computation after all rapps have been added to ensure
    -- that if one is proven, the others are all marked as irrelevant.

  aesop_trace[steps] do
    let traceMods ← TraceModifiers.get
    let rappMsgs ← rrefs.mapM λ rref => do
      let r ← rref.get
      let rappMsg ← r.toMessageData
      let subgoalMsgs ← r.foldSubgoalsM (init := #[]) λ msgs gref =>
        return msgs.push (← (← gref.get).toMessageData traceMods)
      return rappMsg ++ MessageData.node subgoalMsgs
    aesop_trace![steps] "New rapps and goals:{MessageData.node rappMsgs}"

  let provenRref? ← rrefs.findM? λ rref => return (← rref.get).state.isProven
  if let (some _) := provenRref? then
    aesop_trace[steps] "One of the rule applications has no subgoals. Goal is proven."
    return RuleResult.proven
  else
    return RuleResult.succeeded

def runRegularRuleCore (parentRef : GoalRef) (rule : RegularRule)
    (indexMatchLocations : UnorderedArraySet IndexMatchLocation) :
    SearchM Q RuleResult := do
  let parent ← parentRef.get
  let initialBranchState := rule.withRule λ r => parent.branchState.find r
  aesop_trace[stepsBranchStates] "Initial branch state: {initialBranchState}"
  let ruleOutput? ←
    runRegularRuleTac parent rule.tac.run rule.name indexMatchLocations
      initialBranchState (← read).options
  match ruleOutput? with
  | Sum.inl exc => onFailure exc.toMessageData
  | Sum.inr { applications := #[], .. } =>
    onFailure "Rule returned no rule applications."
  | Sum.inr output =>
    let rapps ← output.applications.mapM
      (·.toRuleApplicationWithMVarInfo parent.mvars)
    if let (.safe rule) := rule then
      if rapps.size != 1 then
        return ← onFailure "Safe rule did not produce exactly one rule application. Treating it as failed."
      if rapps.any (! ·.assignedMVars.isEmpty) then
        aesop_trace[steps] "Safe rule assigned metavariables. Postponing it."
        return RuleResult.postponed ⟨rule, output⟩
    aesop_trace[steps] "Rule succeeded, producing {rapps.size} rule application(s)."
    addRapps parentRef rule rapps output.postBranchState?
  where
    onFailure (msg : MessageData) : SearchM Q RuleResult := do
      aesop_trace[stepsRuleFailures] "Rule failed with message:{indentD msg}"
      parentRef.modify λ g => g.setFailedRapps $ g.failedRapps.push rule
      return RuleResult.failed

def runRegularRule (parentRef : GoalRef) (rule : RegularRule)
    (indexMatchLocations : UnorderedArraySet IndexMatchLocation) :
    SearchM Q RuleResult :=
  profiling (runRegularRuleCore parentRef rule indexMatchLocations)
    λ result elapsed => do
      let successful :=
        match result with
        | .failed => false
        | .succeeded => true
        | .proven => true
        | .postponed .. => true
      let rule := RuleProfileName.rule rule.name
      recordAndTraceRuleProfile { rule, elapsed, successful }

-- Never returns `RuleResult.postponed`.
def runFirstSafeRule (gref : GoalRef) :
    SearchM Q (RuleResult × Array PostponedSafeRule) := do
  let g ← gref.get
  if g.unsafeRulesSelected then
    return (RuleResult.failed, #[])
    -- If the unsafe rules have been selected, we have already tried all the
    -- safe rules.
  let rules ← selectSafeRules g
  aesop_trace[steps] "Selected safe rules:{MessageData.node $ rules.map toMessageData}"
  aesop_trace[steps] "Trying safe rules"
  let mut postponedRules := {}
  for r in rules do
    aesop_trace[steps] "Trying {r.rule}"
    let result' ←
      runRegularRule gref (.safe r.rule) r.locations
    match result' with
    | .failed => continue
    | .proven => return (result', #[])
    | .succeeded => return (result', #[])
    | .postponed r =>
      postponedRules := postponedRules.push r
  return (RuleResult.failed, postponedRules)

partial def runFirstUnsafeRule (postponedSafeRules : Array PostponedSafeRule)
    (parentRef : GoalRef) : SearchM Q Unit := do
  let queue ← selectUnsafeRules postponedSafeRules parentRef
  aesop_trace[steps] "Trying unsafe rules"
  let (remainingQueue, _) ← loop queue
  parentRef.modify λ g => g.setUnsafeQueue remainingQueue
  aesop_trace[steps] "Remaining unsafe rules:{MessageData.node remainingQueue.entriesToMessageData}"
  if remainingQueue.isEmpty then
    if (← parentRef.get).state.isProven then
      return
    if ← (← parentRef.get).isUnprovableNoCache then
      aesop_trace[steps] "Goal is unprovable."
      parentRef.markUnprovable
    else
      aesop_trace[steps] "All rules applied, goal is exhausted."
  where
    loop (queue : UnsafeQueue) : SearchM Q (UnsafeQueue × RuleResult) := do
      let (some (r, queue)) := queue.popFront?
        | return (queue, RuleResult.failed)
      match r with
      | .unsafeRule r =>
        aesop_trace[steps] "Trying {r.rule}"
        let result ←
          runRegularRule parentRef (.«unsafe» r.rule) r.locations
        match result with
        | .proven => return (queue, result)
        | .succeeded => return (queue, result)
        | .postponed .. => throwError
          "aesop: internal error: applying an unsafe rule yielded a postponed safe rule."
        | .failed => loop queue
      | .postponedSafeRule r =>
        aesop_trace[steps] "Applying postponed safe rule {r.rule}"
        let parentMVars := (← parentRef.get).mvars
        let postBranchState? := r.output.postBranchState?
        let rapps ← r.output.applications.mapM
          (·.toRuleApplicationWithMVarInfo parentMVars)
        let result ←
          addRapps parentRef (.«unsafe» r.toUnsafeRule) rapps postBranchState?
        return (queue, result)

def expandGoal (gref : GoalRef) : SearchM Q Unit := do
  if ← normalizeGoalIfNecessary gref then
    -- Goal was already proven by normalisation.
    return
  let (safeResult, postponedSafeRules) ← runFirstSafeRule gref
  unless safeResult.isSuccessful do
    runFirstUnsafeRule postponedSafeRules gref

end Aesop
