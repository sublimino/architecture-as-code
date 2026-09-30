// Command bao-glob evaluates an OpenBao bound_claims glob with the exact
// library OpenBao's JWT auth method links (github.com/ryanuber/go-glob
// v1.0.0, verified in openbao 2.1.1 and 2.7.0 via `go version -m`), so the
// role's glob can be tested adversarially without a live OpenBao.
//
// Usage: bao-glob PATTERN < subjects   (prints "match|nomatch<TAB>subject")
package main

import (
	"bufio"
	"fmt"
	"os"

	glob "github.com/ryanuber/go-glob"
)

func main() {
	if len(os.Args) != 2 {
		fmt.Fprintln(os.Stderr, "usage: bao-glob PATTERN < subjects")
		os.Exit(2)
	}
	in := bufio.NewScanner(os.Stdin)
	for in.Scan() {
		verdict := "nomatch"
		if glob.Glob(os.Args[1], in.Text()) {
			verdict = "match"
		}
		fmt.Printf("%s\t%s\n", verdict, in.Text())
	}
}
