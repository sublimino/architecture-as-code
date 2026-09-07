package main

import (
	"flag"
	"fmt"
	"log"
	"net/http"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/node-capability-guard/pkg/webhook"
)

func main() {
	port := flag.Int("port", 8443, "port to listen on")
	tlsCert := flag.String("tls-cert", "", "path to TLS certificate")
	tlsKey := flag.String("tls-key", "", "path to TLS private key")
	flag.Parse()

	http.HandleFunc("/validate", webhook.HandleValidate)
	http.HandleFunc("/metrics", webhook.HandleMetrics)
	http.HandleFunc("/healthz", webhook.HandleHealthz)

	addr := fmt.Sprintf(":%d", *port)
	log.Printf("node-capability-guard listening on %s", addr)

	if *tlsCert != "" && *tlsKey != "" {
		if err := http.ListenAndServeTLS(addr, *tlsCert, *tlsKey, nil); err != nil {
			log.Fatalf("failed to serve TLS: %v", err)
		}
	} else {
		if err := http.ListenAndServe(addr, nil); err != nil {
			log.Fatalf("failed to serve HTTP: %v", err)
		}
	}
}
