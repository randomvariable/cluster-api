package v1alpha4

//
type MachineConfig struct {
	// Images will pre-load images into the container runtime for use by
	// the cluster
	Images []Image `json:"images,omitempty"`
	// NOTE: Webhook will explicitly prohibit configuring both a Linux and Windows
	// configuration
	// LinuxConfiguration controls Linux specific configuration options
	LinuxConfiguration *LinuxConfiguration `json:"linuxConfiguration,omitempty"`
	// WindowsConfiguration controls Windows specific configuration options
	WindowsConfiguration *WindowsConfiguration `json:"windowsConfiguration,omitempty"`
	// Commands lists executable commands that should be run at different phases
	Commands Commands `json:"commands,omitempty"`
	// Kubelet specifies specific configuration for the
	Kubelet string `json:"kubelet,omitempty"`
	// ContainerRuntime configures the container runtime. ContainerD is supported
	// at the present time.
	ContainerRuntime ContainerRuntime `json:"containerRuntime"`
	// SystemTrust defines certificate authorities to inject into the host system
	// trust store
	SystemTrustCertificateAuthorities []string
	// SystemProxies configures proxies for kubelet, container runtime and the host
	SystemProxies []SystemProxyConfig
}


// SerialisedNodeConfig is the fully serialised format of the node config
// containing no external references to Kubernetes resources
type SerialisedNodeConfig struct {
	// Files specifies files to be created on the host filesystem
	Files []SerialisedFile `json:"files,omitempty"`
	// Images will pre-load images into the container runtime for use by
	// the cluster
	Images []Image `json:"images,omitempty"`
	// LinuxConfiguration controls Linux specific configuration options
	LinuxConfiguration *LinuxConfiguration `json:"linuxConfiguration,omitempty"`

	// WindowsConfiguration controls Windows specific configuration options
	WindowsConfiguration *SerialisedWindowsConfiguration `json:"windowsConfiguration,omitempty"`
	// Commands lists executable commands that should be run at different phases
	Commands Commands
	// AttestationPlugin specifies which attestation plugin to use for the node
	AttestationPlugin string `json:"attestationPlugin"`
	// ContainerRuntime configures the container runtime. ContainerD is supported
	// at the present time.
	ContainerRuntime ContainerRuntime ContainerRuntime `json:"containerRuntime"`
	// SystemTrust defines certificate authorities to inject into the host system
	// trust store
	SystemTrustCertificateAuthorities []string
	// SystemProxies configures proxies for kubelet, container runtime and the host
	SystemProxies []SystemProxyConfig
}

type Kubelet struct {

}

type ContainerRuntime struct {
	// Provider is the provider plugin which will be used to configure
	// the runtime. This must be present on the host as
	// machineadm-plugin-container-runtime-x
	// +kubebuilder:default:=containerd
	// +kubebuilder:validation:Required
	Provider string `json:"provider"`
	// Registries configures settings for each container registry.
	Registries []Registry `json:"registries"`
}

type Registry struct {
	// Host is the top-level hostname of the registry
	Host string `json:"host"`
	// MirrorEndpoints specifies mirrors to be used as alternative endpoints
	// for the registry
	MirrorEndpoints []string `json:"mirrorEndpoints"`
	// InsecureSkipTLSVerify specifies  that the TLS certificate should not be
	// validated
	InsecureSkipTLSVerify bool `json:"insecureSkipVerify"`
	// CACertificates is a PEM formatted document containing CA certificates
	CACertificates []string `json:"caCertificates"`
}

type SystemProxy struct {
	// Provider is the provider plugin which will be used to configure
	// the system proxy. This must be present on the host as
	// machineadm-plugin-system-proxy-x
	// +kubebuilder:default:=systemd
	// +kubebuilder:validation:Required
	Provider string `json:"provider"`
	// Protocol that is supported by the proxy
	Protocol string `json:"protocol"`
	// Endpoint is the target endpoint of the proxy
	Endpoint string `json:"endpoint"`
}

type SystemProxyConfig struct {
	SystemProxy
	// AuthSecretName is the name of the secret containing credentials for
	// the proxy
	AuthSecretName string `json:"authSecretName"`
}

type SystemProxyData struct {
	SystemProxy
	// Username is the username for the http proxy
	Username string `json:"username"`
	// Password is the proxy password
	Password string `json:"password"`
}

type Commands struct {
	PreKubernetesBootstrap  []string `json:"preKubernetesBootstrap"`
	PostKubernetesBootstrap []string `json:"postKubernetesBootstrap"`
}

type LinuxConfiguration struct {
	// Provider is the provider plugin which will be used to configure
	// the system proxy. This must be present on the host as
	// machineadm-plugin-linux-configuration-x
	// +kubebuilder:default:=systemd
	// +kubebuilder:validation:Required
	Provider string `json:"provider"`
	// SysctlParameters will configure kernel parameters using sysctl(8). When
	// specified, each parameter must follow the form variable=value, the way
	// it would appear in sysctl.conf.
	SysctlParameters []string `json:",omitempty"`
}

type WindowsConfiguration struct {
	// Services defines Windows Services to be created
	Services []WindowsServiceConfig `json:"services,omitempty"`

	// DomainJoin will instruct nodeadm to join the computer to Active Directory
	// before Kubernetes bootstrap.
	DomainJoin DomainJoin `json:"domainJoin,omitempty"`
}

type SerialisedWindowsConfiguration struct {
	// Services defines Windows Services to be created
	Services []SerialisedWindowsService `json:"services,omitempty"`

	// DomainJoin will instruct nodeadm to join the computer to Active Directory
	// before Kubernetes bootstrap.
	DomainJoin SerialisedDomainJoin `json:"domainJoin,omitempty"`
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

type WindowsServiceConfig {
	WindowsService

	// Specifies a password. This is required if an account other than the
	// LocalSystem account is used.
	// +optional
	PasswordSecretName string `json:"passwordSecretName,omitempty"`
}

type SerialisedWindowsService
	WindowsService

	// Specifies a password. This is required if an account other than the
	// LocalSystem account is used.
	// +optional
	Password string `json:"passwordSecret,omitempty"`
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
	// using setfacl on Linux, and dacls on Windows.
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

type SerialisedFile struct {
	File
	// Content is the raw content of the file. Can only be used with type=file
	Content string `json:"content,omitempty"`
}

type DomainJoin struct {
	// CredentialsSecretName is a reference to a secret containing credentials
	// to join the Active Directory domain.
	CredentialsSecretName string

	// JoinGroups specifies security groups the node should attempt to join
	// with the administrative credentials.
	JoinGroups []string
}
