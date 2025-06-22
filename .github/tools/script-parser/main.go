package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"time"

	"github.com/spf13/cobra"
	"mvdan.cc/sh/v3/syntax"
)

type Variable struct {
	Name   string `json:"name"`
	Value  string `json:"value"`
	Type   string `json:"type"`
	Line   uint   `json:"line"`
	Result string `json:"result,omitempty"`
	Source string `json:"source"`
}

type Config struct {
	Quiet     bool
	Verbose   bool
	JSON      bool
	Files     []string
	URLs      []string
	FromFile  string
	Extract   bool
	Transform bool
	Output    string
	Parallel  int
}

type ParseResult struct {
	Variables []Variable
	Source    string
	Error     error
}

var config Config

func main() {
	var rootCmd = &cobra.Command{
		Use:   "script-parser",
		Short: "Extract/Eval Variables from shell scripts",
		Example: `  script-parser -f script.sh
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
  script-parser --from-file sources.txt --transform --extract --parallel 4`,
		RunE: runParser,
	}

	rootCmd.Flags().StringArrayVarP(&config.Files, "file", "f", []string{}, "shell script file(s) to parse (can be specified multiple times)")
	rootCmd.Flags().StringArrayVarP(&config.URLs, "url", "u", []string{}, "URL(s) to download shell script from (can be specified multiple times)")
	rootCmd.Flags().StringVarP(&config.FromFile, "from-file", "l", "", "read file paths and URLs from a file (one per line)")
	rootCmd.Flags().StringVarP(&config.Output, "output", "o", "", "output file path (default: stdout)")
	rootCmd.Flags().IntVarP(&config.Parallel, "parallel", "p", 10, "number of files to process in parallel")
	rootCmd.Flags().BoolVarP(&config.Quiet, "quiet", "q", false, "only output variable assignments")
	rootCmd.Flags().BoolVarP(&config.Verbose, "verbose", "v", false, "verbose output with additional details")
	rootCmd.Flags().BoolVarP(&config.JSON, "json", "j", false, "output in JSON format")
	rootCmd.Flags().BoolVarP(&config.Extract, "extract", "e", false, "evaluate variables using bash and include results")
	rootCmd.Flags().BoolVarP(&config.Transform, "transform", "t", false, "transform URLs (Use Pkgforge APIs) before processing")

	// Add validation
	rootCmd.PreRunE = func(cmd *cobra.Command, args []string) error {
		if config.Parallel < 1 {
			return fmt.Errorf("parallel must be at least 1")
		}
		return nil
	}

	if err := rootCmd.Execute(); err != nil {
		os.Exit(1)
	}
}

func runParser(cmd *cobra.Command, args []string) error {
	var allSources []string
	var allVariables []Variable

	// Collect sources from --from-file first
	if config.FromFile != "" {
		fileSources, err := readSourcesFromFile(config.FromFile)
		if err != nil {
			return fmt.Errorf("error reading from file %s: %w", config.FromFile, err)
		}
		allSources = append(allSources, fileSources...)
	}

	// Collect all other sources
	for _, file := range config.Files {
		allSources = append(allSources, "file:"+file)
	}
	for _, url := range config.URLs {
		allSources = append(allSources, "url:"+url)
	}

	// Handle stdin if no sources specified
	if len(allSources) == 0 {
		variables, err := parseSource("stdin", os.Stdin)
		if err != nil {
			return err
		}
		allVariables = variables
	} else {
		// Parse multiple sources in parallel
		results := parseSourcesParallel(allSources)
		
		// Collect results and handle errors
		for _, result := range results {
			if result.Error != nil {
				if !config.Quiet {
					fmt.Fprintf(os.Stderr, "Error parsing %s: %v\n", result.Source, result.Error)
				}
				continue
			}
			allVariables = append(allVariables, result.Variables...)
		}
	}

	// Remove duplicates across all files
	allVariables = removeDuplicates(allVariables)

	// Extract/evaluate variables if requested
	if config.Extract {
		allVariables = extractVariableValues(allVariables)
	}

	// Output results
	var output io.Writer = os.Stdout
	if config.Output != "" {
		file, err := os.Create(config.Output)
		if err != nil {
			return fmt.Errorf("error creating output file: %w", err)
		}
		defer file.Close()
		output = file
	}

	if config.JSON {
		return outputJSON(allVariables, output)
	}

	if config.Quiet {
		return outputQuiet(allVariables, output)
	}

	return outputNormal(allVariables, allSources, output)
}

