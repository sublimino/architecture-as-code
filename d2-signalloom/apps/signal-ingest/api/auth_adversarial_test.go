package api

import (
	"crypto/ecdsa"
	"crypto/hmac"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"encoding/asn1"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"math/big"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// Adversarial JWT-SVID cases through the real JWTAuthenticator and
// ProtectedRouter, asserting the exact status and error body a caller sees.

const (
	advSubject = "spiffe://osramp.local/ns/fe-signalloom-agents/sa/stun-sentinel"
	advAud     = "signal-ingest"
)

var advNow = time.Unix(1_900_000_000, 0)

var b64 = base64.RawURLEncoding

// signRaw signs exact header/claims JSON so tests control every byte.
func signRaw(t *testing.T, key *ecdsa.PrivateKey, header, claims string) string {
	t.Helper()
	input := b64.EncodeToString([]byte(header)) + "." + b64.EncodeToString([]byte(claims))
	digest := sha256.Sum256([]byte(input))
	r, s, err := ecdsa.Sign(rand.Reader, key, digest[:])
	if err != nil {
		t.Fatal(err)
	}
	return input + "." + b64.EncodeToString(append(r.FillBytes(make([]byte, 32)), s.FillBytes(make([]byte, 32))...))
}

func advClaims(sub string, exp int64, extra string) string {
	c := fmt.Sprintf(`{"sub":%q,"aud":%q,"exp":%d`, sub, advAud, exp)
	if extra != "" {
		c += "," + extra
	}
	return c + "}"
}

type advFixture struct {
	ec     *ecdsa.PrivateKey
	rsa    *rsa.PrivateKey
	authn  *JWTAuthenticator
	router *ProtectedRouter
}

func newAdvFixture(t *testing.T) advFixture {
	t.Helper()
	ec := genKey(t)
	rk, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	authn, err := NewJWTAuthenticator(AuthConfig{
		Audience: advAud, TrustDomain: "osramp.local",
		Keys: map[string]any{"ec": &ec.PublicKey, "rsa": &rk.PublicKey},
		Bindings: map[string]PrincipalBinding{
			advSubject: {TenantID: "kusari", Permissions: []Permission{PermissionHealth}},
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	authn.now = func() time.Time { return advNow }
	h, _ := newTestHandlers(t)
	router, err := NewProtectedRouter(h, authn, h.Audit, http.NotFoundHandler(), RouterOptions{})
	if err != nil {
		t.Fatal(err)
	}
	return advFixture{ec: ec, rsa: rk, authn: authn, router: router}
}

func (f advFixture) serve(t *testing.T, path string, authz ...string) (int, string) {
	t.Helper()
	req := httptest.NewRequest(http.MethodGet, path, nil)
	for _, v := range authz {
		req.Header.Add("Authorization", v)
	}
	w := httptest.NewRecorder()
	f.router.ServeHTTP(w, req)
	var body struct {
		Error string `json:"error"`
	}
	if w.Code != http.StatusOK {
		if err := json.Unmarshal(w.Body.Bytes(), &body); err != nil {
			t.Fatalf("status %d body is not a JSON error object: %q", w.Code, w.Body.String())
		}
	}
	return w.Code, body.Error
}

const (
	esHeader  = `{"alg":"ES256","kid":"ec","typ":"JWT"}`
	unauth    = "authentication_failed"
	unbound   = "principal_unbound"
	forbidden = "authorization_denied"
)

func TestJWTBoundaryExactStatusAndBody(t *testing.T) {
	f := newAdvFixture(t)
	valid := signRaw(t, f.ec, esHeader, advClaims(advSubject, advNow.Unix()+60, ""))
	parts := strings.Split(valid, ".")

	// HS256 keyed with the RSA public key, the classic alg-confusion forgery.
	rsaPub, _ := x509.MarshalPKIXPublicKey(&f.rsa.PublicKey)
	hsInput := b64.EncodeToString([]byte(`{"alg":"HS256","kid":"rsa"}`)) + "." + parts[1]
	mac := hmac.New(sha256.New, rsaPub)
	mac.Write([]byte(hsInput))
	hsConfused := hsInput + "." + b64.EncodeToString(mac.Sum(nil))

	// ES256 signature in ASN.1 DER instead of the JOSE r||s form.
	digest := sha256.Sum256([]byte(parts[0] + "." + parts[1]))
	r, s, _ := ecdsa.Sign(rand.Reader, f.ec, digest[:])
	der, _ := asn1.Marshal(struct{ R, S *big.Int }{r, s})
	derSig := parts[0] + "." + parts[1] + "." + b64.EncodeToString(der)

	tests := []struct {
		name   string
		authz  []string
		status int
		body   string
	}{
		{"valid", []string{"Bearer " + valid}, 200, ""},
		{"missing header", nil, 401, unauth},
		{"basic scheme", []string{"Basic " + valid}, 401, unauth},
		{"lowercase bearer", []string{"bearer " + valid}, 401, unauth},
		{"bearer without token", []string{"Bearer "}, 401, unauth},
		{"double space", []string{"Bearer  " + valid}, 401, unauth},
		{"trailing whitespace", []string{"Bearer " + valid + " "}, 401, unauth},
		{"duplicate header same token", []string{"Bearer " + valid, "Bearer " + valid}, 401, unauth},
		{"oversized token", []string{"Bearer " + valid + strings.Repeat("A", 16*1024)}, 401, unauth},
		{"two segments", []string{"Bearer " + parts[0] + "." + parts[1]}, 401, unauth},
		{"four segments", []string{"Bearer " + valid + ".x"}, 401, unauth},
		{"padded base64 signature", []string{"Bearer " + valid + "="}, 401, unauth},
		{"alg none empty signature", []string{"Bearer " + b64.EncodeToString([]byte(`{"alg":"none","kid":"ec"}`)) + "." + parts[1] + "."}, 401, unauth},
		{"alg none with real signature", []string{"Bearer " + b64.EncodeToString([]byte(`{"alg":"none","kid":"ec"}`)) + "." + parts[1] + "." + parts[2]}, 401, unauth},
		{"alg lowercase es256", []string{"Bearer " + signRaw(t, f.ec, `{"alg":"es256","kid":"ec"}`, advClaims(advSubject, advNow.Unix()+60, ""))}, 401, unauth},
		{"alg RS256 against EC key", []string{"Bearer " + signRaw(t, f.ec, `{"alg":"RS256","kid":"ec"}`, advClaims(advSubject, advNow.Unix()+60, ""))}, 401, unauth},
		{"HS256 keyed with RSA public key", []string{"Bearer " + hsConfused}, 401, unauth},
		{"DER-encoded ES256 signature", []string{"Bearer " + derSig}, 401, unauth},
		{"missing kid", []string{"Bearer " + signRaw(t, f.ec, `{"alg":"ES256"}`, advClaims(advSubject, advNow.Unix()+60, ""))}, 401, unauth},
		{"unknown kid", []string{"Bearer " + signRaw(t, f.ec, `{"alg":"ES256","kid":"nope"}`, advClaims(advSubject, advNow.Unix()+60, ""))}, 401, unauth},
		{"kid of the other key", []string{"Bearer " + signRaw(t, f.ec, `{"alg":"ES256","kid":"rsa"}`, advClaims(advSubject, advNow.Unix()+60, ""))}, 401, unauth},
		{"crit header", []string{"Bearer " + signRaw(t, f.ec, `{"alg":"ES256","kid":"ec","crit":["exp"]}`, advClaims(advSubject, advNow.Unix()+60, ""))}, 401, unauth},
		{"duplicate header kid", []string{"Bearer " + signRaw(t, f.ec, `{"alg":"ES256","kid":"nope","kid":"ec"}`, advClaims(advSubject, advNow.Unix()+60, ""))}, 401, unauth},
		{"duplicate sub claim", []string{"Bearer " + signRaw(t, f.ec, esHeader, fmt.Sprintf(`{"sub":"spiffe://osramp.local/x","sub":%q,"aud":%q,"exp":%d}`, advSubject, advAud, advNow.Unix()+60))}, 401, unauth},
		{"claims array not object", []string{"Bearer " + signRaw(t, f.ec, esHeader, `[1]`)}, 401, unauth},
		{"exp missing", []string{"Bearer " + signRaw(t, f.ec, esHeader, fmt.Sprintf(`{"sub":%q,"aud":%q}`, advSubject, advAud))}, 401, unauth},
		{"exp null", []string{"Bearer " + signRaw(t, f.ec, esHeader, fmt.Sprintf(`{"sub":%q,"aud":%q,"exp":null}`, advSubject, advAud))}, 401, unauth},
		{"aud missing", []string{"Bearer " + signRaw(t, f.ec, esHeader, fmt.Sprintf(`{"sub":%q,"exp":%d}`, advSubject, advNow.Unix()+60))}, 401, unauth},
		{"aud wrong", []string{"Bearer " + signRaw(t, f.ec, esHeader, fmt.Sprintf(`{"sub":%q,"aud":"other","exp":%d}`, advSubject, advNow.Unix()+60))}, 401, unauth},
		{"aud case variant", []string{"Bearer " + signRaw(t, f.ec, esHeader, fmt.Sprintf(`{"sub":%q,"aud":"Signal-Ingest","exp":%d}`, advSubject, advNow.Unix()+60))}, 401, unauth},
		{"aud array without expected", []string{"Bearer " + signRaw(t, f.ec, esHeader, fmt.Sprintf(`{"sub":%q,"aud":["other",1],"exp":%d}`, advSubject, advNow.Unix()+60))}, 401, unauth},
		{"aud array with expected", []string{"Bearer " + signRaw(t, f.ec, esHeader, fmt.Sprintf(`{"sub":%q,"aud":["other",%q],"exp":%d}`, advSubject, advAud, advNow.Unix()+60))}, 200, ""},
		{"aud nested array", []string{"Bearer " + signRaw(t, f.ec, esHeader, fmt.Sprintf(`{"sub":%q,"aud":[[%q]],"exp":%d}`, advSubject, advAud, advNow.Unix()+60))}, 401, unauth},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			status, body := f.serve(t, "/healthz", tc.authz...)
			if status != tc.status || body != tc.body {
				t.Fatalf("got %d %q, want %d %q", status, body, tc.status, tc.body)
			}
		})
	}
}

// Clock boundaries: no leeway. exp is exclusive, nbf is inclusive, and a
// NumericDate that does not parse as an int64 never yields a live token.
func TestJWTTimeClaimBoundaries(t *testing.T) {
	f := newAdvFixture(t)
	now := advNow.Unix()
	tests := []struct {
		name   string
		claims string
		status int
	}{
		{"exp one second ahead", advClaims(advSubject, now+1, ""), 200},
		{"exp equals now", advClaims(advSubject, now, ""), 401},
		{"exp one second behind", advClaims(advSubject, now-1, ""), 401},
		{"nbf equals now", advClaims(advSubject, now+60, fmt.Sprintf(`"nbf":%d`, now)), 200},
		{"nbf one second ahead", advClaims(advSubject, now+60, fmt.Sprintf(`"nbf":%d`, now+1)), 401},
		{"exp fractional", fmt.Sprintf(`{"sub":%q,"aud":%q,"exp":%d.5}`, advSubject, advAud, now+60), 401},
		{"exp exponent form", fmt.Sprintf(`{"sub":%q,"aud":%q,"exp":1e11}`, advSubject, advAud), 401},
		{"exp int64 overflow", fmt.Sprintf(`{"sub":%q,"aud":%q,"exp":99999999999999999999}`, advSubject, advAud), 401},
		{"exp int64 overflow with valid nbf", fmt.Sprintf(`{"sub":%q,"aud":%q,"exp":99999999999999999999,"nbf":%d}`, advSubject, advAud, now-1), 401},
		{"exp malformed with valid nbf", fmt.Sprintf(`{"sub":%q,"aud":%q,"exp":1e11,"nbf":%d}`, advSubject, advAud, now-1), 401},
		{"nbf int64 underflow", advClaims(advSubject, now+60, `"nbf":-99999999999999999999`), 401},
		{"nbf fractional", advClaims(advSubject, now+60, fmt.Sprintf(`"nbf":%d.5`, now-10)), 401},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			status, _ := f.serve(t, "/healthz", "Bearer "+signRaw(t, f.ec, esHeader, tc.claims))
			if status != tc.status {
				t.Fatalf("got %d, want %d", status, tc.status)
			}
		})
	}
}

