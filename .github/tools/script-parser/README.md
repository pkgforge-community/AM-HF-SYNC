### ℹ️ About
Extract/Eval Variables from shell scripts.<br>

### 🧰 Usage
```mathematica
❯ script-parser --help

Extract/Eval Variables from shell scripts

Usage:
  script-parser [flags]

Examples:
  script-parser -f script.sh
  cat script.sh | script-parser
  script-parser --file script.sh --json
  script-parser -f script.sh --quiet
  script-parser -u https://example.com/script.sh --extract --json
  script-parser --url https://raw.githubusercontent.com/user/repo/main/script.sh --extract
  script-parser -f script1.sh -f script2.sh --parallel 2 --json -o results.json
  script-parser -u url1 -u url2 -f local.sh --parallel 3 --output combined.json
  script-parser --from-file sources.txt --parallel 4 --json -o results.json
  script-parser --from-file urls.txt --extract --verbose
  script-parser -f script.sh --transform --extract --json
  script-parser --from-file sources.txt --transform --extract --parallel 4

Flags:
  -e, --extract            evaluate variables using bash and include results
  -f, --file stringArray   shell script file(s) to parse (can be specified multiple times)
  -l, --from-file string   read file paths and URLs from a file (one per line)
  -h, --help               help for script-parser
  -j, --json               output in JSON format
  -o, --output string      output file path (default: stdout)
  -p, --parallel int       number of files to process in parallel (default 10)
  -q, --quiet              only output variable assignments
  -t, --transform          transform URLs (Use Pkgforge APIs) before processing
  -u, --url stringArray    URL(s) to download shell script from (can be specified multiple times)
  -v, --verbose            verbose output with additional details

```

### 🛠️ Building
```bash
CGO_ENABLED="0"
GOOS="linux"
GOARCH="amd64" #arm64,loong64,riscv64 etc

export CGO_ENABLED GOOS GOARCH
go build -a -v -x -trimpath \
         -buildvcs="false" \
         -ldflags="-s -w -buildid= -extldflags '-s -w -Wl,--build-id=none'" \
         -o "./script-parser-${GOARCH}"

"./script-parser-${GOARCH}" --help
```