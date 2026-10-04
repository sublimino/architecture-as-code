package awslogs

import (
	"strings"
	"testing"
)

// Cato round 2, ISC-23: the plaintext description must not repeat the principal ARN that
// the store pseudonymises in ActorHint.
func TestDescriptionNeverRepeatsTheActorARN(t *testing.T) {
	labels := map[string]string{
		LabelEventSource:  "iam.amazonaws.com",
		LabelEventName:    "AttachUserPolicy",
		LabelResourceName: "arn:aws:iam::123456789012:policy/x",
		LabelSourceIP:     "203.0.113.5",
	}
	actor := "arn:aws:iam::123456789012:user/alice"
	d := controlPlaneDescription(labels, actor)
	if strings.Contains(d, actor) || strings.Contains(d, "user/alice") {
		t.Fatalf("description leaks the actor ARN: %q", d)
	}
	if d == "" || len(d) > 200 {
		t.Fatalf("description must stay a one-line summary under 200 chars: %q", d)
	}
}

// Cato round 3, ISC-23: a resource ARN that names a principal must not reach the
// description through the resource_name door either, and neither must the source IP.
func TestDescriptionNeverRepeatsResourceARNOrSourceIP(t *testing.T) {
	labels := map[string]string{
		LabelEventSource:  "iam.amazonaws.com",
		LabelEventName:    "AttachUserPolicy",
		LabelResourceType: "AWS::IAM::User",
		LabelResourceName: "arn:aws:iam::123456789012:user/alice",
		LabelSourceIP:     "203.0.113.5",
	}
	d := controlPlaneDescription(labels, "arn:aws:iam::123456789012:user/alice")
	for _, leak := range []string{"user/alice", "123456789012", "203.0.113.5"} {
		if strings.Contains(d, leak) {
			t.Fatalf("description leaks %q: %q", leak, d)
		}
	}
	if !strings.Contains(d, "AttachUserPolicy") {
		t.Fatalf("description should still summarise the event: %q", d)
	}
}
