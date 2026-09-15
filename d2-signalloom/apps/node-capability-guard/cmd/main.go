// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package main

import (
	"flag"
	"fmt"
	"log"
	"net/http"
	"os"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/node-capability-guard/pkg/webhook"
)

func main() {
	port := flag.Int("port", 8443, "port to listen on")
	tlsCert := flag.String("tls-cert", "", "path to TLS certificate")
	tlsKey := flag.String("tls-key", "", "path to TLS private key")
	storeFile := flag.String("store-file", "", "path to contained identities JSON file")
	trustDomain := flag.String("trust-domain", "signalloom.demo", "SPIFFE trust domain")
	flag.Parse()

	// Environment variable overrides
	if envStore := os.Getenv("CONTAINED_STORE_FILE"); envStore != "" && *storeFile == "" {
		*storeFile = envStore
	}
	if envTD := os.Getenv("SPIFFE_TRUST_DOMAIN"); envTD != "" {
		*trustDomain = envTD
	}

	var store webhook.ContainedIdentityStore
	if *storeFile != "" {
		fs, err := webhook.NewFileIdentityStore(*storeFile)
		if err != nil {
			log.Fatalf("failed to initialize file identity store (%s): %v", *storeFile, err)
		}
		store = fs
		log.Printf("node-capability-guard using file store: %s", *storeFile)
	} else {
		store = webhook.NewMemoryIdentityStore()
		log.Printf("node-capability-guard using in-memory identity store")
	}

	server := webhook.NewWebhookServer(store, *trustDomain)
	webhook.SetDefaultStore(store)

	http.HandleFunc("/validate", server.HandleValidate)
	http.HandleFunc("/metrics", webhook.HandleMetrics)
	http.HandleFunc("/healthz", webhook.HandleHealthz)

	addr := fmt.Sprintf(":%d", *port)
	log.Printf("node-capability-guard listening on %s (trust-domain=%s)", addr, *trustDomain)

	if *tlsCert != "" && *tlsKey != "" {
		if err := http.ListenAndServeTLS(addr, *tlsCert, *tlsKey, nil); err != nil {
			log.Fatalf("failed to serve TLS: %v", err)
		}
	} else {
		log.Printf("WARN: running without TLS (test mode)")
		if err := http.ListenAndServe(addr, nil); err != nil {
			log.Fatalf("failed to serve HTTP: %v", err)
		}
	}
}
