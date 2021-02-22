---
title: Cluster API Machine Bootstrapper
authors:
  - "@randomvariable"
  - "@yastij"
reviewers:
  - "@fpandini"
creation-date: 2021-02-22
last-updated: 2021-02-22
status: provisional
see-also:
  - "/docs/proposals/2021022-kubelet-authentication-plugin.md"
  - "/docs/proposals/2021022-artifacts-management.md"
---

# Title
- Keep it simple and descriptive.
- A good title can help communicate what the proposal is and should be considered as part of any review.

<!-- BEGIN Remove before PR -->
To get started with this template:
1. **Make a copy of this template.**
  Copy this template into `docs/enhacements` and name it `YYYYMMDD-my-title.md`, where `YYYYMMDD` is the date the proposal was first drafted.
1. **Fill out the required sections.**
1. **Create a PR.**
  Aim for single topic PRs to keep discussions focused.
  If you disagree with what is already in a document, open a new PR with suggested changes.

The canonical place for the latest set of instructions (and the likely source of this file) is [here](/docs/proposals/YYYYMMDD-template.md).

The `Metadata` section above is intended to support the creation of tooling around the proposal process.
This will be a YAML section that is fenced as a code block.
See the proposal process for details on each of these items.

<!-- END Remove before PR -->

## Table of Contents

