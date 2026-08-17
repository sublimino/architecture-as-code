// Package dextemplates renders the SignalLoom-themed Dex web templates against
// the data Dex actually passes them, and fails when the two disagree.
//
// # WHY THIS EXISTS
//
// The templates live in a ConfigMap (base/dex-ui.yaml). Nothing in the build
// ever executed them, so a field name that Dex does not supply was invisible
// until a user hit the page. That is what happened to error.html: it rendered
// `{{ .Error }}`, and Dex has never had a field called Error.
//
// The failure does NOT look like a template failure. Dex's templates.err()
// writes the 4xx status line FIRST, then calls Execute directly:
//
//	func (t *templates) err(r *http.Request, w http.ResponseWriter, errCode int, errMsg string) error {
//	    w.WriteHeader(errCode)
//	    data := struct {
//	        ErrType string
//	        ErrMsg  string
//	        ReqPath string
//	    }{http.StatusText(errCode), errMsg, r.URL.Path}
//	    if err := t.errorTmpl.Execute(w, data); err != nil {
//	        return fmt.Errorf("rendering template %s failed: %s", t.errorTmpl.Name(), err)
//	    }
//	    return nil
//	}
//
// Note it does not use renderTemplate(), which wraps the writer in a
// writeRecorder and substitutes a plain "Internal server error" when Execute
// fails before writing anything. err() has no such guard. html/template
// streams, so Execute writes the header, the panel and the heading, hits the
// unknown field, and stops. The client gets a syntactically broken partial
// page under an HTTP 400 — a page whose entire visible text is the word
// "Error". It is indistinguishable, from the outside, from a template that
// simply had nothing to say.
//
// So the guard cannot be "does the page return 400" or "does the page render".
// It has to be "does the template execute against the exact struct Dex passes,
// and does the result contain the message". That is what these tests do.
//
// ON missingkey=error
//
// It does not apply. Go's missingkey option governs indexing a MAP with an
// absent key; Dex passes anonymous STRUCTS, and a struct field that does not
// exist is already a hard execution error in every mode. The default was never
// too lenient. The gap was that nothing ever executed the template. Dex also
// never calls Option() on its template set, so the setting is not reachable
// from this repo in any case — the templates are mounted into an upstream
// image. A build-time render is the only guard available, and it is the
// stronger one: it catches the field-name drift before the image ever runs.
package dextemplates

import (
	"bytes"
	"fmt"
	"html/template"
	"net/url"
	"os"
	"path"
	"path/filepath"
	"reflect"
	"regexp"
	"sort"
	"strings"
	"testing"

	"gopkg.in/yaml.v3"
)

// dexVersion is the tag pinned in base/dex.yaml. The struct mirrors below were
// read from dexidp/dex at this tag. TestDexImageTagIsThePinnedOne fails if the
// image moves, because these field names are not stable across Dex releases —
// the error template's message field was called ErrDesc before v2.36 and is
// ErrMsg now. A silent bump would reintroduce exactly the defect this file
// exists to catch.
const dexVersion = "v2.41.1"

// ---------------------------------------------------------------------------
// Mirrors of the anonymous structs dex v2.41.1 passes to each template.
// Source: github.com/dexidp/dex@v2.41.1 server/templates.go
// ---------------------------------------------------------------------------

// dexErrorData mirrors templates.err() — server/templates.go:336.
type dexErrorData struct {
	ErrType string
	ErrMsg  string
	ReqPath string
}

// dexConnectorInfo mirrors server.connectorInfo — server/templates.go:251.
type dexConnectorInfo struct {
	ID   string
	Name string
	URL  template.URL
	Type string
}

// dexLoginData mirrors templates.login() — server/templates.go:285.
type dexLoginData struct {
	Connectors []dexConnectorInfo
	ReqPath    string
}

// dexPasswordData mirrors templates.password() — server/templates.go:294.
type dexPasswordData struct {
	PostURL        string
	BackLink       string
	Username       string
	UsernamePrompt string
	Invalid        bool
	ReqPath        string
}

// dexApprovalData mirrors templates.approval() — server/templates.go:309.
type dexApprovalData struct {
	User      string
	Client    string
	AuthReqID string
	Scopes    []string
	ReqPath   string
}

// dexOOBData mirrors templates.oob() — server/templates.go:328.
type dexOOBData struct {
	Code    string
	ReqPath string
}

// dexDeviceData mirrors templates.device() — server/templates.go:264.
type dexDeviceData struct {
	PostURL  string
	UserCode string
	Invalid  bool
	ReqPath  string
}

