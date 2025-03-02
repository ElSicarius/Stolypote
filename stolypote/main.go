package main

import (
	"bufio"
	"bytes"
	"encoding/base64"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"mime"
	"mime/multipart"
	"net/http"
	"os"
	"path"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/google/uuid"
)

var listenAddr string

// In-container directories (mount "wordlists" from host)
const (
	DumpDir                = "/app/wordlists/dump/http"
	WordlistDir            = "/app/wordlists"
	ResponsesDir           = "/app/responses"
	ResponseFile           = "/app/config/responses.txt" // Response mappings
	PathsFilename          = "paths-honeypot.txt"
	UsersFilename          = "users-honeypot.txt"
	PasswordsFilename      = "passwords-honeypot.txt"
	CombosFilename         = "combo-user-pass-honeypot.txt"
	AuthorizationsFilename = "authorizations-honeypot.txt"
	ParametersFilename     = "parameters-honeypot.txt"
)

// Synchronized in-memory sets to avoid duplicates before appending to files
var (
	pathsSet          = map[string]bool{}
	extensionsSet     = map[string]map[string]bool{} // extension -> set of paths
	usersSet          = map[string]bool{}
	passwordsSet      = map[string]bool{}
	combosSet         = map[string]bool{}
	authorizationsSet = map[string]bool{}
	responseMap       = map[string]string{} // Extension -> Response File Mapping
	parametersSet     = map[string]bool{}

	mu sync.Mutex
)

// Patterns for possible user/password fields
var userKeys = []string{"u", "user", "username", "login", "email"}
var passKeys = []string{"p", "pass", "passwd", "password", "token", "pwd"}

func main() {
	// Default: listen on all interfaces inside Docker, port 65111
	flag.StringVar(&listenAddr, "listen", "0.0.0.0:65111", "Listening address")
	flag.Parse()

	// Ensure directories exist
	if err := os.MkdirAll(DumpDir, 0755); err != nil {
		log.Fatalf("Cannot create dump directory: %v", err)
	}
	if err := os.MkdirAll(WordlistDir, 0755); err != nil {
		log.Fatalf("Cannot create wordlist directory: %v", err)
	}

	// Preload all the response files
	loadResponseMappings()

	// Preload existing wordlists to avoid duplicates
	preloadWordlists()

	// Start the honeypot HTTP server
	mux := http.NewServeMux()
	mux.HandleFunc("/", handleHoneypot)

	srv := &http.Server{
		Addr:    listenAddr,
		Handler: mux,
	}

	log.Printf("[+] Starting Go honeypot on %s ...", listenAddr)
	if err := srv.ListenAndServe(); err != nil {
		log.Fatalf("[!] Honeypot server failed: %v", err)
	}
}

// handleHoneypot logs requests and extracts data
func handleHoneypot(w http.ResponseWriter, r *http.Request) {
	// Dump to JSON
	if err := logRequest(r); err != nil {
		log.Printf("[!] Failed to log request: %v", err)
	}
	// Extract interesting data (paths, credentials, param keys, etc.)
	extractData(r)

	serveCustomResponse(w, r)
}

// Loads response mappings from responses.txt
func loadResponseMappings() {
	f, err := os.Open(ResponseFile)
	if err != nil {
		log.Printf("[!] No response mapping file found, serving only 'ok' response.")
		return
	}
	defer f.Close()

	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}

		parts := strings.SplitN(line, "=", 2)
		if len(parts) != 2 {
			log.Printf("[!] Invalid format in responses.txt: %s", line)
			continue
		}

		key := strings.TrimSpace(parts[0])
		value := strings.TrimSpace(parts[1])

		// open the corresponding file and if it exists, set it's content
		fullPath := filepath.Join(ResponsesDir, value)
		if _, err := os.Stat(fullPath); err != nil {
			log.Printf("[!] Response file %s does not exist", fullPath)
			continue
		}

		responseMap[key] = value
	}
	log.Printf("[+] Loaded response mappings: %+v", responseMap)
}

// Serves custom response if matched
func serveCustomResponse(w http.ResponseWriter, r *http.Request) {
	ext := strings.TrimPrefix(path.Ext(r.URL.Path), ".")
	fileKey := ext

	if r.URL.Path == "/robots.txt" {
		fileKey = "robots.txt"
	}

	if responseFile, exists := responseMap[fileKey]; exists {
		fullPath := filepath.Join(ResponsesDir, responseFile)

		data, err := os.ReadFile(fullPath)
		if err != nil {
			log.Printf("[!] Error reading response file %s: %v", fullPath, err)
			http.Error(w, "Internal Server Error", http.StatusInternalServerError)
			return
		}

		contentType := mime.TypeByExtension(filepath.Ext(responseFile))
		if contentType == "" {
			contentType = "text/plain"
		}

		w.Header().Set("Content-Type", contentType)
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write(data)

		log.Printf("[+] Served custom response for %s (%s)", r.URL.Path, responseFile)
		return
	}

	// Default fallback response
	w.Header().Set("Content-Type", "text/plain")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write([]byte("ok"))
}