// A subject must be in the configured trust domain (else 401) and must match
// a binding byte-for-byte (else 403). No spelling may alias the bound subject.
func TestJWTSPIFFESubjectConfusion(t *testing.T) {
	f := newAdvFixture(t)
	tests := []struct {
		sub    string
		status int
		body   string
	}{
		{advSubject, 200, ""},
		{"spiffe://osramp.local.evil/ns/fe-signalloom-agents/sa/stun-sentinel", 401, unauth},
		{"spiffe://evil/osramp.local/ns/fe-signalloom-agents/sa/stun-sentinel", 401, unauth},
		{"spiffe://evil.osramp.local/ns/fe-signalloom-agents/sa/stun-sentinel", 401, unauth},
		{"spiffe://osramp.local:443/ns/fe-signalloom-agents/sa/stun-sentinel", 401, unauth},
		{"spiffe://attacker@osramp.local/ns/fe-signalloom-agents/sa/stun-sentinel", 401, unauth},
		{"spiffe://OSRAMP.LOCAL/ns/fe-signalloom-agents/sa/stun-sentinel", 401, unauth},
		{"spiffe://osramp%2elocal/ns/fe-signalloom-agents/sa/stun-sentinel", 401, unauth},
		{"spiffe://osrаmp.local/ns/fe-signalloom-agents/sa/stun-sentinel", 401, unauth}, // Cyrillic а
		{"https://osramp.local/ns/fe-signalloom-agents/sa/stun-sentinel", 401, unauth},
		{"spiffe:osramp.local/ns/fe-signalloom-agents/sa/stun-sentinel", 401, unauth},
		{"spiffe://osramp.local/ns/fe-signalloom-agents/sa/stun-sentinel?x=1", 401, unauth},
		{"spiffe://osramp.local/ns/fe-signalloom-agents/sa/stun-sentinel#x", 401, unauth},
		{"", 401, unauth},
		{"SPIFFE://osramp.local/ns/fe-signalloom-agents/sa/stun-sentinel", 403, unbound},
		{"spiffe://osramp.local/ns/fe-signalloom-agents/sa/stun-sentinel/", 403, unbound},
		{"spiffe://osramp.local/ns/x/../fe-signalloom-agents/sa/stun-sentinel", 403, unbound},
		{"spiffe://osramp.local/ns/fe-signalloom-agents/sa/%73tun-sentinel", 403, unbound},
		{"spiffe://osramp.local//ns/fe-signalloom-agents/sa/stun-sentinel", 403, unbound},
		{"spiffe://osramp.local/ns/fe-signalloom-agents/sa/STUN-SENTINEL", 403, unbound},
		{"spiffe://osramp.local/ns/fe-signalloom-agents/sa/stun-sentinel-evil", 403, unbound},
	}
	for _, tc := range tests {
		t.Run(tc.sub, func(t *testing.T) {
			status, body := f.serve(t, "/healthz", "Bearer "+signRaw(t, f.ec, esHeader, advClaims(tc.sub, advNow.Unix()+60, "")))
			if status != tc.status || body != tc.body {
				t.Fatalf("got %d %q, want %d %q", status, body, tc.status, tc.body)
			}
		})
	}
}

