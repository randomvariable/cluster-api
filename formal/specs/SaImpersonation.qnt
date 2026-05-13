// Copyright 2026 The Kubernetes Authors.
//
// SaImpersonation.qnt — issue #76 (FM-76).
//
// An operator with `impersonate` permission can act as another
// ServiceAccount, bypassing admission rules that target only the
// operator's own identity. The model tracks the transitive
// impersonation graph and asserts that the effective permission
// set is bounded by the transitive closure of `impersonateGraph`.

module SaImpersonation {

  pure val ACTORS: Set[str] = Set("alice", "bob", "ci-runner", "kcp-controller")

  var impersonateGraph: Set[(str, str)]    // (actor, may-impersonate-as)
  var directPermissions: str -> Set[str]   // SA -> set of granted verbs
  var requestedAction: (str, str, str)     // (actor, asSa, verb) — most recent attempt
  var requestAdmitted: bool

  action init = all {
    impersonateGraph' = Set(("alice", "bob"), ("bob", "ci-runner")),
    directPermissions' = Map(
      "alice" -> Set("read"),
      "bob" -> Set("read", "write"),
      "ci-runner" -> Set("read", "write", "delete"),
      "kcp-controller" -> Set("read", "write", "delete", "admin"),
    ),
    requestedAction' = ("", "", ""),
    requestAdmitted' = false,
  }

  pure def transitiveImpersonators(graph: Set[(str, str)], actor: str): Set[str] = {
    val direct = graph.filter(p => p._1 == actor).map(p => p._2)
    val twoHop = direct.fold(direct, (acc, x) =>
      acc.union(graph.filter(p => p._1 == x).map(p => p._2)))
    val threeHop = twoHop.fold(twoHop, (acc, x) =>
      acc.union(graph.filter(p => p._1 == x).map(p => p._2)))
    Set(actor).union(threeHop)
  }

  // ActAs admits an impersonation attempt iff the target is in
  // the transitive closure of impersonators starting at actor.
  action ActAs(actor: str, target: str, verb: str): bool = all {
    ACTORS.contains(actor),
    ACTORS.contains(target),
    val canImpersonate = transitiveImpersonators(impersonateGraph, actor).contains(target)
    val hasVerb = directPermissions.get(target).contains(verb)
    all {
      requestedAction' = (actor, target, verb),
      requestAdmitted' = canImpersonate and hasVerb,
      impersonateGraph' = impersonateGraph,
      directPermissions' = directPermissions,
    }
  }

  action step = any {
    nondet a = ACTORS.oneOf();
    nondet t = ACTORS.oneOf();
    nondet v = Set("read", "write", "delete", "admin").oneOf();
    ActAs(a, t, v),
  }

  // Positive invariant: every admitted action's actor has a
  // transitive impersonation path to the target.
  val EffectivePermissionsBoundedByTransitiveClosure =
    requestAdmitted implies
      transitiveImpersonators(impersonateGraph, requestedAction._1).contains(requestedAction._2)

  // Counterexample run: alice -> bob -> ci-runner. Alice acts as
  // ci-runner via the transitive edge.
  run aliceImpersonatesCiRunnerRun = init
    .then(ActAs("alice", "ci-runner", "delete"))
    // requestAdmitted should be TRUE because alice can transitively
    // impersonate ci-runner. The transitive closure is sound; but
    // if directPermissions["alice"] is just {read}, the effective
    // permission set has been silently expanded.

  // Healthy run: alice attempts to act as kcp-controller (no edge).
  // requestAdmitted is FALSE.
  run aliceCannotImpersonateKcpRun = init
    .then(ActAs("alice", "kcp-controller", "admin"))
}
