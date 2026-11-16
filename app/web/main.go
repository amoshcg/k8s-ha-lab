// web é a aplicação de demonstração do laboratório.
//
// Ela é propositalmente pequena, mas se comporta como uma aplicação real nos
// pontos que importam para o Kubernetes:
//
//   - demora STARTUP_DELAY para começar a aceitar conexões (como uma JVM aquecendo);
//   - expõe /healthz (liveness) e /readyz (readiness) separados;
//   - ao receber SIGTERM, passa a responder "não pronta" em /readyz, mas continua
//     atendendo por SHUTDOWN_DELAY para dar tempo de o Service tirá-la do
//     balanceamento, e só então encerra (graceful shutdown);
//   - com BROKEN=true (imagem v3) simula uma versão com defeito: nunca fica pronta,
//     responde 503 e morre depois de CRASH_AFTER ("não conectou ao banco");
//   - /admin/break, /admin/unready e /admin/crash injetam falhas em um pod em
//     execução; /admin/fix desfaz break e unready.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"sync/atomic"
	"syscall"
	"time"
)

type app struct {
	version string
	pod     string
	node    string
	podIP   string
	broken  bool
	started time.Time

	failing     atomic.Bool // /admin/break: pod "travado", liveness e readiness falham
	unready     atomic.Bool // /admin/unready: só a readiness falha
	terminating atomic.Bool // recebeu SIGTERM
}

func main() {
	log.SetFlags(log.LstdFlags | log.Lmicroseconds)

	hostname, _ := os.Hostname()
	a := &app{
		version: env("APP_VERSION", "dev"),
		pod:     env("POD_NAME", hostname),
		node:    env("NODE_NAME", "desconhecido"),
		podIP:   env("POD_IP", ""),
		broken:  env("BROKEN", "false") == "true",
	}
	startupDelay := envDuration("STARTUP_DELAY", 3*time.Second)
	shutdownDelay := envDuration("SHUTDOWN_DELAY", 5*time.Second)
	crashAfter := envDuration("CRASH_AFTER", 8*time.Second)
	port := env("PORT", "8080")

	log.Printf("iniciando versão=%s pod=%s nó=%s broken=%v", a.version, a.pod, a.node, a.broken)
	if startupDelay > 0 {
		log.Printf("aquecendo por %s (ainda sem aceitar conexões)", startupDelay)
		time.Sleep(startupDelay)
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/", a.handleRoot)
	mux.HandleFunc("/healthz", a.handleHealthz)
	mux.HandleFunc("/readyz", a.handleReadyz)
	mux.HandleFunc("/admin/break", a.handleBreak)
	mux.HandleFunc("/admin/unready", a.handleUnready)
	mux.HandleFunc("/admin/fix", a.handleFix)
	mux.HandleFunc("/admin/crash", a.handleCrash)

	ln, err := net.Listen("tcp", ":"+port)
	if err != nil {
		log.Fatalf("não foi possível abrir a porta %s: %v", port, err)
	}
	srv := &http.Server{Handler: a.withHeaders(mux), ReadHeaderTimeout: 5 * time.Second}
	go func() {
		if err := srv.Serve(ln); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Fatalf("servidor: %v", err)
		}
	}()
	a.started = time.Now()
	log.Printf("aceitando conexões na porta %s", port)

	if a.broken {
		go func() {
			time.Sleep(crashAfter)
			log.Printf("FATAL: não foi possível conectar ao banco de dados após %s; encerrando com erro", crashAfter)
			os.Exit(1)
		}()
	}

	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGTERM, syscall.SIGINT)
	s := <-sig
	name := "SIGTERM"
	if s == syscall.SIGINT {
		name = "SIGINT"
	}

	a.terminating.Store(true)
	log.Printf("%s recebido: /readyz passa a falhar; continuo atendendo por %s enquanto o Service me remove", name, shutdownDelay)
	time.Sleep(shutdownDelay)

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if err := srv.Shutdown(ctx); err != nil {
		log.Printf("shutdown: %v", err)
	}
	log.Printf("encerrado sem erros")
}

