package kitsecrets

import (
	"fmt"
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// SecretTypeNames are the type NAMES treated as credentials.
//
// A name list rather than a type analysis, because type analysis needs a module
// and this file's whole advantage is that it does not. The list is a
// declaration of intent: a service adds its own (`Credentials`, `Bearer`,
// `SigningKey`) and the analyzer covers the types that use them.
//
// Naming a type here does NOT flag that type. It flags the types that HOLD one.
var SecretTypeNames = []string{
	"Token",
	"Secret",
	"Credential",
	"Credentials",
	"APIKey",
	"Password",
	"PrivateKey",
	"SigningKey",
	"Bearer",
	"Session",
}

// CoverageFinding is one printable credential-bearing type.
type CoverageFinding struct {
	Package string
	Type string
	Method string
	Pos string
}

// String renders a finding for a test failure. It deliberately does not quote
// the method's body: the body is where the credential is.
func (f CoverageFinding) String() string {
	return fmt.Sprintf("%s: %s declares %s() while holding a credential type", f.Pos, f.Type, f.Method)
}

// TypeCoverage reports every credential-bearing type in dirs that declares
// String() string or Error() string.
//
// dirs are directories, walked for .go files. Passing a file works too, because
// the walk is the same either way and a service that wants one file should not
// have to make a directory to say so.
func TypeCoverage(dirs []string) ([]CoverageFinding, error) {
	secret := make(map[string]bool, len(SecretTypeNames))
	for _, n := range SecretTypeNames {
		secret[n] = true
	}

	var findings []CoverageFinding
	for _, dir := range dirs {
		files, err := goFiles(dir)
		if err != nil {
			return nil, err
		}
		for _, path := range files {
			fset := token.NewFileSet()
			parsed, err := parser.ParseFile(fset, path, nil, 0)
			if err != nil {
				return nil, fmt.Errorf("kitsecrets: %s does not parse: %w", path, err)
			}
			findings = append(findings, scanFile(fset, parsed, path, secret)...)
		}
	}
	sort.Slice(findings, func(i, j int) bool {
		if findings[i].Pos != findings[j].Pos {
			return findings[i].Pos < findings[j].Pos
		}
		return findings[i].Method < findings[j].Method
	})
	return findings, nil
}

func scanFile(fset *token.FileSet, file *ast.File, path string, secret map[string]bool) []CoverageFinding {
	holders := map[string]bool{}
	for _, decl := range file.Decls {
		gen, ok := decl.(*ast.GenDecl)
		if !ok || gen.Tok != token.TYPE {
			continue
		}
		for _, spec := range gen.Specs {
			ts, ok := spec.(*ast.TypeSpec)
			if !ok {
				continue
			}
			if holdsSecret(ts.Type, secret) {
				holders[ts.Name.Name] = true
			}
		}
	}

	var findings []CoverageFinding
	for _, decl := range file.Decls {
		fn, ok := decl.(*ast.FuncDecl)
		if !ok || fn.Recv == nil || len(fn.Recv.List) == 0 {
			continue
		}
		name := printableName(fn)
		if name != "String" && name != "Error" {
			continue
		}
		recv := exprName(fn.Recv.List[0].Type)
		if !holders[recv] {
			continue
		}
		findings = append(findings, CoverageFinding{
			Package: path,
			Type:    recv,
			Method:  name,
			Pos:     fset.Position(fn.Pos()).String(),
		})
	}
	return findings
}

func printableName(fn *ast.FuncDecl) string {
	switch fn.Name.Name {
	case "String":
		if fn.Type.Params != nil && len(fn.Type.Params.List) != 0 {
			return ""
		}
		if fn.Type.Results == nil || len(fn.Type.Results.List) != 1 {
			return ""
		}
		return "String"
	case "Error":
		if fn.Type.Params != nil && len(fn.Type.Params.List) != 0 {
			return ""
		}
		if fn.Type.Results == nil || len(fn.Type.Results.List) != 0 {
			return ""
		}
		return "Error"
	}
	return ""
}

func holdsSecret(expr ast.Expr, secret map[string]bool) bool {
	found := false
	ast.Inspect(expr, func(n ast.Node) bool {
		if found {
			return false
		}
		switch t := n.(type) {
		case *ast.Ident:
			if secret[t.Name] {
				found = true
				return false
			}
		case *ast.SelectorExpr:
			if secret[t.Sel.Name] {
				found = true
				return false
			}
		}
		return true
	})
	return found
}

func exprName(expr ast.Expr) string {
	switch t := expr.(type) {
	case *ast.Ident:
		return t.Name
	case *ast.StarExpr:
		return exprName(t.X)
	case *ast.ArrayType:
		return exprName(t.Elt)
	case *ast.MapType:
		return exprName(t.Value)
	case *ast.SelectorExpr:
		return t.Sel.Name
	}
	return ""
}

func goFiles(dir string) ([]string, error) {
	info, err := os.Stat(dir)
	if err != nil {
		return nil, fmt.Errorf("kitsecrets: cannot read %s: %w", dir, err)
	}
	if !info.IsDir() {
		if !strings.HasSuffix(dir, ".go") {
			return nil, fmt.Errorf("kitsecrets: %s is not a .go file", dir)
		}
		return []string{dir}, nil
	}

	var out []string
	err = filepath.Walk(dir, func(path string, fi os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		if fi.IsDir() {
			switch fi.Name() {
			case ".git", "vendor", "testdata", "node_modules":
				return filepath.SkipDir
			}
			return nil
		}
		if strings.HasSuffix(path, ".go") {
			out = append(out, path)
		}
		return nil
	})
	if err != nil {
		return nil, fmt.Errorf("kitsecrets: walking %s: %w", dir, err)
	}
	sort.Strings(out)
	if len(out) == 0 {
		return nil, fmt.Errorf("kitsecrets: no .go files under %s — a coverage check over nothing is not a check", dir)
	}
	return out, nil
}
