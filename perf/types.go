package perf

type TerminationType string

const (
	EdgeTermination        TerminationType = "edge"
	HTTPTermination        TerminationType = "http"
	PassthroughTermination TerminationType = "passthrough"
	ReEncryptTermination   TerminationType = "reencrypt"
)

var AllTerminationTypes = [...]TerminationType{
	EdgeTermination,
	HTTPTermination,
	PassthroughTermination,
	ReEncryptTermination,
}

func (t TerminationType) TerminationScheme() string {
	switch t {
	case HTTPTermination:
		return "http"
	default:
		return "https"
	}
}

func (t TerminationType) TerminationPort() int64 {
	switch t {
	case HTTPTermination:
		return 8080
	default:
		return 8443
	}
}
