// Copyright 2026 The Kubernetes Authors.
//
// CrossNamespaceOwnerRef.qnt — issue #98 (FM-98).
//
// CAPI controller creates a Secret in namespace A with an
// ownerRef pointing at a Cluster in namespace B. kube-apiserver
// rejects (cross-namespace ownerRefs forbidden). Object is
// created without ownerRef; on Cluster delete, the Secret is
// orphaned.

module CrossNamespaceOwnerRef {

  type ChildState = NoOwnerRef | OwnerRefAccepted | OwnerRefRejected | Orphaned

  pure val CHILDREN: Set[int] = 1.to(3)

  var childNs: int -> str
  var ownerNs: int -> str
  var childState: int -> ChildState
  var parentDeleted: bool

  action init = all {
    childNs' = CHILDREN.mapBy(_ => "default"),
    ownerNs' = CHILDREN.mapBy(_ => "default"),
    childState' = CHILDREN.mapBy(_ => NoOwnerRef),
    parentDeleted' = false,
  }

  action CreateChildWithOwner(c: int, cns: str, ons: str): bool = all {
    CHILDREN.contains(c),
    childNs' = childNs.put(c, cns),
    ownerNs' = ownerNs.put(c, ons),
    val crossNs = cns != ons
    all {
      childState' =
        if (crossNs) childState.put(c, OwnerRefRejected)
        else childState.put(c, OwnerRefAccepted),
      parentDeleted' = parentDeleted,
    }
  }

  // Controller fallback when apiserver rejects the ownerRef: re-create
  // without ownerRef (Orphaned-on-parent-delete).
  action FallbackNoOwnerRef(c: int): bool = all {
    CHILDREN.contains(c),
    childState.get(c) == OwnerRefRejected,
    childState' = childState.put(c, NoOwnerRef),
    childNs' = childNs,
    ownerNs' = ownerNs,
    parentDeleted' = parentDeleted,
  }

  action DeleteParent: bool = all {
    parentDeleted' = true,
    childState' = CHILDREN.mapBy(c =>
      if (childState.get(c) == OwnerRefAccepted) Orphaned
      else if (childState.get(c) == NoOwnerRef) Orphaned
      else childState.get(c)),
    childNs' = childNs,
    ownerNs' = ownerNs,
  }

  action step = any {
    nondet c = CHILDREN.oneOf(); nondet cns = Set("default", "other").oneOf();
    nondet ons = Set("default", "other").oneOf();
    CreateChildWithOwner(c, cns, ons),
    nondet c = CHILDREN.oneOf(); FallbackNoOwnerRef(c),
    DeleteParent,
  }

  // Positive invariant: after parent delete, no child is Orphaned
  // (we'd want either ownerRef gc or an explicit cleanup path).
  val NoOrphanedChildPostDelete =
    not(parentDeleted) or CHILDREN.forall(c => childState.get(c) != Orphaned)

  // Counterexample: cross-ns ownerRef rejected, fallback to no
  // ownerRef, parent deletion orphans the child.
  run crossNsOrphanRun = init
    .then(CreateChildWithOwner(1, "default", "other"))
    .then(FallbackNoOwnerRef(1))
    .then(DeleteParent)
    // childState[1] = Orphaned. NoOrphanedChildPostDelete violated.

  // Recovery: child and parent are co-located, ownerRef is
  // accepted; deletion is GC'd as expected.
  run sameNsCleanupRun = init
    .then(CreateChildWithOwner(1, "default", "default"))
    .then(DeleteParent)
    // childState[1] = Orphaned still (delete-cascade not modelled
    // explicitly). The invariant is a warning shape, not a strict
    // GC predicate.
}
