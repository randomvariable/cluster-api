package v1alpha4

type NodeConfig struct {
	// Files specifies files to be created on the host filesystem
	Files []FileConfig `json:"files,omitempty"`
	// Images will pre-load images into the container runtime for use by
	// the cluster
	Images []Image `json:"images,omitempty"`
	// LinuxConfiguration controls Linux specific configuration options
	*LinuxConfiguration `json:"linuxConfiguration,omitempty"`
	// WindowsConfiguration controls Windows specific configuration options
	*WindowsConfiguration `json:"windowsConfiguration,omitempty"`
	// Commands lists executable commands that should be run at different phases
	Commands Commands
	// AttestationPlugin specifies which attestation plugin to use for the node
	AttestationPlugin string `json:"attestationPlugin"`
	// ContainerRuntime configures the container runtime. ContainerD is supported
	// at the present time.
	ContainerRuntime ContainerRuntime `json:"containerRuntime"`
	// SystemTrust defines certificate authorities to inject into the host system
	// trust store
	SystemTrustCertificateAuthorities []string
	// SystemProxies configures proxies for kubelet, container runtime and the host
	SystemProxies []SystemProxyConfig
}

type ContainerRuntime struct {
	// Registries configures settings for each registry.
	Registries []Registry
}

type Registry struct {
	// Host is the top-level hostname of the registry
	Host string
	// MirrorEndpoints specifies mirrors to be used as alternative endpoints
	// for the registry
	MirrorEndpoints []string
	// InsecureSkipTLSVerify specifies  that the TLS certificate should not be
	// validated
	InsecureSkipTLSVerify bool
	// CACertificates is a PEM formatted document containing CA certificates
	CACertificates string
}

type SystemProxy struct {
	// Protocol that is supported by the proxy
	Protocol string
	// Endpoint is the target endpoint of the proxy
	Endpoint string
	// AuthSecretRef is a reference to a secret containing credentials for
	// the proxy
	AuthSecretRef SecretRef
}

type SystemProxyConfig struct {
	SystemProxy
	AuthSecretRef SecretRef
}

type SystemProxyData struct {
	SystemProxy
	// Username is the username for the http proxy
	Username string
	// Password is the proxy password
	Password string
}

type Commands struct {
	PreKubernetesBootstrap  []string
	PostKubernetesBootstrap []string
}

type LinuxConfiguration struct {
	// SysctlParameters will configure kernel parameters using sysctl(8). When
	// specified, each parameter must follow the form variable=value, the way
	// it would appear in sysctl.conf.
	SysctlParameters []string `json:",omitempty"`
}

type WindowsConfiguration struct {
	// Services defines Windows Services to be created
	Services []WindowsService `json:"services,omitempty"`

	// DomainJoin will instruct nodeadm to join the computer to Active Directory
	// before Kubernetes bootstrap.
	DomainJoin DomainJoin `json:"domainJoin,omitempty"`
}

// WindowsService defines a Windows Service to be created by sc.exe
type WindowsService struct {
	// ServiceName specifies the service name returned by the getkeyname operation.
	// +kubebuilder:validation:Required
	ServiceName string `json:"serviceName"`

	// Path specifies a path to the service binary file.
	// +kubebuilder:validation:Required
	Path string `json:"path"`

	// Type specifies the service type.
	// See https://docs.microsoft.com/en-us/windows-server/administration/windows-commands/sc-create for definitions.
	// +kubebuilder:validation:Enum:=own,share,kernel,filesys,rec,interact
	// +kubebuilder:default:=own
	Type WindowsServiceType `json:"type,omitempty"`

	// Start specifies the start type for the service.
	// See https://docs.microsoft.com/en-us/windows-server/administration/windows-commands/sc-create for definitions.
	// +kubebuilder:default:=demand
	// +kubebuilder:validation:Enum:=boot,system,auto,demand,disabled,delayed-auto
	Start WindowsServiceStart `json:"start"`

	// Specifies the severity of the error if the service fails to start when the computer is started.
	// See https://docs.microsoft.com/en-us/windows-server/administration/windows-commands/sc-create for definitions.
	// +kubebuilder:validation:Enum:=normal,severe,critical,ignore
	// +kubebuilder:default:=normal
	Error WindowsServiceError `json:"error"`

	// Groups Specifies the name of the group of which this service is a member. The list of groups is stored in the registry,
	// in the HKLM\System\CurrentControlSet\Control\ServiceGroupOrder subkey.
	// +optional
	Groups []string `json:"groups,omitempty"`

	// Specifies whether or not to obtain a TagID from the CreateService call.
	// Tags are used only for boot-start and system-start drivers.
	// +optional
	Tag bool `json:"tag,omitempty"`

	// Specifies the names of services or groups that must start before this service.
	// The names are separated by forward slashes (/).
	// +optional
	Dependencies []string `json:"dependencies,omitempty"`

	// Specifies a name of an account in which a service will run, or specifies a name of the Windows driver object in which the driver
	// will run. The default setting is LocalSystem.
	// +kubebuilder:default:=LocalSystem
	RunAs string `json:"runAs"`

	// Specifies a password. This is required if an account other than the
	// LocalSystem account is used.
	// +optional
	PasswordSecretRef secretRef `json:"passwordSecretRef,omitempty"`

	// Specifies a friendly name for identifying the service in user interface programs.
	// For example, the subkey name of one particular
	// service is wuauserv, which has a more friendly display name of Automatic Updates.
	// +optional
	DisplayName string `json:"displayName,omitempty"`

	// StartImmediately requests that nodeadm starts the service immediately after
	// setup
	StartImmediately bool `json:"startImmediately,omitempty"`

	// SkipStartError instructs nodeadm to skip start errors during initial bootstrap.
	SkipStartError bool `json:"skipStartError,omitempty"`
}

