// Copyright 2026 The Kubernetes Authors.
//
// PropagationPolicyMismatch.qnt — issue #97 (FM-97).
//
// Client deletes a Cluster with PropagationPolicy=Foreground.
// CAPI controller uses Background by default in some paths.
// Children are deleted asynchronously; the operator believes
// synchronous behaviour and observes a partial state.

module PropagationPolicyMismatch {

  type Policy = Foreground | Background | Orphan
  type ChildState = Live | Deleting | Deleted

  pure val CHILDREN: Set[str] = Set("KCP", "MachineDeployment", "Secret")

  var operatorRequestedPolicy: Policy
  var controllerActualPolicy: Policy
  var parentDeleting: bool
  var childState: str -> ChildState

  action init = all {
    operatorRequestedPolicy' = Foreground,
    controllerActualPolicy' = Foreground,
    parentDeleting' = false,
    childState' = CHILDREN.mapBy(_ => Live),
  }

  action OperatorDeletesParent(p: Policy): bool = all {
    operatorRequestedPolicy' = p,
    parentDeleting' = true,
    controllerActualPolicy' = controllerActualPolicy,
    childState' = childState,
  }

  // The bug: controller hardcodes its policy and ignores
  // operatorRequestedPolicy.
  action ControllerStartsDeletion(p: Policy): bool = all {
    parentDeleting,
    controllerActualPolicy' = p,
    operatorRequestedPolicy' = operatorRequestedPolicy,
    parentDeleting' = parentDeleting,
    childState' = childState,
  }

  action DeleteChild(c: str): bool = all {
    CHILDREN.contains(c),
    parentDeleting,
    childState.get(c) == Live,
    childState' = childState.put(c, Deleting),
    operatorRequestedPolicy' = operatorRequestedPolicy,
    controllerActualPolicy' = controllerActualPolicy,
    parentDeleting' = parentDeleting,
  }

  action FinaliseChild(c: str): bool = all {
    CHILDREN.contains(c),
    childState.get(c) == Deleting,
    childState' = childState.put(c, Deleted),
    operatorRequestedPolicy' = operatorRequestedPolicy,
    controllerActualPolicy' = controllerActualPolicy,
    parentDeleting' = parentDeleting,
  }

  action step = any {
    OperatorDeletesParent(Foreground),
    OperatorDeletesParent(Background),
    ControllerStartsDeletion(Background),
    ControllerStartsDeletion(Foreground),
    nondet c = CHILDREN.oneOf(); DeleteChild(c),
    nondet c = CHILDREN.oneOf(); FinaliseChild(c),
  }

  // Positive invariant: the controller's actual policy matches
  // the operator's requested policy.
  val OperatorObservedPolicyMatchesActual =
    not(parentDeleting) or operatorRequestedPolicy == controllerActualPolicy

  // Counterexample: operator asks Foreground, controller uses Background.
  run policyMismatchRun = init
    .then(OperatorDeletesParent(Foreground))
    .then(ControllerStartsDeletion(Background))
    // OperatorObservedPolicyMatchesActual is false.

  run policyMatchRun = init
    .then(OperatorDeletesParent(Foreground))
    .then(ControllerStartsDeletion(Foreground))
}
