package v1alpha4

// EncryptedData is a resource representing in-line encrypted
// data that can be decrypted with an infrastructure plugin
type EncryptedData struct {
	metav1.TypeMeta   `json:",inline"`
	metav1.ObjectMeta `json:"metadata,omitempty"`

	Spec EncryptedDataSpec `json:"spec,omitempty"`
}

// EncryptedDataSpec stores an encrypted block of data as Ciphertext decryptable with a given key derivation algorithm
// and passphrase.
type EncryptedDataSpec struct {
	// Provider is the infrastructure provider plugin that fetches the passphrase. This must be present on the host as
	// machineadm-plugin-encryption-provider-x
	// +kubebuilder:default:=null
	// +kubebuilder:validation:Required
	Provider string `json:"provider"`
	// Ciphertext is the base64 encoded encrypted ciphertext
	Ciphertext string `json:"ciphertext"`
	// +kubebuilder:validation:Required
	// Salt is base64 encoded random data added to the hashing algorithm to safeguard the
	// passphrase
	Salt string `json:"salt"`
	// IV, or Initialization Vector is the base64 encoded fixed-size input to a cryptographic algorithm
	// providing the random seed that was used for encryption.
	IV string `json:"iv"`
	// CipherAlgorithm is the encryption algorithm used for the ciphertext
	// +kubebuilder:validation:Required
	// +kubebuilder:default:=aes-256-cbc
	CipherAlgorithm string `json:"cipherAlgorithm"`
	// DigestAlgorithm is the digest algorithm used for key derivation.
	// +kubebuilder:validation:Required
	// +kubebuilder:default:=sha-512
	DigestAlgorithm string `json:"digestAlgorithm"`
	// Iterations is the number of hashing iterations that was used for key derivation.
	// +kubebuilder:default:=50000
	Iterations string `json:"iterations"`
	// KeyDerivationAlgorithm states the key derivation algorithm used to derive the encryption key
	// from the passphrase
	// +kubebuilder:validation:Required
	// +kubebuilder:default:=pbkdf2
	KeyDerivationAlgorithm string `json:"keyDerivationAlgorithm"`
}
