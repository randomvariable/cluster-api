package v1alpha4

type NodeConfig struct {
	Files  []File
	Images []Image
	// SysctlParameters will configure kernel parameters using sysctl(8). When
	// specified, each parameter must follow the form variable=value, the way
	// it would appear in sysctl.conf.
	SysctlParameters []string `json:",omitempty"`
	Archives         []Archive
	Commands         Commands
}

type Commands struct {
}

type Image struct {
	// This is the name we would pass to "docker pull", whereas source could be a URL from which we would download an image.
	Name string `json:"name,omitempty"`
	// Hash is the hash of the file, to verify image integrity (even over http)
	Hash string `json:"hash,omitempty"`
	// Sources is a list of URLs from which we should download the image
	Sources []string `json:"sources,omitempty"`
}

type File struct {
	Type       string
	Path       string
	Content    string
	ContentRef string // change to object ref
	Mode       string
	Owner      string
	ACLs       []string // sort out for windows and Linux
}

type SystemDUnit struct {
	Name []string
}

type DomainJoin struct {
	UserName          string
	PasswordSecretRef string

	JoinGroups []string
}

type Group struct {
	Name   string
	GID    *int
	System bool
}

// UserTask is responsible for creating a user, by calling useradd
type UserTask struct {
	Name string

	UID   int    `json:"uid"`
	Shell string `json:"shell"`
	Home  string `json:"home"`
}

type Package struct {
	Version      *string `json:"version,omitempty"`
	Source       *string `json:"source,omitempty"`
	Hash         *string `json:"hash,omitempty"`
	PreventStart *bool   `json:"preventStart,omitempty"`

	// Healthy is true if the package installation did not fail
	Healthy *bool `json:"healthy,omitempty"`

	// Additional dependencies that must be installed before this package.
	// These will actually be passed together with this package to rpm/dpkg,
	// which will then figure out the correct order in which to install them.
	// This means that Deps don't get installed unless this package needs to
	// get installed.
	Deps []*Package `json:"deps,omitempty"`
}

// https://docs.microsoft.com/en-us/windows-server/administration/windows-commands/sc-create
type WindowsService struct {
	Type         string
	Start        string
	Error        string
	Path         string
	Group        string
	Tag          bool
	Dependencies []string
	RunsAs       string
	DisplayName  string
	Password     string // change to secretRef
}

type Archive struct {
	Name string

	// Source is the location for the archive
	Source string `json:"source,omitempty"`
	// Hash is the source tar
	Hash string `json:"hash,omitempty"`

	// TargetDir is the directory for extraction
	TargetDir string `json:"target,omitempty"`

	// StripComponents is the number of components to remove when expanding the archive
	StripComponents int `json:"stripComponents,omitempty"`

	// MapFiles is the list of files to extract with corresponding directories to extract
	MapFiles map[string]string `json:"mapFiles,omitempty"`
}