// A bound, authenticated principal without the route's permission is 403, not 401.
func TestJWTBoundPrincipalWithoutPermissionIs403(t *testing.T) {
	f := newAdvFixture(t)
	status, body := f.serve(t, "/api/v1/store/stats", "Bearer "+signRaw(t, f.ec, esHeader, advClaims(advSubject, advNow.Unix()+60, "")))
	if status != 403 || body != forbidden {
		t.Fatalf("got %d %q, want 403 %q", status, body, forbidden)
	}
}

// An unknown kid never triggers a key reload: keys change only via
// RefreshKeys, so a flood of unknown-kid tokens costs no I/O and a newly
// published key is trusted only after a refresh has validated the file.
func TestJWKSUnknownKidDoesNotRefetchUntilRefresh(t *testing.T) {
	path := filepath.Join(t.TempDir(), "jwks.json")
	keyA, keyB := genKey(t), genKey(t)
	writeJWKSFile(t, path, map[string]*ecdsa.PrivateKey{"a": keyA})
	a := newFileAuthenticator(t, path, time.Hour)
	writeJWKSFile(t, path, map[string]*ecdsa.PrivateKey{"a": keyA, "b": keyB})
	for i := 0; i < 1000; i++ {
		if err := authWith(a, refreshToken(t, keyB, "b")); err != ErrInvalidCredential {
			t.Fatalf("kid published on disk accepted before refresh: %v", err)
		}
	}
	if err := a.RefreshKeys(); err != nil {
		t.Fatal(err)
	}
	if err := authWith(a, refreshToken(t, keyB, "b")); err != nil {
		t.Fatalf("kid published before refresh rejected after refresh: %v", err)
	}
}