A table of contents is helpful for quickly jumping to sections of a proposal and for highlighting
any additional information provided beyond the standard proposal template.
[Tools for generating](https://github.com/ekalinin/github-markdown-toc) a table of contents from markdown are available.

- [Title](#title)
  - [Table of Contents](#table-of-contents)
  - [Glossary](#glossary)
  - [Summary](#summary)
  - [Motivation](#motivation)
    - [Goals](#goals)
    - [Non-Goals/Future Work](#non-goalsfuture-work)
  - [Proposal](#proposal)
    - [User Stories](#user-stories)
    - [Requirements Specification](#requirements-specification)
    - [Implementation Details/Notes/Constraints](#implementation-detailsnotesconstraints)
    - [Security Model](#security-model)
    - [Risks and Mitigations](#risks-and-mitigations)
  - [Alternatives](#alternatives)
  - [Upgrade Strategy](#upgrade-strategy)
  - [Additional Details](#additional-details)
    - [Test Plan [optional]](#test-plan-optional)
    - [Graduation Criteria [optional]](#graduation-criteria-optional)
    - [Version Skew Strategy [optional]](#version-skew-strategy-optional)
  - [Implementation History](#implementation-history)

## Glossary

* OS Distribution: An OS Distribution refers to a packaged version of an Operating System, in order to primarily distinguish between different Linux distributions such as CentOS vs. Ubuntu vs. Talos, as opposed to differences between Operating Systems as a whole (e.g. Linux and Windows).
* Machineadm : Is a binary CLI that is executed on machines to perform Kubernetes Cluster API bootstrap.
* CABPK: Cluster API Bootstrap Provider Kubeadm is the bootstrap controller that exists from v1alpha2 onwards and generates cloud-init bootstrap data to execute kubeadm for a machine provisioned by Cluster API
* Cloud-Init: Is a first-boot bootstrapper written by Canonical and is widely used across Ubuntu, Amazon Linux 2, and VMware PhotonOS
* Cloudbase-Init: A Cloud-Init API compatible bootstrapper for the Windows operating system.
* First-boot bootstrapper: Run when a machine is booted for the first time, and retrieve configuration information from an infrastructure provider specified endpoint, e.g. IMDS or Guestinfo.


## Summary

Cluster API through v1alpha3 has used a combination of kubeadm, shell scripts and cloud-init to provision nodes. This proposal is for a node bootstrapper to combine these functions into a component that configures a machine and runs kubeadm, and be able to be consumed by multiple bootstrap providers such as cloud-init, Ignition and Talos.

## Motivation

Cluster API’s reliance on cloud-init has frequently caused problems: changes in patch releases have caused breaking changes for Cluster API providers, such as vSphere and AWS. It has also made it difficult for other vendors, not using cloud-init, to easily use the core
Cluster API providers, examples include OpenShift and FlatCar Linux which both use Ignition, and Talos with their own system.

Furthermore, certain providers, such as Cluster API Provider AWS are utilising time-limited hacks within cloud-init to secure bootstrap userdata, and this is not sustainable for the health of the project over time.

Use of an agnostic bootstrapper (machineadm) benefits end users in that they won’t need to closely monitor changes within each system that may have negative side effects on Cluster API. In addition, separating out the processes required to bootstrap a Kubernetes node from the bootstrap mechanism allows for Cluster API Kubeadm Bootstrap Provider (CABPK) to become an independent component.

### Goals

* To produce a minimal on-machine bootstrapping mechanism to run kubeadm, and configure cluster related components.
* To produce interfaces to plug new bootstrapping mechanisms.
* To define new super-types (bootstrapper agnostic) for cluster and control plane configuration, which are not directly coupled to the kubeadm types.
* To work closely with other efforts within Cluster API for the introduction of the types, like the one outlined in #2769.
* To have Kubeadm Control Plane Provider and Kubeadm Bootstrap Provider adopt these types in v1alpha4 (release blocking).


### Non-Goals/Future Work

- To support any on the fly mutability of components or resources at the present time. This proposal will be amended in the future to cover mutability use cases after the initial implementations are completed.

## Proposal

### User Stories
<table>
<thead>
<tr>
<th>ID</th><th>Title</th><th>Description</th></tr>
</thead>
<tbody>
<tr>
<td>U1</td><td>Non cloud-init bootstrap processes</td>
<td>
Ignition is a user-data processing Linux bootstrapping system used by Flat Car Linux, RHEL Atomic Host and Fedora CoreOS. (cluster-api/3761)
</td>
</tr>

<tr>
<td>U2</td><td>System preparation</td>
<td>
Although Flatcar Container Linux is being added to Image Builder, Flatcar is intended to also be used as an immutable distribution, with all additions being done at first boot. Flatcar users should be able to use standard Flatcar images with Cluster API.
</td>
</tr>

<tr>
<td>U3</td><td>Active Directory</td>
<td>
As a platform operator of a Windows environment, I may require their Kubernetes nodes to be domain joined such that the application workloads operate with appropriate Kerberos credentials to connect to services in the infrastructure.

For Windows or Linux hosts joining an Active Directory, they must effectively be given a set of bootstrap credentials to join the directory and persist a Kerberos keytab for the host.
</td>
</tr>

<tr>
<td>U4</td><td>CIS Benchmark Compliance</td>
<td>
As a platform operator, I require Kubernetes clusters to pass the CIS Benchmark in order to meet organisational level security compliance requirements.
</td>
</tr>

<tr>
<td>U5</td><td>DISA STIG Compliance</td>
<td>
As a platform operator in a US, UK, Canadian, Australian or New Zealand secure government environment, I require my Kubernetes clusters to be compliant with the DISA STIG.
</td>
</tr>

<tr>
<td>U6</td><td>Kubeadm UX</td>
<td>
As a cluster operator, I would like the bootstrap configuration of clusters or machines to be shielded from changes happening in kubeadm (e.g. v1beta1 and v1beta2 type migration)</td>
</tr>

<tr>
<td>U7</td><td>Existing Clusters</td>
<td>
As a cluster operator with existing clusters, I would like to be able to, after enabling the necessary flags or feature gates, to create new clusters or machines using nodeadm.
</td>
</tr>

<tr>
<td>U8</td><td>Air-gapped</td>
<td>
As a cluster operator, I need Cluster API to operate independently of an internet connection in order to be able to provision clusters in an air-gapped environment, i.e. where the data center is not connected to the public internet.
</td>
</tr>

<tr>
<td>U9</td><td>Advanced control plane configuration files
</td>
<td>
As a cluster operator, I need to configure components of my control plane, such as audit logging policies, KMS encryption, authentication webhooks to meet organisational requirements.
</td>
</tr>

<tr>
<td>U10</td><td>ContainerD Configuration</td>
<td>
Options such as proxy configuration, registry mirrors, custom certs, cgroup hierachy (image-builder/471) need to often be customised, and it isn’t always suitable to do at an image level. Cluster operators in an organisation often resort to prekubeadmcommand bash scripts to configure containerd and restart the service.
</td>
</tr>

<tr>
<td>U11</td><td>API Server Auth Reconfiguration</td>
<td>
As a cluster operator, I need to reconfigure the API server such that I can deploy a new static pod for authentication and insert an updated API server configuration.
</td>
</tr>

<tr>
<td>U12</td><td>Improving bootstrap reporting</td>
<td>
SRE teams often need to diagnose failed nodes, and having better information about why a node may have failed to join, or better indication of success would be helpful. (cluster-api/3716)
</td>
</tr>

</tbody>
</table>


### Requirements Specification
We define three modalities of the node bootstrapper:

<table>
<thead>
<tr><th>Mode</th><th>Description</th>
</thead>
<tbody>

<tr>
<td>Provisioning</td>
<td>
Expected to run as part of machine bootstrapping e.g. (part of cloud-* SystemD units or Windows OOBE). Only supported when used with Cluster API bootstrapping. Typically executes cluster creation or node join procedures, configuring kubelet etc...
</td>
</tr>

<tr>
<td>Preparation</td>
<td>
Could be run as part of machine bootstrapping prior to “provisioning”, and “prepares” a node for use with Kubernetes. We largely keep this out of scope for the initial implementation unless there is a trivial implementation.
</td>
</tr>

<tr>
<td>Post</td>
<td>
Parts of the use cases above require ongoing management of a host. We list these as requirements, but are largely not in scope for the node agent and should be dealt with by external systems.
</td>
</tr>
</tbody>
</table>

<table>
<thead>
<tr><th>ID</th><th>Requirement</th><th>Mode</th><th>Related Stories</th>
</thead>
<tbody>

<tr>
<td>R1</td>
<td>
The node agent MUST be able to execute kubeadm and report its outcome.
Provisioning
</td>
<td>Provisioning</td><td>U1</td>
</tr>

<tr>
<td>R2</td>
<td>
The node agent MUST allow the configuration of Linux sysctl parameters
</td>
<td>Preparation</td><td>U2,U4</td>
</tr>

<tr>
<td>R3</td>
<td>
The node agent COULD allow the application of custom static pods on the control plane
</td>
<td>Provisioning</td><td>U4,U9</td>
</tr>

<tr>
<td>R4</td>
<td>
The node agent MUST not directly expose the kubeadm API to the end user
</td>
<td>Provisioning</td><td>U6</td>
</tr>

<tr>
<td>R5</td>
<td>
The node agent MUST be able to be used in conjunction with an OS provided bootstrapping tool, not limited to Cloud-Init, Ignition, Talos and Windows Answer File.
</td>
<td>Provisioning</td><td>U1</td>
</tr>

<tr>
<td>R6</td>
<td>
The node agent/authenticator binary MUST provide cryptographic verification in situations where it is downloaded post-boot.
</td>
<td>Preparation</td><td>U2</td>
</tr>

<tr>
<td>R7</td>
<td>
The node agent MUST not be reliant on the use of static pods to operate</td>
<td>All</td><td>U5</td>
</tr>

<tr>
<td>R8</td>
<td>
The node agent MUST enable a Windows node to be domain joined. The node agent WILL NOT manage the group membership of a Windows node in order to enable Group Managed Service Accounts
</td>
<td>Provisioning</td><td>U3</td>
</tr>

<tr>
<td>R9</td>
<td>
The node bootstrapping system MUST be opt-in and not affect the operation of existing clusters when Cluster API is upgraded.
</td>
<td>Provisioning</td><td>U7</td>
</tr>

<tr>
<td>R10</td>
<td>
The node agent system SHOULD allow the agent to be downloaded from the management cluster
</td>
<td>Preparation</td><td>U8</td>
</tr>

<tr>
<td>R11</td>
<td>
The node agent MUST be able to operate without connectivity to the internet (using proper configuration parameters), or to the management cluster.
</td>
<td>Provisioning</td><td>U7</td>
</tr>

<tr>
<td>R12</td>
<td>
When the node agent is downloaded on boot the location MUST be configurable</td>
<td>Preparation</td><td>U8</td>
</tr>

<tr>
<td>R13</td>
<td>
When the node agent is downloaded from the public internet, it MUST be downloadable from a location not subject to frequent rate limiting (e.g. a GCS bucket).</td>
<td>Preparation</td><td>U9</td>
</tr>

<tr>
<td>R14</td>
<td>
The node agent MUST be able to configure containerd given a structured configuration input..</td>
<td>Provisioning</td><td>U10</td>
</tr>

<tr>
<td>R15</td>
<td>
The node agent MUST publish a documented contract for operating system maintainers to integrate with the node agent.
</td>
<td>All</td><td>U1</td>
</tr>


</tbody>


</table>




### Implementation Details/Notes/Constraints

- What are some important details that didn't come across above.
- What are the caveats to the implementation?
- Go in to as much detail as necessary here.
- Talk about core concepts and how they releate.

### Security Model

Document the intended security model for the proposal, including implications
on the Kubernetes RBAC model. Questions you may want to answer include:

* Does this proposal implement security controls or require the need to do so?
  * If so, consider describing the different roles and permissions with tables.
* Are their adequate security warnings where appropriate (see https://adam.shostack.org/ReederEtAl_NEATatMicrosoft.pdf for guidance).
* Are regex expressions going to be used, and are their appropriate defenses against DOS.
* Is any sensitive data being stored in a secret, and only exists for as long as necessary?

### Risks and Mitigations

- What are the risks of this proposal and how do we mitigate? Think broadly.
- How will UX be reviewed and by whom?
- How will security be reviewed and by whom?
- Consider including folks that also work outside the SIG or subproject.

## Alternatives

The `Alternatives` section is used to highlight and record other possible approaches to delivering the value proposed by a proposal.

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
[community meeting]: https://docs.google.com/document/d/1Ys-DOR5UsgbMEeciuG0HOgDQc8kZsaWIWJeKJ1-UfbY
