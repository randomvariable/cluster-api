---
title: Bootstrap Node Agent
authors:
  - "@randomvariable"
  - "@detiber"
reviewers:
  - "@ncdc"
  - "vincepri"
creation-date: yyyy-mm-dd
last-updated: yyyy-mm-dd
status: provisional|experimental|implementable|implemented|deferred|rejected|withdrawn|replaced
see-also:
  - "/docs/proposals/20190101-we-heard-you-like-proposals.md"
  - "/docs/proposals/20190102-everyone-gets-a-proposal.md"
replaces:
  - "/docs/proposals/20181231-replaced-proposal.md"
superseded-by:
  - "/docs/proposals/20190104-superceding-proposal.md"
---
# Bootstrap Node Agent

## Table of Contents

A table of contents is helpful for quickly jumping to sections of a proposal and for highlighting
any additional information provided beyond the standard proposal template.
[Tools for generating](https://github.com/ekalinin/github-markdown-toc) a table of contents from markdown are available.

- [Bootstrap Node Agent](#bootstrap-node-agent)
  - [Table of Contents](#table-of-contents)
  - [Glossary](#glossary)
  - [Summary](#summary)
  - [Motivation](#motivation)
      - [Prior Github issues](#prior-github-issues)
    - [Goals](#goals)
    - [Non-Goals/Future Work](#non-goalsfuture-work)
  - [Proposal](#proposal)
      - [User Experience Reports](#user-experience-reports)
      - [Story 1](#story-1)
  - [Requirements](#requirements)
    - [Functional](#functional)
    - [Non-Functional](#non-functional)
    - [Implementation Details/Notes/Constraints](#implementation-detailsnotesconstraints)
      - [Mechanisms to create](#mechanisms-to-create)
      - [Constraints](#constraints)
    - [Risks and Mitigations](#risks-and-mitigations)
  - [Upgrade Strategy](#upgrade-strategy)
  - [Additional Details](#additional-details)
    - [Test Plan [optional]](#test-plan-optional)
    - [Graduation Criteria [optional]](#graduation-criteria-optional)
    - [Version Skew Strategy [optional]](#version-skew-strategy-optional)
  - [Implementation History](#implementation-history)

## Glossary

Refer to the [Cluster API Book Glossary](https://cluster-api.sigs.k8s.io/reference/glossary.html).

If this proposal adds new terms, or defines some, make the changes to the book's glossary when in PR stage.

## Summary

We propose the creation of a bootstrap node agent to be either pre-installed in images,
downloaded on first-boot, or ran as daemonset that will in the first instance provide
node reporting to the management cluster.

## Motivation


#### Prior Github issues
  - [Cloud-init failure detection in AWS][aws-issue]
  - [Failure detection in vSphere][vsphere-issue]


### Goals

- To assist consumers and users as to why a bootstrap failure occurred

### Non-Goals/Future Work

- To change Kubernetes components such as kubeadm, kubelet or API server.
- To replace the current cluster bootstrapping process using cloud-init
  in the immediate future.

## Proposal

#### User Experience Reports
- https://github.com/kubernetes-sigs/cluster-api-provider-aws/issues/972

#### Story 1

A cluster operator runs a Cluster As A Service in an organisation.

One of the development teams provisions a workload cluster, but are unable to successfully
connect to the cluster, so ask the cluster operator to investigate. They discover the 2nd node
didn't join the cluster, even though the cluster reported a Ready status.

A kubeconfig was retrievable. To find out what happened, the operator
proxies an SSH connection in AWS EC2 to the failed node and reviews `journalctl -u cloud-final`,
`/var/log/cloud-init-output.log` and `journalctl -u kubelet`.

After scouring these logs, they discover that the DNS resolution of the API
server took too long and they increased the node join timeout.

The cluster operator wants an easier way to find out what happened, especially
if they decide to turn off the bastion instance creation in the future.

## Requirements

### Functional

<a name="FR1">FR1.</a> The design MUST include the

### Non-Functional

<a name="NFR1">NFR1.</a> The design MUST not prohibit the development of
implementations across Linux distributions and operating systems.

<a name="NFR2">NFR2.</a> The design MUST not break the assumption of one-way
communication from the management cluster to workload cluster for successful
cluster creation.

<a name="NFR3">NFR3.</a> The design MAY require 2-way communications between management
and workload clusters for non-critical features.


### Implementation Details/Notes/Constraints

#### Mechanisms to create

We can broadly characterise the mechanisms that need to be provided by bootstrap
failure detection into the following four areas:

**1. Data collection**

<em>**Service manager signals**</em>

All Linux based images within the image-builder project support SystemD.

Libraries such as [go-systemd][go-systemd], provide the ability to
programatically interact with SystemD. For Windows, Service Manager
support is included in [golang.org/x][mgr].

However, not all distributions use SystemD, and an escape hatch should be
provided for those systems, including Fedora CoreOS ([Ignition][Ignition]), [Talos][Talos], and Alpine ([OpenRC][OpenRC]).

<em>**Serial port redirection**</em>

Many cloud providers, including AWS, Azure and vSphere provide provision for
scraping console output when it is redirected to a specific COM port, typically
by setting `console=ttyS0,9600` on the [Linux kernel command line][Linux serial console].

For Windows, serial port redirection is only supported for [Emergency Management
Services][Windows-EMS]. The [Special Administration Console][SAC] is designed
as an interactive, session-based tool, which is not usable on read-only systems
such as AWS EC2.

<em>**Logs**</em>

In [user story 1](#story-1), the cluster operator trawled through a number of
log files in order to determine the root cause of the issue. At the very minimum,
the gathering mechanism must include the ability to scrape appropriate logs.

On Linux, these include selected files from `/var/log` as well as the SystemD
journal, support for which is included in [go-systemd][go-systemd].

For Windows, most logs go into the Event Log, presented via two Win32 APIs, the older Event Logging API includes access
to three logs called `Application`, `System` and `Security`, and the newer [Event Tracing for Windows (ETW) API][etw]
supporting much finer granularity, structured data and arbitrary log locations at high throughput and low latency.
Microsoft provide a [Golang package for ETW][go-etw].

<em>**Status endpoints**</em>

For Kubernetes clusters, there are two daemons in particular that we care about,
`kubelet` and the container runtime. `kubelet` can be expected to be always present,
but the container runtime is variable, though its UNIX socket can be inferred from
kubeadm configuration.

Kubelet provides a `/healthz` endpoint providing a HTTP 200. However, this appears
too late to be useful for the use case of determining what caused a bootstrap to fail.

In addition, Kubelet has a `/metrics` endpoint presenting OpenMetrics. However, we were
not able to determine any clear signal useful for diagnosing bootstrap failures.

No clear signals were found in the list of metrics exposed by containerd.

**2. Data communication and security**

<em>**Write-back to management cluster**</em>

Having a process on a workload cluster machine write back to a presupposed
resource in the management cluster allows bubbles information up to
consumers using the top-level resources.

However, RBAC is tricky - in order to scope access to a particular resource,
say a Machine object, or maybe a ConfigMap, would require a separate RBAC
role. Depending on the targeted resource, this can open up privilege escalation
scenarios.

Additionally, this approach fundamentally requires connectivity back to the management cluster.

<em>**Provider-specific messaging service**</em>

Cloud providers such as AWS, Azure and GCP provide Pub/Sub systems that could
allow respective infrastructure providers to communicate data across network
boundaries.

For example, Cluster API Provider AWS could create a SQS queue and SNS topic,
and inject the SNS topic into the bootstrap userdata. The reporting agent
would then publish the relevant data to SNS (and where the data is larger to
256KB, push onto a known S3 bucket with a ARN reference being published). CAPA would then pick the message and interpret it as required.

Although implementable, this would place two constraints on the design:

* A pluggable model for provider specific publishing.
* A contract to be implemented by each infrastructure provider.

Furthermore, this does not immediately resolve the issue for environments
without a readily-available message queue service. A default implementation
could be made using a service like NATS, but this would defeat the purpose
of using an infrastructure provider messaging service to bypass network
requirements.

<em>**Direct terminal access to node**</em>

An agent, running either in the workload or management cluster could directly
execute commands on the node using either SSH, [WinRM][winrm] or an infrastructure
provider specific service such as [AWS Systems Manager][aws-systems-manager].

For non infrastructure-provider specific services, direct connectivity would be
required between whereever the agent is running and the target machine, though
in the case of a successfully registered machine, the connection could potentially
be proxied via the kubelet.

The agent would necessarily be extremely privileged, having root access on all
provisioned nodes, presenting a security risk if implemented.

<em>**Proxy to workload cluster**</em>

Where agents are running on the workload cluster, particularly when run as
either a static pod or daemonset, it would be possible to reuse the proxy
mechanisms used by KubeadmControlPlane to connect to etcd to be able to
connect to the running agent.

This presumes a working kubelet instance.

**3. Data presentation**

<em>**Log shipping**</em>

Given a set of logs that a process scrapes on the workload cluster, we could
simply ship these logs back to the management cluster. However, storing these
as events on the Machine object in Kubernetes must be ruled out because of
the impact on etcd performance.

If raw logs are to be presented to end users, then this must be done through
either proxying directly from the node, or via a separate storage mechanism
and API.

<em>**Conditions and Log parsing**</em>

Most downstream consumers, as in [User Story 1](#story-1), would want a much
simpler way to determine what happened to the machine instead of having to trawl
through the logs on their own.

In this case, log parsing would be required in order to determine what things
occurred on the machine that maybe of interest to the consumer.

Log parsing is often a pain to do correctly, however, some may seem unavoidable.

**4. Agent deployment**

Given all methods of data collection except serial port redirection would require
an agent to be running on the machine, a mechanism to get it on the node and
running is required.

<em>**Include in image**</em>

The default bootstrap implementation in Cluster API requires images to be
pre-seeded with kubeadm, containerd and kubelet. It would therefore not
present a different challenge to also include the agent in the node image.

<em>**Download on first boot**</em>

Using the existing cloud-init and related mechanisms, a script could be deployed
to download the agent, install and run it. This is the approach taken by [nodeup][nodeup] in Kops.

<em>**Deploy as static pod**</em>

In this method, the agent is deployed and made to run during kubeadm init or
join. This presupposes a working kubelet, container runtime, and where
images are not preloaded, connectivity to the container registry but is
potentially independent of a running control plane.

<em>**Deploy as daemonset**</em>

Daemonset deployment would be a pure post-apply operation to the workload
cluster after it has successfully booted. This is the simplest approach,
but reduces the scope of possible reportable statuses to those of a near-fully
working node.

#### Constraints

**Management to Workload Cluster Connectivity**

All Cluster API providers work on the assumption that communication from the
workload cluster to the management cluster is not possible. This is particularly
true in the bootstrap scenario as when running in the context of a user workstation,
there is not inbound connectivity to the workstation from the cloud provider.

Therefore any solution must NOT interfere with the successful path of cluster
bootstrapping.

### Risks and Mitigations

- What are the risks of this proposal and how do we mitigate? Think broadly.
- How will UX be reviewed and by whom?
- How will security be reviewed and by whom?
- Consider including folks that also work outside the SIG or subproject.

## Upgrade Strategy

If applicable, how will the component be upgraded? Make sure this is in the test plan.

Consider the following in developing an upgrade strategy for this enhancement:
- What changes (in invocations, configurations, API use, etc.) is an existing cluster required to make on upgrade in order to keep previous behavior?
- What changes (in invocations, configurations, API use, etc.) is an existing cluster required to make on upgrade in order to make use of the enhancement?

## Additional Details

### Test Plan [optional]

**Note:** *Section not required until targeted at a release.*

Consider the following in developing a test plan for this enhancement:
- Will there be e2e and integration tests, in addition to unit tests?
- How will it be tested in isolation vs with other components?

No need to outline all of the test cases, just the general strategy.
Anything that would count as tricky in the implementation and anything particularly challenging to test should be called out.

All code is expected to have adequate tests (eventually with coverage expectations).
Please adhere to the [Kubernetes testing guidelines][testing-guidelines] when drafting this test plan.

[testing-guidelines]: https://git.k8s.io/community/contributors/devel/sig-testing/testing.md

### Graduation Criteria [optional]

**Note:** *Section not required until targeted at a release.*

Define graduation milestones.

These may be defined in terms of API maturity, or as something else. Initial proposal should keep
this high-level with a focus on what signals will be looked at to determine graduation.

Consider the following in developing the graduation criteria for this enhancement:
- [Maturity levels (`alpha`, `beta`, `stable`)][maturity-levels]
- [Deprecation policy][deprecation-policy]

Clearly define what graduation means by either linking to the [API doc definition](https://kubernetes.io/docs/concepts/overview/kubernetes-api/#api-versioning),
or by redefining what graduation means.

In general, we try to use the same stages (alpha, beta, GA), regardless how the functionality is accessed.

[maturity-levels]: https://git.k8s.io/community/contributors/devel/sig-architecture/api_changes.md#alpha-beta-and-stable-versions
[deprecation-policy]: https://kubernetes.io/docs/reference/using-api/deprecation-policy/

### Version Skew Strategy [optional]

If applicable, how will the component handle version skew with other components? What are the guarantees? Make sure
this is in the test plan.

Consider the following in developing a version skew strategy for this enhancement:
- Does this enhancement involve coordinating behavior in the control plane and in the kubelet? How does an n-2 kubelet without this feature available behave when this feature is used?
- Will any other components on the node change? For example, changes to CSI, CRI or CNI may require updating that component before the kubelet.

## Implementation History

- [ ] MM/DD/YYYY: Proposed idea in an issue or [community meeting]
- [ ] MM/DD/YYYY: Compile a Google Doc following the CAEP template (link here)
- [ ] MM/DD/YYYY: First round of feedback from community
- [ ] MM/DD/YYYY: Present proposal at a [community meeting]
- [ ] MM/DD/YYYY: Open proposal PR

<!-- Links -->
[aws-issue]: https://github.com/kubernetes-sigs/cluster-api-provider-aws/issues/972
[vsphere-issue]: https://github.com/kubernetes-sigs/cluster-api-provider-vsphere/issues/912
[go-systemd]: https://github.com/coreos/go-systemd
[mgr]: https://pkg.go.dev/golang.org/x/sys/windows/svc/mgr
[Talos]: https://github.com/talos-systems/talos
[Ignition]: https://github.com/coreos/ignition
[OpenRC]: https://wiki.gentoo.org/wiki/OpenRC
[Linux Serial Console]: https://www.kernel.org/doc/html/latest/admin-guide/serial-console.html
[Windows-EMS]: https://docs.microsoft.com/en-gb/windows-hardware/drivers/devtest/boot-parameters-to-enable-ems-redirection?redirectedfrom=MSDN
[SAC]: https://docs.microsoft.com/en-us/previous-versions/windows/it-pro/windows-server-2003/cc787940(v=ws.10)?redirectedfrom=MSDN
[go-etw]: https://pkg.go.dev/github.com/microsoft/go-winio/pkg/etw
[etw]: https://docs.microsoft.com/en-us/windows/win32/etw/event-tracing-portal
[nodeup]: https://github.com/kubernetes/kops/blob/master/pkg/model/resources/nodeup.go
[aws-systems-manager]: https://aws.amazon.com/systems-manager/
[winrm]: https://github.com/masterzen/winrm