// Every refresh-time rejection keeps the last good set AND does not admit the
// key carried by the rejected file.
func TestJWKSRejectedRefreshAdmitsNothingNew(t *testing.T) {
	keyB := genKey(t)
	goodB := fmt.Sprintf(`{"kty":"EC","kid":"b","crv":"P-256","x":%q,"y":%q}`,
		b64.EncodeToString(keyB.X.FillBytes(make([]byte, 32))), b64.EncodeToString(keyB.Y.FillBytes(make([]byte, 32))))
	weak, _ := rsa.GenerateKey(rand.Reader, 1024)
	weakRSA := fmt.Sprintf(`{"kty":"RSA","kid":"w","n":%q,"e":"AQAB"}`, b64.EncodeToString(weak.N.Bytes()))
	for name, body := range map[string]string{
		"oversized":         `{"keys":[` + goodB + `],"pad":"` + strings.Repeat("x", maxJWKSFileBytes) + `"}`,
		"duplicate kid":     `{"keys":[` + goodB + `,` + goodB + `]}`,
		"weak rsa sibling":  `{"keys":[` + goodB + `,` + weakRSA + `]}`,
		"off-curve sibling": `{"keys":[` + goodB + `,{"kty":"EC","kid":"c","crv":"P-256","x":"AQ","y":"AQ"}]}`,
		"missing kid":       `{"keys":[` + goodB + `,{"kty":"EC","crv":"P-256","x":"AQ","y":"AQ"}]}`,
		"symmetric key":     `{"keys":[` + goodB + `,{"kty":"oct","kid":"h","k":"c2VjcmV0"}]}`,
		"truncated":         `{"keys":[` + goodB,
	} {
		t.Run(name, func(t *testing.T) {
			path := filepath.Join(t.TempDir(), "jwks.json")
			keyA := genKey(t)
			writeJWKSFile(t, path, map[string]*ecdsa.PrivateKey{"a": keyA})
			a := newFileAuthenticator(t, path, time.Hour)
			writeRaw(t, path, body)
			if err := a.RefreshKeys(); err == nil {
				t.Fatal("rejected JWKS refresh reported success")
			}
			if err := authWith(a, refreshToken(t, keyA, "a")); err != nil {
				t.Fatalf("last-good key lost: %v", err)
			}
			if err := authWith(a, refreshToken(t, keyB, "b")); err != ErrInvalidCredential {
				t.Fatalf("key from rejected JWKS admitted: %v", err)
			}
		})
	}
}