func parseSourcesParallel(sources []string) []ParseResult {
	jobs := make(chan string, len(sources))
	results := make(chan ParseResult, len(sources))

	// Start workers
	var wg sync.WaitGroup
	for i := 0; i < config.Parallel; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for source := range jobs {
				result := parseSourceWrapper(source)
				results <- result
			}
		}()
	}

	// Send jobs
	for _, source := range sources {
		jobs <- source
	}
	close(jobs)

	// Wait for completion
	go func() {
		wg.Wait()
		close(results)
	}()

	// Collect results
	var allResults []ParseResult
	for result := range results {
		allResults = append(allResults, result)
	}

	return allResults
}

func readSourcesFromFile(filename string) ([]string, error) {
	file, err := os.Open(filename)
	if err != nil {
		return nil, err
	}
	defer file.Close()

	var sources []string
	scanner := bufio.NewScanner(file)
	lineNum := 0

	for scanner.Scan() {
		lineNum++
		line := strings.TrimSpace(scanner.Text())
		
		// Skip empty lines and comments
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}

		// Determine if it's a URL or file path
		source, err := categorizeSource(line)
		if err != nil {
			if !config.Quiet {
				fmt.Fprintf(os.Stderr, "Warning: skipping invalid source on line %d: %s (%v)\n", lineNum, line, err)
			}
			continue
		}

		sources = append(sources, source)
	}

	if err := scanner.Err(); err != nil {
		return nil, fmt.Errorf("error reading file: %w", err)
	}

	return sources, nil
}

func categorizeSource(source string) (string, error) {
	// Check if it's a URL
	if isURL(source) {
		return "url:" + source, nil
	}

	// Check if it's a valid file path
	if _, err := os.Stat(source); err != nil {
		// Try to resolve relative path
		if absPath, absErr := filepath.Abs(source); absErr == nil {
			if _, statErr := os.Stat(absPath); statErr == nil {
				return "file:" + absPath, nil
			}
		}
		return "", fmt.Errorf("file does not exist: %s", source)
	}

	return "file:" + source, nil
}

func isURL(str string) bool {
	u, err := url.Parse(str)
	return err == nil && u.Scheme != "" && u.Host != ""
}

func applyURLTransformations(url string) string {
	// Transform /blob/ to /raw/ in URLs
	blobPattern := regexp.MustCompile(`/blob/`)
	url = blobPattern.ReplaceAllString(url, "/raw/")
	
	// Add other URL transformations here if needed
	return url
}

func parseSourceWrapper(source string) ParseResult {
	if strings.HasPrefix(source, "file:") {
		filePath := strings.TrimPrefix(source, "file:")
		file, err := os.Open(filePath)
		if err != nil {
			return ParseResult{Error: fmt.Errorf("error opening file: %w", err), Source: filePath}
		}
		defer file.Close()

		// Get absolute path for source
		absPath, err := filepath.Abs(filePath)
		if err != nil {
			absPath = filePath // fallback to original path
		}

		variables, err := parseSource(absPath, file)
		return ParseResult{Variables: variables, Source: absPath, Error: err}
	} else if strings.HasPrefix(source, "url:") {
		url := strings.TrimPrefix(source, "url:")
		if config.Transform {
			url = applyURLTransformations(url)
		}
		resp, err := downloadScript(url)
		if err != nil {
			return ParseResult{Error: fmt.Errorf("error downloading script: %w", err), Source: url}
		}
		defer resp.Body.Close()

		variables, err := parseSource(url, resp.Body)
		return ParseResult{Variables: variables, Source: url, Error: err}
	}

	return ParseResult{Error: fmt.Errorf("unknown source type: %s", source), Source: source}
}

