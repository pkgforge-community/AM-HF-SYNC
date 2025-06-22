package main

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"strings"
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
}

type Config struct {
	Quiet   bool
	Verbose bool
	JSON    bool
	File    string
	URL     string
	Extract bool
}

var config Config

func main() {
	var rootCmd = &cobra.Command{
		Use:   "shell-parser",
		Short: "Extract variables from shell scripts",
		Long: `A modern CLI tool to parse shell scripts and extract variable assignments.
Supports reading from files, URLs, or stdin, with various output formats.`,
		Example: `  shell-parser -f script.sh
  cat script.sh | shell-parser
  shell-parser --file script.sh --json
  shell-parser -f script.sh --quiet
  shell-parser -u https://example.com/script.sh --extract --json
  shell-parser --url https://raw.githubusercontent.com/user/repo/main/script.sh --extract`,
		RunE: runParser,
	}

	rootCmd.Flags().StringVarP(&config.File, "file", "f", "", "shell script file to parse")
	rootCmd.Flags().StringVarP(&config.URL, "url", "u", "", "URL to download shell script from")
	rootCmd.Flags().BoolVarP(&config.Quiet, "quiet", "q", false, "only output variable assignments")
	rootCmd.Flags().BoolVarP(&config.Verbose, "verbose", "v", false, "verbose output with additional details")
	rootCmd.Flags().BoolVar(&config.JSON, "json", false, "output in JSON format")
	rootCmd.Flags().BoolVar(&config.Extract, "extract", false, "evaluate variables using bash and include results")

	// Add validation for mutually exclusive options
	rootCmd.PreRunE = func(cmd *cobra.Command, args []string) error {
		sources := 0
		if config.File != "" {
			sources++
		}
		if config.URL != "" {
			sources++
		}
		if sources > 1 {
			return fmt.Errorf("cannot specify both --file and --url options")
		}
		return nil
	}

	if err := rootCmd.Execute(); err != nil {
		os.Exit(1)
	}
}

func runParser(cmd *cobra.Command, args []string) error {
	var input io.Reader
	var sourceName string

	if config.File != "" {
		file, err := os.Open(config.File)
		if err != nil {
			return fmt.Errorf("error opening file: %w", err)
		}
		defer file.Close()
		input = file
		sourceName = config.File
	} else if config.URL != "" {
		resp, err := downloadScript(config.URL)
		if err != nil {
			return fmt.Errorf("error downloading script: %w", err)
		}
		defer resp.Body.Close()
		input = resp.Body
		sourceName = config.URL
	} else {
		input = os.Stdin
		sourceName = "stdin"
	}

	// Parse the shell script
	parser := syntax.NewParser()
	file, err := parser.Parse(input, sourceName)
	if err != nil {
		return fmt.Errorf("error parsing shell script: %w", err)
	}

	// Extract variables
	variables := extractVariables(file)

	// Remove duplicates
	variables = removeDuplicates(variables)

	// Extract/evaluate variables if requested
	if config.Extract {
		variables = extractVariableValues(variables)
	}

	// Output results
	if config.JSON {
		return outputJSON(variables)
	}

	if config.Quiet {
		return outputQuiet(variables)
	}

	return outputNormal(variables, sourceName)
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
		result := evaluateVariable(v.Name, v.Value)
		variables[i].Result = result
	}
	return variables
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

func extractVariables(file *syntax.File) []Variable {
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
						Name:  n.Name.Value,
						Value: value,
						Type:  varType,
						Line:  n.Pos().Line(),
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
							Name:  assign.Name.Value,
							Value: value,
							Type:  varType,
							Line:  assign.Pos().Line(),
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
		key := fmt.Sprintf("%s:%d:%s", v.Name, v.Line, v.Value)
		if !seen[key] {
			seen[key] = true
			result = append(result, v)
		}
	}
	
	return result
}

func outputJSON(variables []Variable) error {
	data, err := json.MarshalIndent(variables, "", "  ")
	if err != nil {
		return fmt.Errorf("error marshaling JSON: %w", err)
	}
	fmt.Println(string(data))
	return nil
}

func outputQuiet(variables []Variable) error {
	for _, v := range variables {
		if config.Extract && v.Result != "" {
			fmt.Printf("%s=%s\n", v.Name, v.Result)
		} else {
			fmt.Printf("%s=%s\n", v.Name, v.Value)
		}
	}
	return nil
}

func outputNormal(variables []Variable, sourceName string) error {
	if !config.Verbose {
		fmt.Printf("Variables found in %s:\n", sourceName)
		fmt.Println(strings.Repeat("-", 50))
	} else {
		fmt.Printf("Parsing %s...\n", sourceName)
		fmt.Printf("Found %d variables:\n", len(variables))
		fmt.Println(strings.Repeat("=", 60))
	}

	for _, v := range variables {
		if config.Verbose {
			if config.Extract && v.Result != "" {
				fmt.Printf("Line %d | Type: %-10s | %s = %s -> %s\n", v.Line, v.Type, v.Name, v.Value, v.Result)
			} else {
				fmt.Printf("Line %d | Type: %-10s | %s = %s\n", v.Line, v.Type, v.Name, v.Value)
			}
		} else {
			if config.Extract && v.Result != "" {
				fmt.Printf("Line %d: %s = %s -> %s\n", v.Line, v.Name, v.Value, v.Result)
			} else {
				fmt.Printf("Line %d: %s = %s\n", v.Line, v.Name, v.Value)
			}
		}
	}

	if config.Verbose {
		fmt.Println(strings.Repeat("=", 60))
		fmt.Printf("Total: %d variables\n", len(variables))
	}

	return nil
}