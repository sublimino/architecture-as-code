// Orbit approval, broker side.
//
// This is the half of the approval gate that holds the PRIVATE key. When an
// operator clicks Approve in the console, the broker mints an ed25519-signed
// JWT bound to that one proposal and hands it to the sentinel, which verifies
// it against the public half it holds. The sentinel cannot mint such a token,
// so it cannot approve its own proposals. Only the operator, through this
// broker, can.
//
// Everything here is stdlib-only (crypto/ed25519, encoding/base64,
// encoding/json), keeping the broker's build-offline property. The private key
// is loaded from disk at startup; if it is absent, minting is disabled and the
// approve endpoint returns 503.
package main

import (
	"crypto/ed25519"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"strings"
	"time"
)

const (
	approvalIssuer   = "estate95-approval"
	approvalAudience = "olly-sentinel"
)

// orbitSigner mints approval tokens. nil private key => minting disabled.
type orbitSigner struct {
	priv ed25519.PrivateKey
}

func newOrbitSigner(path string) *orbitSigner {
	// Minting stays disabled on any failure, but say which one: a key present
	// yet unreadable (wrong owner or mode) looks identical to an absent key
	// otherwise, and that is the usual cause of "signing key not configured".
	raw, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			log.Printf("orbit approval key absent at %s: minting disabled (run `make signing-keys`)", path)
		} else {
			log.Printf("orbit approval key at %s unreadable: %v (check owner and mode; the console must run as the file's owner)", path, err)
		}
		return &orbitSigner{}
	}
	block, _ := pem.Decode(raw)
	if block == nil {
		log.Printf("orbit approval key at %s is not PEM: minting disabled", path)
		return &orbitSigner{}
	}
	key, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	if err != nil {
		log.Printf("orbit approval key at %s not PKCS8: %v", path, err)
		return &orbitSigner{}
	}
	priv, ok := key.(ed25519.PrivateKey)
	if !ok {
		log.Printf("orbit approval key at %s is not ed25519: minting disabled", path)
		return &orbitSigner{}
	}
	return &orbitSigner{priv: priv}
}

func (s *orbitSigner) enabled() bool { return len(s.priv) > 0 }

func b64url(b []byte) string { return base64.RawURLEncoding.EncodeToString(b) }

// mint builds an EdDSA JWS compact token binding the approval to one proposal.
func (s *orbitSigner) mint(proposalID, correlationID, action, approvedBy string, ttl time.Duration, now time.Time) (string, error) {
	if !s.enabled() {
		return "", fmt.Errorf("approval signing key not loaded")
	}
	header, _ := json.Marshal(map[string]string{"alg": "EdDSA", "typ": "JWT"})
	claims, _ := json.Marshal(map[string]any{
		"iss":            approvalIssuer,
		"aud":            approvalAudience,
		"sub":            proposalID,
		"correlation_id": correlationID,
		"action":         action,
		"approved_by":    approvedBy,
		"iat":            now.Unix(),
		"nbf":            now.Unix(),
		"exp":            now.Add(ttl).Unix(),
	})
	signingInput := b64url(header) + "." + b64url(claims)
	sig := ed25519.Sign(s.priv, []byte(signingInput))
	return signingInput + "." + b64url(sig), nil
}

// clock is the broker's time source, isolated so the token timestamps are easy
// to reason about. Real wall-clock; the sentinel checks exp/nbf independently.
func (c *console) clock() time.Time { return time.Now() }

// proxyPost forwards a JSON body to an in-cluster service via the port-forward
// pool and returns its response. The mirror of proxyGet.
func (c *console) proxyPost(svc, path string, body []byte) ([]byte, int, error) {
	local, err := c.pf.get(svc)
	if err != nil {
		return nil, http.StatusServiceUnavailable, err
	}
	resp, err := http.Post("http://"+local+path, "application/json", strings.NewReader(string(body)))
	if err != nil {
		return nil, http.StatusBadGateway, err
	}
	defer resp.Body.Close()
	out, _ := io.ReadAll(resp.Body)
	return out, resp.StatusCode, nil
}