func parseSource(sourceName string, input io.Reader) ([]Variable, error) {
	var reader io.Reader = input

	// Apply transformations if requested
	if config.Transform {
		content, err := io.ReadAll(input)
		if err != nil {
			return nil, fmt.Errorf("error reading content for transformation: %w", err)
		}

		transformedContent := applyTransformations(string(content))
		reader = strings.NewReader(transformedContent)

		if config.Verbose && !config.Quiet {
			fmt.Fprintf(os.Stderr, "Applied transformations to %s\n", sourceName)
		}
	}

	// Parse the shell script
	parser := syntax.NewParser()
	file, err := parser.Parse(reader, sourceName)
	if err != nil {
		return nil, fmt.Errorf("error parsing shell script: %w", err)
	}

	// Extract variables
	variables := extractVariables(file, sourceName)
	return variables, nil
}

func downloadScript(url string) (*http.Response, error) {
	client := &http.Client{
		Timeout: 30 * time.Second,
	}

	resp, err := client.Get(url)
	if err != nil {
		return nil, fmt.Errorf("failed to download script: %w", err)
	}

	if resp.StatusCode != http.StatusOK {
		resp.Body.Close()
		return nil, fmt.Errorf("failed to download script: HTTP %d", resp.StatusCode)
	}

	return resp, nil
}

func extractVariableValues(variables []Variable) []Variable {
	for i, v := range variables {
		// Apply transformations to the value before evaluation if transform is enabled
		value := v.Value
		if config.Transform {
			value = applyTransformations(value)
		}
		
		result := evaluateVariable(v.Name, value)
		variables[i].Result = result
		
		// Also update the original value if it was transformed
		if config.Transform && value != v.Value {
			variables[i].Value = value
		}
	}
	return variables
}

func applyTransformations(content string) string {
	// Create case-insensitive regex patterns for the transformations
	// Pattern 1: api.github.com -> api.gh.pkgforge.dev
	githubPattern := regexp.MustCompile(`(?i)api\.github\.com`)
	content = githubPattern.ReplaceAllString(content, "api.gh.pkgforge.dev")
	
	// Pattern 2: repology.org -> api.rl.pkgforge.dev  
	repologyPattern := regexp.MustCompile(`(?i)repology\.org`)
	content = repologyPattern.ReplaceAllString(content, "api.rl.pkgforge.dev")
	
	return content
}

func evaluateVariable(name, value string) string {
	// Create a temporary bash script to evaluate the variable
	script := fmt.Sprintf("#!/bin/bash\n%s=%s\necho \"${%s}\"", name, value, name)
	
	cmd := exec.Command("bash", "-c", script)
	output, err := cmd.Output()
	if err != nil {
		// If evaluation fails, return the error info
		if exitError, ok := err.(*exec.ExitError); ok {
			return fmt.Sprintf("ERROR: %s", string(exitError.Stderr))
		}
		return fmt.Sprintf("ERROR: %s", err.Error())
	}
	
	return strings.TrimSpace(string(output))
}

