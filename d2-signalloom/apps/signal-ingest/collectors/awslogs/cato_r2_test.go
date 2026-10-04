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
