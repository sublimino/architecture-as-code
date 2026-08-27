// prod-deploy-gate: HMAC token generation and validation tests.
//
// TDD RED phase — these tests define the contract for the token package:
//   - Generate produces a valid HMAC-SHA256 token with embedded expiry
//   - Validate accepts a fresh token
//   - Validate rejects an expired token
//   - Validate rejects a tampered token
//   - Validate rejects an empty/malformed token
package main

import (
	"testing"
	"time"
)

func TestGenerateToken(t *testing.T) {
	secret := []byte("test-hmac-secret-32-bytes-long!!")
	requestID := "deploy-req-001"

	tok, err := GenerateToken(secret, requestID, 30*time.Minute)
	if err != nil {
		t.Fatalf("GenerateToken failed: %v", err)
	}
	if tok == "" {
		t.Fatal("GenerateToken returned empty token")
	}
}

func TestValidateToken_Fresh(t *testing.T) {
	secret := []byte("test-hmac-secret-32-bytes-long!!")
	requestID := "deploy-req-002"

	tok, err := GenerateToken(secret, requestID, 30*time.Minute)
	if err != nil {
		t.Fatalf("GenerateToken failed: %v", err)
	}

	gotID, err := ValidateToken(secret, tok)
	if err != nil {
		t.Fatalf("ValidateToken failed on fresh token: %v", err)
	}
	if gotID != requestID {
		t.Errorf("ValidateToken returned requestID=%q, want %q", gotID, requestID)
	}
}

func TestValidateToken_Expired(t *testing.T) {
	secret := []byte("test-hmac-secret-32-bytes-long!!")
	requestID := "deploy-req-003"

	// Generate with 1ms TTL, then sleep past it.
	tok, err := GenerateToken(secret, requestID, 1*time.Millisecond)
	if err != nil {
		t.Fatalf("GenerateToken failed: %v", err)
	}

	time.Sleep(5 * time.Millisecond)

	_, err = ValidateToken(secret, tok)
	if err == nil {
		t.Fatal("ValidateToken should reject expired token")
	}
	if err != ErrTokenExpired {
		t.Errorf("ValidateToken error=%v, want ErrTokenExpired", err)
	}
}

func TestValidateToken_Tampered(t *testing.T) {
	secret := []byte("test-hmac-secret-32-bytes-long!!")
	requestID := "deploy-req-004"

	tok, err := GenerateToken(secret, requestID, 30*time.Minute)
	if err != nil {
		t.Fatalf("GenerateToken failed: %v", err)
	}

	// Flip a character in the token.
	tampered := []byte(tok)
	if tampered[0] == 'a' {
		tampered[0] = 'b'
	} else {
		tampered[0] = 'a'
	}

	_, err = ValidateToken(secret, string(tampered))
	if err == nil {
		t.Fatal("ValidateToken should reject tampered token")
	}
	if err != ErrTokenInvalid {
		t.Errorf("ValidateToken error=%v, want ErrTokenInvalid", err)
	}
}

func TestValidateToken_WrongSecret(t *testing.T) {
	secret1 := []byte("test-hmac-secret-32-bytes-long!!")
	secret2 := []byte("different-secret-32-bytes-long!!")
	requestID := "deploy-req-005"

	tok, err := GenerateToken(secret1, requestID, 30*time.Minute)
	if err != nil {
		t.Fatalf("GenerateToken failed: %v", err)
	}

	_, err = ValidateToken(secret2, tok)
	if err == nil {
		t.Fatal("ValidateToken should reject token signed with different secret")
	}
}

func TestValidateToken_Empty(t *testing.T) {
	secret := []byte("test-hmac-secret-32-bytes-long!!")

	_, err := ValidateToken(secret, "")
	if err == nil {
		t.Fatal("ValidateToken should reject empty token")
	}
}

func TestValidateToken_Malformed(t *testing.T) {
	secret := []byte("test-hmac-secret-32-bytes-long!!")

	_, err := ValidateToken(secret, "not-a-valid-token")
	if err == nil {
		t.Fatal("ValidateToken should reject malformed token")
	}
}