func extractVariables(file *syntax.File, sourceName string) []Variable {
	var variables []Variable
	seen := make(map[string]bool)

	syntax.Walk(file, func(node syntax.Node) bool {
		switch n := node.(type) {
		case *syntax.Assign:
			if n.Name != nil {
				key := fmt.Sprintf("%s:%d", n.Name.Value, n.Pos().Line())
				if !seen[key] {
					seen[key] = true
					value, varType := getWordValue(n.Value)
					variables = append(variables, Variable{
						Name:   n.Name.Value,
						Value:  value,
						Type:   varType,
						Line:   n.Pos().Line(),
						Source: sourceName,
					})
				}
			}
		case *syntax.CallExpr:
			for _, assign := range n.Assigns {
				if assign.Name != nil {
					key := fmt.Sprintf("%s:%d", assign.Name.Value, assign.Pos().Line())
					if !seen[key] {
						seen[key] = true
						value, varType := getWordValue(assign.Value)
						variables = append(variables, Variable{
							Name:   assign.Name.Value,
							Value:  value,
							Type:   varType,
							Line:   assign.Pos().Line(),
							Source: sourceName,
						})
					}
				}
			}
		}
		return true
	})

	return variables
}

func getWordValue(word *syntax.Word) (string, string) {
	if word == nil {
		return "", "empty"
	}

	var result strings.Builder
	varType := "literal"

	for _, part := range word.Parts {
		switch p := part.(type) {
		case *syntax.Lit:
			result.WriteString(p.Value)
		case *syntax.SglQuoted:
			result.WriteString("'" + p.Value + "'")
			varType = "quoted"
		case *syntax.DblQuoted:
			varType = "quoted"
			result.WriteString(`"`)
			for _, dqPart := range p.Parts {
				if lit, ok := dqPart.(*syntax.Lit); ok {
					result.WriteString(lit.Value)
				} else if param, ok := dqPart.(*syntax.ParamExp); ok {
					if param.Param != nil {
						result.WriteString("$" + param.Param.Value)
					}
				} else if cmdSub, ok := dqPart.(*syntax.CmdSubst); ok {
					result.WriteString("$(")
					for i, stmt := range cmdSub.Stmts {
						if i > 0 {
							result.WriteString("; ")
						}
						result.WriteString(formatStatement(stmt))
					}
					result.WriteString(")")
				}
			}
			result.WriteString(`"`)
		case *syntax.CmdSubst:
			varType = "command"
			result.WriteString("$(")
			// Extract the actual command for later bash execution
			for i, stmt := range p.Stmts {
				if i > 0 {
					result.WriteString("; ")
				}
				result.WriteString(formatStatement(stmt))
			}
			result.WriteString(")")
		case *syntax.ParamExp:
			varType = "parameter"
			result.WriteString("$")
			if p.Param != nil {
				result.WriteString(p.Param.Value)
			}
		case *syntax.ArithmExp:
			varType = "arithmetic"
			result.WriteString("$((")
			if p.X != nil {
				result.WriteString(formatArithmetic(p.X))
			}
			result.WriteString("))")
		}
	}
	return result.String(), varType
}

func formatStatement(stmt *syntax.Stmt) string {
	if stmt.Cmd == nil {
		return ""
	}
	
	switch cmd := stmt.Cmd.(type) {
	case *syntax.CallExpr:
		var parts []string
		for _, word := range cmd.Args {
			if word != nil {
				parts = append(parts, formatWordWithQuotes(word))
			}
		}
		return strings.Join(parts, " ")
	case *syntax.BinaryCmd:
		// Handle pipelines and other binary commands
		left := formatStatement(cmd.X)
		right := formatStatement(cmd.Y)
		op := ""
		switch cmd.Op {
		case syntax.Pipe:
			op = " | "
		case syntax.PipeAll:
			op = " |& "
		case syntax.AndStmt:
			op = " && "
		case syntax.OrStmt:
			op = " || "
		default:
			op = " " + cmd.Op.String() + " "
		}
		return left + op + right
	default:
		return "..."
	}
}