type Commands struct {
}

type Image struct {
	// Name is the name we would pass to "docker pull"
	Name string `json:"name"`
	// Target specifies what the image should be retagged with, useful in network restricted environments.
	Target string `json:"name,omitempty"`
}

type File struct {
	// Type specifies if this is a file, directory, link, hard link or NTFS junction.
	// +kubebuilder:validation:Required
	// +kubebuilder:validation:Enum:=file,directory,link,hardlink,junction
	Type string `json:"type"`
	// Path specifies where the file will be created
	// +kubebuilder:validation:Required
	Path string `json:"path"`
	// Mode specifies the mode of the file. Only supported, and required for Linux.
	Mode string `json:"mode,omitempty"`
	// Owner specifies the owner of the file.
	// +kubebuilder:validation:Required
	Owner string `json:"owner,omitempty"`
	// ACLs are any additional ACLs to be applied to the file. Will be applied
	// using setfacl on Linux, and DACLs on Windows.
	ACLs []string `json:"acls,omitempty"`
}

type FileConfig struct {
	File
	// Content is the raw content of the file. Can only be used with type=file
	// Cannot be used together with contentRef.
	Content string `json:"content,omitempty"`
	// Content is the raw content of the file. Can only be used with type=file
	// Cannot be used together with content.
	ContentRef LocalContentReference `json:"contentRef,omitempty"`
}

type FileData struct {
	File
	// Content is the raw content of the file. Can only be used with type=file
	Content string `json:"content,omitempty"`
}

// +kubebuilder:validation:Required
type LocalContentReference struct {
	// Kind is the type of resource being referenced
	// +kubebuilder:validation:Enum:=secret,configMap
	Kind LocalContentReferenceKind `json:"kind"`
	// Name is the name of resource being referenced
	Name string `json:"name"`
}

type DomainJoin struct {
	// CredentialsSecretRef is a reference to a secret containing credentials
	// to join the Active Directory domain.
	CredentialsSecretRef secretRef

	// JoinGroups specifies security groups the node should attempt to join
	// with the administrative credentials.
	JoinGroups []string
}

type WindowsServiceType string
type WindowsServiceStart string
type LocalContentReferenceKind string

const (
	LocalContentReferenceKindSecret    = LocalContentReferenceKind("secret")
	LocalContentReferenceKindConfigMap = LocalContentReferenceKind("configMap")

	WindowsServiceTypeOwn          = WindowsServiceType("own")
	WindowsServiceTypeShare        = WindowsServiceType("share")
	WindowsServiceTypeKernel       = WindowsServiceType("kernel")
	WindowsServiceTypeFileSys      = WindowsServiceType("filesys")
	WindowsServiceTypeFileRec      = WindowsServiceType("rec")
	WindowsServiceTypeFileInteract = WindowsServiceType("interact")

	WindowsServiceStartBoot        = WindowsServiceStart("boot")
	WindowsServiceStartSystem      = WindowsServiceStart("system")
	WindowsServiceStartAuto        = WindowsServiceStart("auto")
	WindowsServiceStartDemand      = WindowsServiceStart("demand")
	WindowsServiceStartDisabled    = WindowsServiceStart("disabled")
	WindowsServiceStartDelayedAuto = WindowsServiceStart("delayed-auto")
)

const (
	WindowsServiceErrorNormal   = WindowsServiceError("normal")
	WindowsServiceErrorSevere   = WindowsServiceError("severe")
	WindowsServiceErrorCritical = WindowsServiceError("critical")
	WindowsServiceErrorIgnore   = WindowsServiceError("ignore")
)