// logRequest saves the raw request to a JSON file
func logRequest(r *http.Request) error {

	// console log the uri + path + query + method + port + protocol
	fmt.Printf("Inc Request: M:%s P:%s Q:%s Proto:%s Against:%s\n", r.Method, r.URL.Path, r.URL.RawQuery, r.Proto, r.Host)
	data := map[string]interface{}{
		"time":        time.Now().Format(time.RFC3339),
		"method":      r.Method,
		"url":         r.URL.String(),
		"proto":       r.Proto,
		"remote_addr": r.RemoteAddr,
	}

	hdr := map[string]interface{}{}
	for k, vv := range r.Header {
		if len(vv) == 1 {
			hdr[k] = vv[0]
		} else {
			hdr[k] = vv
		}
	}
	data["headers"] = hdr

	bodyBytes, err := io.ReadAll(r.Body)
	if err == nil && len(bodyBytes) > 0 {
		data["body"] = string(bodyBytes)
	}
	r.Body.Close()
	r.Body = io.NopCloser(bytes.NewReader(bodyBytes))

	filename := filepath.Join(DumpDir, uuid.NewString()+".json")
	f, err := os.Create(filename)
	if err != nil {
		return fmt.Errorf("create dump file: %w", err)
	}
	defer f.Close()

	enc := json.NewEncoder(f)
	enc.SetIndent("", "  ")
	if err := enc.Encode(data); err != nil {
		return fmt.Errorf("encode json: %w", err)
	}
	return nil
}

// extractData looks for paths, extensions, user/pass combos, param keys, etc.
func extractData(r *http.Request) {
	mu.Lock()
	defer mu.Unlock()

	// 1) Path
	thePath := r.URL.Path
	addToWordlist(PathsFilename, thePath, pathsSet)

	// If the path has a file extension (e.g. .php), store in <ext>-honeypot.txt
	ext := path.Ext(thePath) // includes the dot, e.g. ".php"
	if len(ext) > 1 {
		extension := ext[1:] // "php"
		if extensionsSet[extension] == nil {
			extensionsSet[extension] = map[string]bool{}
		}
		addToWordlist(extension+"-honeypot.txt", thePath, extensionsSet[extension])
	}

	// 2) Credentials in URL userinfo (http://user:pass@host)
	if r.URL.User != nil {
		u := r.URL.User.Username()
		p, _ := r.URL.User.Password()
		if u != "" {
			addToWordlist(UsersFilename, u, usersSet)
		}
		if p != "" {
			addToWordlist(PasswordsFilename, p, passwordsSet)
		}
		if u != "" && p != "" {
			combo := fmt.Sprintf("%s:%s", u, p)
			addToWordlist(CombosFilename, combo, combosSet)
		}
	}

	// 3) Authorization header
	auth := r.Header.Get("Authorization")
	if auth != "" {
		addToWordlist(AuthorizationsFilename, auth, authorizationsSet)
		// Attempt to parse Basic
		if strings.HasPrefix(strings.ToLower(auth), "basic ") {
			enc := strings.TrimSpace(auth[5:])
			dec, err := base64.StdEncoding.DecodeString(enc)
			if err == nil {
				parts := strings.SplitN(string(dec), ":", 2)
				if len(parts) == 2 {
					user, pass := parts[0], parts[1]
					addToWordlist(UsersFilename, user, usersSet)
					addToWordlist(PasswordsFilename, pass, passwordsSet)
					addToWordlist(CombosFilename, fmt.Sprintf("%s:%s", user, pass), combosSet)
				}
			}
		}
	}

	// 4) Query parameters
	q := r.URL.Query()
	for k, vv := range q {
		// Log the parameter name
		addToWordlist(ParametersFilename, k, parametersSet)
		// Check for user/pass patterns
		for _, v := range vv {
			checkSingleParam(k, v)
		}
	}

	// 5) POST body
	ctype := r.Header.Get("Content-Type")
	switch {
	case strings.HasPrefix(ctype, "application/x-www-form-urlencoded"):
		_ = r.ParseForm() // merges GET + POST
		for k, vv := range r.Form {
			addToWordlist(ParametersFilename, k, parametersSet)
			for _, v := range vv {
				checkSingleParam(k, v)
			}
		}
	case strings.HasPrefix(ctype, "multipart/form-data"):
		mediatype, params, _ := mime.ParseMediaType(ctype)
		if mediatype == "multipart/form-data" {
			boundary := params["boundary"]
			if boundary != "" {
				mr := multipart.NewReader(r.Body, boundary)
				form, err := mr.ReadForm(32 << 20)
				if err == nil {
					for k, vv := range form.Value {
						addToWordlist(ParametersFilename, k, parametersSet)
						for _, v := range vv {
							checkSingleParam(k, v)
						}
					}
				}
			}
		}
	case strings.HasPrefix(ctype, "application/json"):
		// Attempt naive JSON parse
		var bodyMap map[string]interface{}
		dec := json.NewDecoder(r.Body)
		if err := dec.Decode(&bodyMap); err == nil {
			checkBodyMap(bodyMap)
		}
	case strings.Contains(ctype, "xml"):
		// Very simple approach to scan for possible <key>value</key>
		raw, _ := io.ReadAll(r.Body)
		lower := strings.ToLower(string(raw))
		// We can do a simplistic "tag search"
		// We'll also attempt to track parameter names
		for _, key := range append(userKeys, passKeys...) {
			// e.g. <username> ... </username>
			openTag := "<" + key + ">"
			closeTag := "</" + key + ">"
			idx := 0
			for {
				i1 := strings.Index(lower[idx:], openTag)
				if i1 == -1 {
					break
				}
				i2 := strings.Index(lower[idx+i1:], closeTag)
				if i2 == -1 {
					break
				}
				start := idx + i1 + len(openTag)
				end := idx + i1 + i2
				val := strings.TrimSpace(lower[start:end])
				checkSingleParam(key, val)
				// move idx to beyond
				idx = idx + i1 + i2 + len(closeTag)
			}
			addToWordlist(ParametersFilename, key, parametersSet)
		}
	default:
		// For other content types, we do nothing fancy
	}
}