// dexDeviceSuccessData mirrors templates.deviceSuccess() — server/templates.go:277.
type dexDeviceSuccessData struct {
	ClientName string
	ReqPath    string
}

// requiredTemplates is Dex's own requiredTmpls list. Every one of these is
// mounted by base/dex.yaml and must be present in the ConfigMap, or Dex
// refuses to start with "missing template(s)".
var requiredTemplates = []string{
	"login.html",
	"approval.html",
	"password.html",
	"oob.html",
	"error.html",
	"device.html",
	"device_success.html",
}

// ---------------------------------------------------------------------------
// Loading the theme out of the ConfigMap
// ---------------------------------------------------------------------------

func repoRoot(t *testing.T) string {
	t.Helper()
	// This package sits at d2-signalloom/test/dex-templates.
	root, err := filepath.Abs(filepath.Join("..", "..", ".."))
	if err != nil {
		t.Fatalf("resolve repo root: %v", err)
	}
	return root
}

func dexUIPath(t *testing.T) string {
	t.Helper()
	return filepath.Join(repoRoot(t), "d2-signalloom", "infra", "inf-signalloom", "base", "dex-ui.yaml")
}

func dexDeploymentPath(t *testing.T) string {
	t.Helper()
	return filepath.Join(repoRoot(t), "d2-signalloom", "infra", "inf-signalloom", "base", "dex.yaml")
}

// loadDexUI returns the data map of the dex-ui ConfigMap.
//
// It fatals rather than returning empty if the ConfigMap is absent or has no
// data. A test that silently runs against zero templates passes for the wrong
// reason, and that is the failure mode this whole file is arguing against.
func loadDexUI(t *testing.T) map[string]string {
	t.Helper()
	path := dexUIPath(t)
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read %s: %v", path, err)
	}

	type configMap struct {
		Kind     string `yaml:"kind"`
		Metadata struct {
			Name string `yaml:"name"`
		} `yaml:"metadata"`
		Data map[string]string `yaml:"data"`
	}

	dec := yaml.NewDecoder(bytes.NewReader(raw))
	for {
		var doc configMap
		if err := dec.Decode(&doc); err != nil {
			break
		}
		if doc.Kind == "ConfigMap" && doc.Metadata.Name == "dex-ui" {
			if len(doc.Data) == 0 {
				t.Fatalf("ConfigMap dex-ui in %s has no data — nothing to test", path)
			}
			return doc.Data
		}
	}
	t.Fatalf("no ConfigMap named dex-ui in %s", path)
	return nil
}

// issuerPath is the path component of the issuer in base/dex.yaml
// (${PUBLIC_ORIGIN}/dex). relativeURL is anchored on it.
const issuerPath = "/dex"

// relativeURL is copied verbatim from dexidp/dex@v2.41.1 server/templates.go:190
// so the rendered bytes here are the bytes Dex emits, not an approximation.
// Reproducing a truncation faithfully matters: the byte count is how a live
// response gets matched back to this test.
func relativeURL(serverPath, reqPath, assetPath string) string {
	if u, err := url.ParseRequestURI(assetPath); err == nil && u.Scheme != "" {
		return assetPath // external URL, no changes needed
	}

	splitPath := func(p string) []string {
		res := []string{}
		for _, part := range strings.Split(path.Clean(p), "/") {
			if part != "" {
				res = append(res, part)
			}
		}
		return res
	}

	stripCommonParts := func(s1, s2 []string) ([]string, []string) {
		min := len(s1)
		if len(s2) < min {
			min = len(s2)
		}
		splitIndex := min
		for i := 0; i < min; i++ {
			if s1[i] != s2[i] {
				splitIndex = i
				break
			}
		}
		return s1[splitIndex:], s2[splitIndex:]
	}

	server, req, asset := splitPath(serverPath), splitPath(reqPath), splitPath(assetPath)
	_, req = stripCommonParts(server, req)
	asset, req = stripCommonParts(asset, req)

	var rel string
	for i := 0; i < len(req)-1; i++ {
		rel = path.Join("..", rel)
	}
	return path.Join(rel, path.Join(asset...))
}

// themeFuncs supplies the template functions Dex makes available. Dex's real
// map is sprig plus four of its own (extra, issuer, logo, url); this is the
// subset the SignalLoom theme uses. A template that reaches for anything else
// fails at Parse with `function "x" not defined`, which is a loud, accurate
// failure — add the stub here and confirm sprig really provides it.
func themeFuncs() template.FuncMap {
	return template.FuncMap{
		"url":    func(reqPath, assetPath string) string { return relativeURL(issuerPath, reqPath, assetPath) },
		"issuer": func() string { return "dex" },
		"logo":   func() string { return "theme/logo.png" },
		"extra":  func(k string) string { return "" },
		"lower":  strings.ToLower, // sprig
	}
}