func formatWordWithQuotes(word *syntax.Word) string {
	if word == nil {
		return ""
	}

	var result strings.Builder
	for _, part := range word.Parts {
		switch p := part.(type) {
		case *syntax.Lit:
			result.WriteString(p.Value)
		case *syntax.SglQuoted:
			result.WriteString("'" + p.Value + "'")
		case *syntax.DblQuoted:
			result.WriteString(`"`)
			for _, dqPart := range p.Parts {
				if lit, ok := dqPart.(*syntax.Lit); ok {
					result.WriteString(lit.Value)
				} else if param, ok := dqPart.(*syntax.ParamExp); ok {
					if param.Param != nil {
						result.WriteString("$" + param.Param.Value)
					}
				}
			}
			result.WriteString(`"`)
		case *syntax.ParamExp:
			result.WriteString("$")
			if p.Param != nil {
				result.WriteString(p.Param.Value)
			}
		}
	}
	return result.String()
}

func formatArithmetic(expr syntax.ArithmExpr) string {
	switch e := expr.(type) {
	case *syntax.BinaryArithm:
		left := formatArithmetic(e.X)
		right := formatArithmetic(e.Y)
		return fmt.Sprintf("%s %s %s", left, e.Op.String(), right)
	case *syntax.Word:
		val, _ := getWordValue(e)
		return val
	default:
		return "..."
	}
}

func removeDuplicates(variables []Variable) []Variable {
	seen := make(map[string]bool)
	var result []Variable
	
	for _, v := range variables {
		key := fmt.Sprintf("%s:%d:%s:%s", v.Name, v.Line, v.Value, v.Source)
		if !seen[key] {
			seen[key] = true
			result = append(result, v)
		}
	}
	
	return result
}

func outputJSON(variables []Variable, output io.Writer) error {
	data, err := json.MarshalIndent(variables, "", "  ")
	if err != nil {
		return fmt.Errorf("error marshaling JSON: %w", err)
	}
	fmt.Fprintln(output, string(data))
	return nil
}

func outputQuiet(variables []Variable, output io.Writer) error {
	for _, v := range variables {
		if config.Extract && v.Result != "" {
			fmt.Fprintf(output, "%s=%s\n", v.Name, v.Result)
		} else {
			fmt.Fprintf(output, "%s=%s\n", v.Name, v.Value)
		}
	}
	return nil
}

func outputNormal(variables []Variable, sources []string, output io.Writer) error {
	if len(sources) == 0 {
		sources = []string{"stdin"}
	}

	if !config.Verbose {
		if len(sources) == 1 {
			fmt.Fprintf(output, "Variables found in %s:\n", sources[0])
		} else {
			fmt.Fprintf(output, "Variables found in %d sources:\n", len(sources))
		}
		fmt.Fprintln(output, strings.Repeat("-", 50))
	} else {
		if len(sources) == 1 {
			fmt.Fprintf(output, "Parsing %s...\n", sources[0])
		} else {
			fmt.Fprintf(output, "Parsing %d sources...\n", len(sources))
		}
		fmt.Fprintf(output, "Found %d variables:\n", len(variables))
		fmt.Fprintln(output, strings.Repeat("=", 60))
	}

	for _, v := range variables {
		if config.Verbose {
			if config.Extract && v.Result != "" {
				fmt.Fprintf(output, "Source: %s | Line %d | Type: %-10s | %s = %s -> %s\n", 
					v.Source, v.Line, v.Type, v.Name, v.Value, v.Result)
			} else {
				fmt.Fprintf(output, "Source: %s | Line %d | Type: %-10s | %s = %s\n", 
					v.Source, v.Line, v.Type, v.Name, v.Value)
			}
		} else {
			if config.Extract && v.Result != "" {
				fmt.Fprintf(output, "%s:%d: %s = %s -> %s\n", 
					filepath.Base(v.Source), v.Line, v.Name, v.Value, v.Result)
			} else {
				fmt.Fprintf(output, "%s:%d: %s = %s\n", 
					filepath.Base(v.Source), v.Line, v.Name, v.Value)
			}
		}
	}

	if config.Verbose {
		fmt.Fprintln(output, strings.Repeat("=", 60))
		fmt.Fprintf(output, "Total: %d variables from %d sources\n", len(variables), len(sources))
	}

	return nil
}