func (a *app) withHeaders(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		h := w.Header()
		h.Set("X-Pod", a.pod)
		h.Set("X-Node", a.node)
		h.Set("X-Version", a.version)
		h.Set("Connection", "close") // cada requisição abre conexão nova: o Service rebalanceia a cada uma
		next.ServeHTTP(w, r)
	})
}

func (a *app) info() map[string]any {
	return map[string]any{
		"version":     a.version,
		"pod":         a.pod,
		"node":        a.node,
		"ip":          a.podIP,
		"uptime_s":    round1(time.Since(a.started).Seconds()),
		"terminating": a.terminating.Load(),
	}
}

func (a *app) handleRoot(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path != "/" {
		http.NotFound(w, r)
		return
	}
	body := a.info()
	switch {
	case a.failing.Load():
		body["error"] = "pod em estado ruim (falha injetada com /admin/break)"
		writeJSON(w, http.StatusInternalServerError, body)
	case a.broken:
		body["error"] = "banco de dados indisponível"
		writeJSON(w, http.StatusServiceUnavailable, body)
	default:
		body["msg"] = "olá do pod " + a.pod
		writeJSON(w, http.StatusOK, body)
	}
}

// /healthz responde à pergunta da livenessProbe: "o processo está vivo e
// funcional, ou precisa ser reiniciado?"
func (a *app) handleHealthz(w http.ResponseWriter, _ *http.Request) {
	if a.failing.Load() {
		http.Error(w, "travado", http.StatusInternalServerError)
		return
	}
	_, _ = w.Write([]byte("ok\n"))
}

// /readyz responde à pergunta da readinessProbe: "posso receber tráfego agora?"
func (a *app) handleReadyz(w http.ResponseWriter, _ *http.Request) {
	reason := ""
	switch {
	case a.failing.Load():
		reason = "travado"
	case a.broken:
		reason = "dependência indisponível (banco de dados)"
	case a.terminating.Load():
		reason = "encerrando"
	case a.unready.Load():
		reason = "marcado como não pronto (/admin/unready)"
	}
	if reason != "" {
		http.Error(w, "não pronto: "+reason, http.StatusServiceUnavailable)
		return
	}
	_, _ = w.Write([]byte("pronto\n"))
}

func (a *app) handleBreak(w http.ResponseWriter, _ *http.Request) {
	a.failing.Store(true)
	log.Printf("FALHA INJETADA: /admin/break — liveness e readiness passam a falhar")
	writeJSON(w, http.StatusOK, map[string]any{"pod": a.pod, "node": a.node, "estado": "quebrado"})
}

func (a *app) handleUnready(w http.ResponseWriter, _ *http.Request) {
	a.unready.Store(true)
	log.Printf("FALHA INJETADA: /admin/unready — só a readiness passa a falhar")
	writeJSON(w, http.StatusOK, map[string]any{"pod": a.pod, "node": a.node, "estado": "não pronto"})
}

func (a *app) handleFix(w http.ResponseWriter, _ *http.Request) {
	a.failing.Store(false)
	a.unready.Store(false)
	log.Printf("falhas injetadas removidas (/admin/fix)")
	writeJSON(w, http.StatusOK, map[string]any{"pod": a.pod, "node": a.node, "estado": "normal"})
}

// /admin/crash simula uma queda abrupta do processo (sem graceful shutdown).
func (a *app) handleCrash(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{"pod": a.pod, "node": a.node, "estado": "caindo"})
	go func() {
		time.Sleep(100 * time.Millisecond)
		log.Printf("FALHA INJETADA: /admin/crash — processo encerrando abruptamente (código 2)")
		os.Exit(2)
	}()
}

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(v)
}

func env(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

func envDuration(k string, def time.Duration) time.Duration {
	v := os.Getenv(k)
	if v == "" {
		return def
	}
	if d, err := time.ParseDuration(v); err == nil {
		return d
	}
	if n, err := strconv.Atoi(v); err == nil {
		return time.Duration(n) * time.Second
	}
	log.Printf("valor inválido para %s=%q; usando %s", k, v, def)
	return def
}

func round1(f float64) float64 { return float64(int64(f*10)) / 10 }