// parseTheme parses every .html key in the ConfigMap into one template set, the
// way Dex's loadTemplates() does, so cross-template references resolve.
func parseTheme(t *testing.T) *template.Template {
	t.Helper()
	data := loadDexUI(t)

	// Assert the mechanism is present before testing it: a set missing the
	// template under test would otherwise Lookup to nil and skip silently.
	for _, name := range requiredTemplates {
		if body, ok := data[name]; !ok || strings.TrimSpace(body) == "" {
			t.Fatalf("dex-ui ConfigMap has no non-empty %q; Dex refuses to start without it", name)
		}
	}

	names := make([]string, 0, len(data))
	for k := range data {
		if strings.HasSuffix(k, ".html") {
			names = append(names, k)
		}
	}
	sort.Strings(names)

	set := template.New("").Funcs(themeFuncs())
	for _, name := range names {
		if _, err := set.New(name).Parse(data[name]); err != nil {
			t.Fatalf("parse %s: %v", name, err)
		}
	}
	return set
}

// fieldNames returns the exported field names of a struct type.
func fieldNames(v any) map[string]bool {
	out := map[string]bool{}
	rt := reflect.TypeOf(v)
	for i := 0; i < rt.NumField(); i++ {
		out[rt.Field(i).Name] = true
	}
	return out
}

// ---------------------------------------------------------------------------
// The tests
// ---------------------------------------------------------------------------

// TestErrorTemplateRendersTypeAndMessage is THE test.
//
// Without the fix it fails at Execute with
//
//	can't evaluate field Error in type dextemplates.dexErrorData
//
// and prints the truncated prefix a real client receives.
func TestErrorTemplateRendersTypeAndMessage(t *testing.T) {
	set := parseTheme(t)

	// A realistic instance of the case that motivated this: a login link whose
	// auth request has expired or been dropped by Dex's in-memory storage,
	// which is what every restart of the pod does to every in-flight login.
	data := dexErrorData{
		ErrType: "Bad Request",
		ErrMsg:  "Invalid or expired login session.",
		ReqPath: "/dex/auth/local/login",
	}

	var buf bytes.Buffer
	err := set.Lookup("error.html").Execute(&buf, data)
	if err != nil {
		t.Fatalf("error.html will not render against the data dex %s passes it: %v\n\n"+
			"html/template streams, and Dex's templates.err() has already sent the 4xx\n"+
			"status line by this point, so the client receives exactly this %d-byte\n"+
			"truncated prefix and nothing more:\n\n%s",
			dexVersion, err, buf.Len(), buf.String())
	}

	got := buf.String()
	for _, want := range []string{data.ErrType, data.ErrMsg} {
		if !strings.Contains(got, want) {
			t.Errorf("rendered error page does not contain %q.\nA user seeing this page\n"+
				"cannot tell an expired login link from a broken deployment.\n\nGot:\n%s", want, got)
		}
	}

	// A page that renders but stops early is the same defect wearing a
	// different hat, and Contains() alone would not catch it.
	if !strings.Contains(got, "</html>") {
		t.Errorf("rendered error page is truncated — no closing </html>.\nGot:\n%s", got)
	}
}

// TestErrorTemplateReferencesOnlyFieldsDexProvides names the defect precisely
// rather than only observing its symptom: it reports WHICH field is wrong.
func TestErrorTemplateReferencesOnlyFieldsDexProvides(t *testing.T) {
	body := loadDexUI(t)["error.html"]
	if body == "" {
		t.Fatal("error.html missing from the dex-ui ConfigMap")
	}

	valid := fieldNames(dexErrorData{})
	// Matches a dotted field reference inside an action: {{ .ErrMsg }},
	// {{ if .Invalid }}, {{ url .ReqPath "..." }}. The bare dot in
	// {{ template "header.html" . }} has no name and does not match.
	ref := regexp.MustCompile(`\.([A-Z][A-Za-z0-9_]*)`)

	for _, action := range regexp.MustCompile(`\{\{[^}]*\}\}`).FindAllString(body, -1) {
		if strings.Contains(action, `template "`) {
			continue // header.html/footer.html get the same struct; checked below.
		}
		for _, m := range ref.FindAllStringSubmatch(action, -1) {
			if !valid[m[1]] {
				t.Errorf("error.html references .%s, which dex %s does not pass to error.html.\n"+
					"Dex supplies exactly: %s.\n"+
					"A field Dex does not supply aborts Execute mid-stream, after the 4xx\n"+
					"status and the page header are already on the wire.",
					m[1], dexVersion, strings.Join(sortedKeys(valid), ", "))
			}
		}
	}
}

