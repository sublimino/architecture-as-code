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

func TestGenerateToken_BoundsAndValidation(t *testing.T) {
	secret := []byte("test-hmac-secret-32-bytes-long!!")

	if _, err := GenerateToken(nil, "req-1", 10*time.Minute); err == nil {
		t.Fatal("GenerateToken should reject empty secret")
	}
	if _, err := GenerateToken(secret, "   ", 10*time.Minute); err == nil {
		t.Fatal("GenerateToken should reject whitespace requestID")
	}
	longID := ""
	for i := 0; i < 129; i++ {
		longID += "a"
	}
	if _, err := GenerateToken(secret, longID, 10*time.Minute); err == nil {
		t.Fatal("GenerateToken should reject requestID exceeding 128 characters")
	}
	if _, err := GenerateToken(secret, "req-1", 0); err == nil {
		t.Fatal("GenerateToken should reject zero TTL")
	}
	if _, err := GenerateToken(secret, "req-1", -5*time.Minute); err == nil {
		t.Fatal("GenerateToken should reject negative TTL")
	}
	if _, err := GenerateToken(secret, "req-1", 25*time.Hour); err == nil {
		t.Fatal("GenerateToken should reject TTL exceeding 24 hours")
	}
}

func TestValidateToken_Adversarial(t *testing.T) {
	secret := []byte("test-hmac-secret-32-bytes-long!!")
	tok, err := GenerateToken(secret, "req-valid", 10*time.Minute)
	if err != nil {
		t.Fatalf("GenerateToken failed: %v", err)
	}

	// 1. Empty secret rejection
	if _, err := ValidateToken(nil, tok); err != ErrTokenInvalid {
		t.Errorf("ValidateToken with empty secret = %v, want ErrTokenInvalid", err)
	}

	// 2. Trailing dot injection
	if _, err := ValidateToken(secret, tok+".extra"); err != ErrTokenMalformed {
		t.Errorf("ValidateToken with trailing dot segment = %v, want ErrTokenMalformed", err)
	}

	// 3. Oversized token
	oversized := tok
	for len(oversized) < 2050 {
		oversized += "a"
	}
	if _, err := ValidateToken(secret, oversized); err != ErrTokenMalformed {
		t.Errorf("ValidateToken with oversized token = %v, want ErrTokenMalformed", err)
	}
}