// checkSingleParam attempts user/pass detection
func checkSingleParam(k, v string) {
	klower := strings.ToLower(k)
	if inSlice(klower, userKeys) {
		addToWordlist(UsersFilename, v, usersSet)
	}
	if inSlice(klower, passKeys) {
		addToWordlist(PasswordsFilename, v, passwordsSet)
	}
}

// checkBodyMap recursively inspects JSON objects for user/pass
func checkBodyMap(m map[string]interface{}) {
	for k, v := range m {
		addToWordlist(ParametersFilename, k, parametersSet)
		klower := strings.ToLower(k)
		switch vv := v.(type) {
		case string:
			if inSlice(klower, userKeys) {
				addToWordlist(UsersFilename, vv, usersSet)
			}
			if inSlice(klower, passKeys) {
				addToWordlist(PasswordsFilename, vv, passwordsSet)
			}
		case map[string]interface{}:
			checkBodyMap(vv)
		case []interface{}:
			for _, it := range vv {
				if sub, ok := it.(map[string]interface{}); ok {
					checkBodyMap(sub)
				}
			}
		}
	}
}

// addToWordlist writes an item to file if not already in the set
func addToWordlist(filename, item string, set map[string]bool) {
	item = strings.TrimSpace(item)
	if item == "" {
		return
	}
	if set[item] {
		return
	}
	set[item] = true

	// If we see a "user:pass" combo, also store them separately
	if filename == CombosFilename {
		parts := strings.SplitN(item, ":", 2)
		if len(parts) == 2 {
			addToWordlist(UsersFilename, parts[0], usersSet)
			addToWordlist(PasswordsFilename, parts[1], passwordsSet)
		}
	}

	f, err := os.OpenFile(filepath.Join(WordlistDir, filename),
		os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0644)
	if err != nil {
		log.Printf("[!] Error writing %s: %v", filename, err)
		return
	}
	defer f.Close()

	_, _ = f.WriteString(item + "\n")
}

// preloadWordlists loads existing files (if any) into sets
func preloadWordlists() {
	loadFileIntoSet(filepath.Join(WordlistDir, PathsFilename), pathsSet)
	loadFileIntoSet(filepath.Join(WordlistDir, UsersFilename), usersSet)
	loadFileIntoSet(filepath.Join(WordlistDir, PasswordsFilename), passwordsSet)
	loadFileIntoSet(filepath.Join(WordlistDir, CombosFilename), combosSet)
	loadFileIntoSet(filepath.Join(WordlistDir, AuthorizationsFilename), authorizationsSet)
	loadFileIntoSet(filepath.Join(WordlistDir, ParametersFilename), parametersSet)

	// Also detect any existing extension files like "php-honeypot.txt"
	files, _ := os.ReadDir(WordlistDir)
	for _, fi := range files {
		name := fi.Name()
		if strings.HasSuffix(name, "-honeypot.txt") &&
			name != PathsFilename &&
			name != UsersFilename &&
			name != PasswordsFilename &&
			name != CombosFilename &&
			name != AuthorizationsFilename &&
			name != ParametersFilename {
			// e.g. "php-honeypot.txt" => "php"
			ext := strings.TrimSuffix(name, "-honeypot.txt")
			if extensionsSet[ext] == nil {
				extensionsSet[ext] = map[string]bool{}
			}
			loadFileIntoSet(filepath.Join(WordlistDir, name), extensionsSet[ext])
		}
	}
}

// loadFileIntoSet reads each line into the set
func loadFileIntoSet(filePath string, set map[string]bool) {
	f, err := os.Open(filePath)
	if err != nil {
		return
	}
	defer f.Close()

	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line != "" {
			set[line] = true
		}
	}
}

func inSlice(s string, arr []string) bool {
	for _, a := range arr {
		if s == a {
			return true
		}
	}
	return false
}