// registerOrbit wires the broker's orbit routes. It proxies proposal listing
// and rejection straight to the sentinel, and mints a token on approval before
// forwarding it, so the private key never leaves the broker and the browser
// never sees it.
func (c *console) registerOrbit(mux *http.ServeMux, signer *orbitSigner) {
	// GET /api/orbit/proposals[?state=proposed] -> sentinel proposal store.
	mux.HandleFunc("/api/orbit/proposals", func(w http.ResponseWriter, r *http.Request) {
		path := "/orbit/proposals"
		if r.URL.RawQuery != "" {
			path += "?" + r.URL.RawQuery
		}
		body, code, err := c.proxyGet("olly-sentinel", path)
		if err != nil {
			clusterUnavailable(w, "the sentinel proposal store", err)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(code)
		_, _ = w.Write(body)
	})

	// POST /api/orbit/approve {proposal_id, approved_by} -> mint a bound token,
	// forward it to the sentinel. The browser supplies only the approver
	// identity.
	mux.HandleFunc("/api/orbit/approve", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "POST only", http.StatusMethodNotAllowed)
			return
		}
		var req struct {
			ProposalID string `json:"proposal_id"`
			ApprovedBy string `json:"approved_by"`
		}
		if err := json.NewDecoder(io.LimitReader(r.Body, 1<<16)).Decode(&req); err != nil {
			http.Error(w, "bad request", http.StatusBadRequest)
			return
		}
		if !signer.enabled() {
			http.Error(w, "approval signing key not configured on the broker", http.StatusServiceUnavailable)
			return
		}
		// Resolve the proposal so the token binds to its correlation_id and
		// action as stored by the sentinel.
		p, err := c.lookupProposal(req.ProposalID)
		if err != nil {
			clusterUnavailable(w, "the sentinel proposal store", err)
			return
		}
		if p == nil {
			http.Error(w, "unknown proposal", http.StatusNotFound)
			return
		}
		approver := strings.TrimSpace(req.ApprovedBy)
		if approver == "" {
			approver = "estate95-operator"
		}
		token, err := signer.mint(p.ProposalID, p.CorrelationID, p.Action, approver, 5*time.Minute, c.clock())
		if err != nil {
			http.Error(w, "mint failed: "+err.Error(), http.StatusInternalServerError)
			return
		}
		payload, _ := json.Marshal(map[string]string{"proposal_id": p.ProposalID, "token": token})
		body, code, err := c.proxyPost("olly-sentinel", "/orbit/approve", payload)
		if err != nil {
			clusterUnavailable(w, "the sentinel approval endpoint", err)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(code)
		_, _ = w.Write(body)
	})

	// POST /api/orbit/reject {proposal_id, rejected_by} -> straight through.
	mux.HandleFunc("/api/orbit/reject", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "POST only", http.StatusMethodNotAllowed)
			return
		}
		payload, _ := io.ReadAll(io.LimitReader(r.Body, 1<<16))
		body, code, err := c.proxyPost("olly-sentinel", "/orbit/reject", payload)
		if err != nil {
			clusterUnavailable(w, "the sentinel approval endpoint", err)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(code)
		_, _ = w.Write(body)
	})
}

type proposalRef struct {
	ProposalID    string `json:"proposal_id"`
	CorrelationID string `json:"correlation_id"`
	Action        string `json:"action"`
}

// lookupProposal fetches one proposal from the sentinel store by id.
func (c *console) lookupProposal(id string) (*proposalRef, error) {
	body, code, err := c.proxyGet("olly-sentinel", "/orbit/proposals")
	if err != nil || code >= 300 {
		if err == nil {
			err = fmt.Errorf("proposal store returned %d", code)
		}
		return nil, err
	}
	var list []proposalRef
	if err := json.Unmarshal(body, &list); err != nil {
		return nil, err
	}
	for i := range list {
		if list[i].ProposalID == id {
			return &list[i], nil
		}
	}
	return nil, nil
}
