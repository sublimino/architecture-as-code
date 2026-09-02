package main

import (
	"bytes"
	"encoding/json"
	"flag"
	"fmt"
	"math/rand"
	"net/http"
	"os"
	"time"
)

type K8sEventList struct {
	Kind       string     `json:"kind"`
	APIVersion string     `json:"apiVersion"`
	Items      []K8sEvent `json:"items"`
}

type K8sEvent struct {
	AuditID         string       `json:"auditID"`
	Stage           string       `json:"stage"`
	RequestURI      string       `json:"requestURI"`
	Verb            string       `json:"verb"`
	User            K8sUserInfo  `json:"user"`
	SourceIPs       []string     `json:"sourceIPs"`
	UserAgent       string       `json:"userAgent"`
	ObjectRef       *K8sObjRef   `json:"objectRef,omitempty"`
	ResponseStatus  *K8sRespStat `json:"responseStatus,omitempty"`
	StageTimestamp  time.Time    `json:"stageTimestamp"`
}

type K8sUserInfo struct {
	Username string   `json:"username"`
	Groups   []string `json:"groups"`
}

type K8sObjRef struct {
	Resource  string `json:"resource"`
	Namespace string `json:"namespace"`
	Name      string `json:"name"`
	APIGroup  string `json:"apiGroup"`
}

type K8sRespStat struct {
	Code   int32  `json:"code"`
	Status string `json:"status"`
}

func main() {
	targetURL := flag.String("target-url", "http://localhost:8080/api/v1/audit/webhook", "Target webhook receiver URL")
	mode := flag.String("mode", "mixed", "Generation mode: k8s|gcp|mixed|adversarial")
	count := flag.Int("count", 20, "Number of events to generate")
	dryRun := flag.Bool("dry-run", false, "Print generated JSON without sending HTTP POST")
	flag.Parse()

	events := generateEvents(*mode, *count)
	payload := K8sEventList{
		Kind:       "EventList",
		APIVersion: "audit.k8s.io/v1",
		Items:      events,
	}

	data, err := json.MarshalIndent(payload, "", "  ")
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error marshalling events: %v\n", err)
		os.Exit(1)
	}

	if *dryRun {
		fmt.Println(string(data))
		return
	}

	resp, err := http.Post(*targetURL, "application/json", bytes.NewReader(data))
	if err != nil {
		fmt.Fprintf(os.Stderr, "HTTP POST to %s failed: %v\n", *targetURL, err)
		os.Exit(1)
	}
	defer resp.Body.Close()

	fmt.Printf("Emitted %d %s audit events -> %s [HTTP %d]\n", len(events), *mode, *targetURL, resp.StatusCode)
}

func generateEvents(mode string, count int) []K8sEvent {
	var events []K8sEvent
	now := time.Now().UTC()

	verbs := []string{"get", "list", "create", "patch", "delete"}
	resources := []string{"secrets", "configmaps", "pods", "rolebindings", "serviceaccounts"}
	namespaces := []string{"default", "kube-system", "ml-workloads", "kagent"}

	for i := 0; i < count; i++ {
		verb := verbs[rand.Intn(len(verbs))]
		res := resources[rand.Intn(len(resources))]
		ns := namespaces[rand.Intn(len(namespaces))]
		username := "system:serviceaccount:kagent:autonomous-agent-1"

		if mode == "adversarial" || (mode == "mixed" && i%3 == 0) {
			verb = "get"
			res = "secrets"
			ns = "kube-system"
		}

		events = append(events, K8sEvent{
			AuditID:    fmt.Sprintf("audit-gen-%d-%d", now.UnixNano(), i),
			Stage:      "ResponseComplete",
			RequestURI: fmt.Sprintf("/api/v1/namespaces/%s/%s", ns, res),
			Verb:       verb,
			User: K8sUserInfo{
				Username: username,
				Groups:   []string{"system:serviceaccounts", "system:authenticated"},
			},
			SourceIPs: []string{"10.244.0.15"},
			UserAgent: "kubectl/v1.30.0",
			ObjectRef: &K8sObjRef{
				Resource:  res,
				Namespace: ns,
				Name:      fmt.Sprintf("target-%s-%d", res, i),
			},
			ResponseStatus: &K8sRespStat{
				Code:   200,
				Status: "OK",
			},
			StageTimestamp: now.Add(time.Duration(i) * time.Second),
		})
	}

	return events
}