// TestErrorTemplateShowsTheMessageField asserts the mechanism is present in the
// tree under test. TestErrorTemplateRendersTypeAndMessage would go green for a
// template that hard-codes the sentinel strings, or that dropped the message
// entirely and happened to leave the words lying around in prose.
func TestErrorTemplateShowsTheMessageField(t *testing.T) {
	body := loadDexUI(t)["error.html"]
	if !strings.Contains(body, ".ErrMsg") {
		t.Errorf("error.html does not reference .ErrMsg — the only field carrying Dex's\n"+
			"human-readable description of what went wrong. Without it the page can\n"+
			"only say that something failed, not what.\n\nerror.html:\n%s", body)
	}
	if !strings.Contains(body, ".ErrType") {
		t.Errorf("error.html does not reference .ErrType — the HTTP status text that\n"+
			"tells an operator whether this is a client mistake or a server fault.\n\nerror.html:\n%s", body)
	}
}

// TestAllTemplatesRenderAgainstDexData extends the guard past error.html. Every
// other template in the theme had the same exposure — nothing executed them
// either. They happen to be correct; this is what keeps them that way.
func TestAllTemplatesRenderAgainstDexData(t *testing.T) {
	set := parseTheme(t)

	cases := []struct {
		tmpl string
		data any
	}{
		{"error.html", dexErrorData{ErrType: "Bad Request", ErrMsg: "boom", ReqPath: "/dex/auth"}},
		{"login.html", dexLoginData{
			Connectors: []dexConnectorInfo{{ID: "local", Name: "Email", URL: "/dex/auth/local", Type: "local"}},
			ReqPath:    "/dex/auth",
		}},
		{"password.html", dexPasswordData{
			PostURL: "/dex/auth/local/login", BackLink: "/dex/auth",
			Username: "demo-user", UsernamePrompt: "Username", Invalid: true, ReqPath: "/dex/auth/local/login",
		}},
		{"approval.html", dexApprovalData{
			User: "demo-user", Client: "Signal Loom Dashboard", AuthReqID: "abc123",
			Scopes: []string{"View your email address"}, ReqPath: "/dex/approval",
		}},
		{"oob.html", dexOOBData{Code: "code-123", ReqPath: "/dex/approval"}},
		{"device.html", dexDeviceData{
			PostURL: "/dex/device/auth/verify_code", UserCode: "AAAA-BBBB", Invalid: true, ReqPath: "/dex/device",
		}},
		{"device_success.html", dexDeviceSuccessData{ClientName: "Signal Loom Dashboard", ReqPath: "/dex/device"}},
	}

	if len(cases) != len(requiredTemplates) {
		t.Fatalf("%d cases for %d required templates — a template is untested", len(cases), len(requiredTemplates))
	}

	for _, tc := range cases {
		t.Run(tc.tmpl, func(t *testing.T) {
			tmpl := set.Lookup(tc.tmpl)
			if tmpl == nil {
				t.Fatalf("%s not in the parsed set", tc.tmpl)
			}
			var buf bytes.Buffer
			if err := tmpl.Execute(&buf, tc.data); err != nil {
				t.Fatalf("%s will not render against the data dex %s passes it: %v\n"+
					"Truncated output (%d bytes):\n%s", tc.tmpl, dexVersion, err, buf.Len(), buf.String())
			}
			if !strings.Contains(buf.String(), "</html>") {
				t.Errorf("%s rendered truncated — no closing </html>:\n%s", tc.tmpl, buf.String())
			}
		})
	}
}

// TestDexImageTagIsThePinnedOne ties the struct mirrors above to a specific
// upstream. Dex has renamed these fields before (ErrDesc -> ErrMsg); a version
// bump without re-reading server/templates.go silently recreates the defect.
func TestDexImageTagIsThePinnedOne(t *testing.T) {
	path := dexDeploymentPath(t)
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read %s: %v", path, err)
	}
	want := fmt.Sprintf("ghcr.io/dexidp/dex:%s", dexVersion)
	if !strings.Contains(string(raw), want) {
		t.Fatalf("%s no longer pins %s.\n"+
			"The struct mirrors in this file were read from dexidp/dex at %s.\n"+
			"Re-read server/templates.go at the new tag, confirm the field names on the\n"+
			"anonymous structs, then update dexVersion here.", path, want, dexVersion)
	}
}

func sortedKeys(m map[string]bool) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}
