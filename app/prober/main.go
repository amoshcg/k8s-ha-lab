// prober é a sonda externa do laboratório: mede, de fora do cluster, se o
// serviço está no ar.
//
// Ela roda duas "pistas" de medição em paralelo:
//
//	app  — GET na aplicação pelo NodePort (plano de dados), a cada -interval;
//	api  — PATCH num ConfigMap pela API do Kubernetes (plano de controle: toda
//	       escrita passa pelo consenso do etcd), a cada -api-interval. Opcional.
//
// Cada resultado vai para um CSV em -out, aparece no terminal e num painel web
// (-listen). Scripts de falha podem registrar "marcas" (GET /api/mark?label=...)
// para que o relatório saiba exatamente quando cada falha foi injetada.
package main

import (
	"bufio"
	"bytes"
	"context"
	"crypto/tls"
	"crypto/x509"
	_ "embed"
	"encoding/csv"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
	_ "time/tzdata" // permite usar TZ dentro de uma imagem "scratch"
)

//go:embed dashboard.html
var dashboardHTML []byte

type config struct {
	target   string
	interval time.Duration
	timeout  time.Duration

	apiURL       string
	apiTokenFile string
	apiCAFile    string
	apiNamespace string
	apiConfigMap string
	apiInterval  time.Duration
	apiTimeout   time.Duration

	listen   string
	outDir   string
	label    string
	recovery time.Duration
	window   time.Duration
	quiet    bool
	noColor  bool

	nodes         string
	nodesInterval time.Duration
}

func main() {
	var c config
	flag.StringVar(&c.target, "target", "http://k8slab-control-plane:30080/", "URL da aplicação")
	flag.DurationVar(&c.interval, "interval", 100*time.Millisecond, "intervalo entre requisições à aplicação")
	flag.DurationVar(&c.timeout, "timeout", time.Second, "timeout de cada requisição à aplicação")
	flag.StringVar(&c.apiURL, "api-url", "", "URL do kube-apiserver (vazio desliga a pista 'api')")
	flag.StringVar(&c.apiTokenFile, "api-token-file", "", "arquivo com o token da ServiceAccount")
	flag.StringVar(&c.apiCAFile, "api-ca-file", "", "arquivo com a CA do cluster")
	flag.StringVar(&c.apiNamespace, "api-namespace", "demo", "namespace do ConfigMap de batimento")
	flag.StringVar(&c.apiConfigMap, "api-configmap", "api-heartbeat", "nome do ConfigMap de batimento")
	flag.DurationVar(&c.apiInterval, "api-interval", 500*time.Millisecond, "intervalo entre escritas na API")
	flag.DurationVar(&c.apiTimeout, "api-timeout", 2*time.Second, "timeout de cada escrita na API")
	flag.StringVar(&c.listen, "listen", ":8090", "endereço do painel web (vazio desliga)")
	flag.StringVar(&c.outDir, "out", "/results", "diretório dos CSVs (vazio desliga)")
	flag.StringVar(&c.label, "label", "sonda", "prefixo dos arquivos de resultado")
	flag.DurationVar(&c.recovery, "recovery", 2*time.Second, "tempo contínuo sem falhas para considerar um incidente encerrado")
	flag.DurationVar(&c.window, "window", 60*time.Second, "janela de histórico mostrada no painel")
	flag.BoolVar(&c.quiet, "quiet", false, "não imprime a linha por segundo")
	flag.BoolVar(&c.noColor, "no-color", false, "desliga cores no terminal")
	flag.StringVar(&c.nodes, "nodes", "", "nós do cluster separados por vírgula (os demais são descobertos pela API); vazio e sem -api-url desliga o painel de nós")
	flag.DurationVar(&c.nodesInterval, "nodes-interval", time.Second, "intervalo de verificação dos nós")
	flag.Parse()

	log.SetFlags(0)
	if c.noColor || !isTerminal() {
		colorsOff()
	}

	p := newProber(c)
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	if err := p.openOutput(); err != nil {
		log.Fatalf("não foi possível criar o CSV: %v", err)
	}

	appLane := p.addLane("app", "Aplicação (plano de dados)", c.target)
	go p.run(ctx, appLane, c.interval, p.appCheck())

	if c.apiURL != "" {
		check, err := p.apiCheck()
		if err != nil {
			log.Fatalf("pista 'api': %v", err)
		}
		apiLane := p.addLane("api", "API do Kubernetes (plano de controle)", c.apiURL)
		go p.run(ctx, apiLane, c.apiInterval, check)
	}

	if c.nodes != "" || c.apiURL != "" {
		var names []string
		for _, n := range strings.Split(c.nodes, ",") {
			if n = strings.TrimSpace(n); n != "" {
				names = append(names, n)
			}
		}
		nm, err := newNodeMonitor(p, names, c.nodesInterval)
		if err != nil {
			log.Fatalf("monitor de nós: %v", err)
		}
		p.nodes = nm
		go nm.run(ctx)
	}

	if c.listen != "" {
		go p.serve(c.listen)
	}
	go p.flusher(ctx)
	if !c.quiet {
		go p.ticker(ctx)
	}

	fmt.Printf("%sSonda iniciada%s  alvo=%s  intervalo=%s", bold, reset, c.target, c.interval)
	if c.apiURL != "" {
		fmt.Printf("  api=%s", c.apiURL)
	}
	fmt.Println()
	if c.listen != "" {
		fmt.Printf("Painel: http://localhost%s   (Ctrl+C encerra e imprime o resumo)\n", portOf(c.listen))
	}
	if p.csvPath != "" {
		fmt.Printf("CSV:    %s\n", p.csvPath)
	}
	fmt.Println()

	<-ctx.Done()
	time.Sleep(50 * time.Millisecond)
	p.finish()
}

// ---------------------------------------------------------------------------
// Modelo

type sample struct {
	T       time.Time
	Lane    string
	OK      bool
	Code    int
	Latency time.Duration
	Version string
	Pod     string
	Node    string
	Detail  string
}

type incident struct {
	Start time.Time
	End   time.Time // zero enquanto aberto
	Fails int
	Total int
}

func (i *incident) duration(now time.Time) time.Duration {
	if i.End.IsZero() {
		return now.Sub(i.Start)
	}
	return i.End.Sub(i.Start)
}

type mark struct {
	T     time.Time
	Label string
}

type lane struct {
	name, title, target string

	mu        sync.Mutex
	recent    []sample
	total     int
	ok        int
	latencies []float64   // ms, apenas respostas ok
	incidents []*incident // calculados ao vivo (ordem de chegada das respostas)
	history   []sample    // todas as amostras, para o cálculo exato do resumo
	cur       *incident
	okSince   time.Time // primeira resposta ok depois da última falha

	// contadores do segundo corrente (linha do terminal)
	secTotal, secOK int
	secVersions     map[string]int
	secPods         map[string]bool
	secErr          string
}

type prober struct {
	cfg     config
	started time.Time

	mu    sync.Mutex
	lanes []*lane
	marks []mark

	csvMu   sync.Mutex
	csvFile *os.File
	csvW    *csv.Writer
	csvPath string

	nodes *nodeMonitor
}

func newProber(c config) *prober { return &prober{cfg: c, started: time.Now()} }

func (p *prober) addLane(name, title, target string) *lane {
	l := &lane{name: name, title: title, target: target, secVersions: map[string]int{}, secPods: map[string]bool{}}
	p.mu.Lock()
	p.lanes = append(p.lanes, l)
	p.mu.Unlock()
	return l
}

type checkFunc func(ctx context.Context) sample

// run dispara uma verificação a cada intervalo, sem esperar a anterior
// terminar: um timeout não reduz a taxa de amostragem.
func (p *prober) run(ctx context.Context, l *lane, every time.Duration, check checkFunc) {
	t := time.NewTicker(every)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			go func() {
				s := check(ctx)
				if ctx.Err() != nil {
					return
				}
				s.Lane = l.name
				p.record(l, s)
			}()
		}
	}
}

func (p *prober) record(l *lane, s sample) {
	l.mu.Lock()
	l.total++
	l.secTotal++
	if s.Version != "" {
		l.secVersions[s.Version]++
	}
	if s.Pod != "" {
		l.secPods[s.Pod] = true
	}
	if s.OK {
		l.ok++
		l.secOK++
		l.latencies = append(l.latencies, ms(s.Latency))
	} else if l.secErr == "" {
		l.secErr = s.Detail
	}
	l.recent = append(l.recent, s)
	l.history = append(l.history, s)
	cut := time.Now().Add(-p.cfg.window)
	i := 0
	for i < len(l.recent) && l.recent[i].T.Before(cut) {
		i++
	}
	l.recent = l.recent[i:]

	var opened, closed *incident
	if !s.OK {
		l.okSince = time.Time{}
		if l.cur == nil {
			l.cur = &incident{Start: s.T}
			l.incidents = append(l.incidents, l.cur)
			opened = l.cur
		}
		l.cur.Fails++
		l.cur.Total++
	} else if l.cur != nil {
		l.cur.Total++
		if l.okSince.IsZero() || s.T.Before(l.okSince) {
			l.okSince = s.T
		}
		if s.T.Sub(l.okSince) >= p.cfg.recovery {
			l.cur.End = l.okSince
			closed = l.cur
			l.cur = nil
			l.okSince = time.Time{}
		}
	}
	l.mu.Unlock()

	if opened != nil {
		fmt.Printf("%s%s ▼ [%s] FALHAS COMEÇARAM: %s%s\n", red, clock(s.T), l.name, s.Detail, reset)
	}
	if closed != nil {
		fmt.Printf("%s%s ▲ [%s] RECUPERADO: sem falhas desde %s; incidente de %.2f s (%d falhas em %d requisições)%s\n",
			green, clock(time.Now()), l.name, clock(closed.End), closed.duration(time.Now()).Seconds(), closed.Fails, closed.Total, reset)
	}
	p.writeCSV(s)
}

func (p *prober) addMark(label string) mark {
	m := mark{T: time.Now(), Label: label}
	p.mu.Lock()
	p.marks = append(p.marks, m)
	p.mu.Unlock()
	fmt.Printf("%s%s ⚑ MARCA: %s%s\n", cyan, clock(m.T), label, reset)
	p.writeCSV(sample{T: m.T, Lane: "mark", OK: true, Detail: label})
	return m
}

// ---------------------------------------------------------------------------
// Verificações

type appResponse struct {
	Version string `json:"version"`
	Pod     string `json:"pod"`
	Node    string `json:"node"`
	Error   string `json:"error"`
}

func (p *prober) appCheck() checkFunc {
	client := &http.Client{
		Timeout: p.cfg.timeout,
		// sem keep-alive: cada requisição é uma conexão nova, então o Service
		// (kube-proxy) escolhe um pod a cada vez e vemos o balanceamento real.
		Transport: &http.Transport{DisableKeepAlives: true, Proxy: nil},
	}
	return func(ctx context.Context) sample {
		start := time.Now()
		s := sample{T: start}
		req, _ := http.NewRequestWithContext(ctx, http.MethodGet, p.cfg.target, nil)
		resp, err := client.Do(req)
		s.Latency = time.Since(start)
		if err != nil {
			s.Detail = shortErr(err)
			return s
		}
		defer resp.Body.Close()
		body, _ := io.ReadAll(io.LimitReader(resp.Body, 64<<10))
		s.Code = resp.StatusCode
		var r appResponse
		_ = json.Unmarshal(body, &r)
		s.Version, s.Pod, s.Node = r.Version, r.Pod, r.Node
		if s.Version == "" {
			s.Version = resp.Header.Get("X-Version")
			s.Pod = resp.Header.Get("X-Pod")
			s.Node = resp.Header.Get("X-Node")
		}
		s.OK = resp.StatusCode == http.StatusOK
		if !s.OK {
			s.Detail = fmt.Sprintf("HTTP %d", resp.StatusCode)
			if r.Error != "" {
				s.Detail += ": " + r.Error
			}
		}
		return s
	}
}

func (p *prober) apiCheck() (checkFunc, error) {
	token, err := os.ReadFile(p.cfg.apiTokenFile)
	if err != nil {
		return nil, fmt.Errorf("lendo token: %w", err)
	}
	caPEM, err := os.ReadFile(p.cfg.apiCAFile)
	if err != nil {
		return nil, fmt.Errorf("lendo CA: %w", err)
	}
	pool := x509.NewCertPool()
	if !pool.AppendCertsFromPEM(caPEM) {
		return nil, fmt.Errorf("CA inválida em %s", p.cfg.apiCAFile)
	}
	client := &http.Client{
		Timeout: p.cfg.apiTimeout,
		Transport: &http.Transport{
			TLSClientConfig:   &tls.Config{RootCAs: pool, MinVersion: tls.VersionTLS12},
			DisableKeepAlives: true,
			Proxy:             nil,
		},
	}
	url := fmt.Sprintf("%s/api/v1/namespaces/%s/configmaps/%s",
		strings.TrimRight(p.cfg.apiURL, "/"), p.cfg.apiNamespace, p.cfg.apiConfigMap)
	auth := "Bearer " + strings.TrimSpace(string(token))

	return func(ctx context.Context) sample {
		start := time.Now()
		s := sample{T: start}
		body := fmt.Sprintf(`{"data":{"ts":%q}}`, start.UTC().Format(time.RFC3339Nano))
		req, _ := http.NewRequestWithContext(ctx, http.MethodPatch, url, bytes.NewBufferString(body))
		req.Header.Set("Authorization", auth)
		req.Header.Set("Content-Type", "application/merge-patch+json")
		resp, err := client.Do(req)
		s.Latency = time.Since(start)
		if err != nil {
			s.Detail = shortErr(err)
			return s
		}
		defer resp.Body.Close()
		raw, _ := io.ReadAll(io.LimitReader(resp.Body, 64<<10))
		s.Code = resp.StatusCode
		s.OK = resp.StatusCode == http.StatusOK
		if !s.OK {
			var st struct {
				Message string `json:"message"`
			}
			_ = json.Unmarshal(raw, &st)
			s.Detail = fmt.Sprintf("HTTP %d %s", resp.StatusCode, st.Message)
		}
		return s
	}, nil
}

func shortErr(err error) string {
	e := err.Error()
	switch {
	case strings.Contains(e, "Client.Timeout") || strings.Contains(e, "deadline exceeded"):
		return "timeout"
	case strings.Contains(e, "connection refused"):
		return "conexão recusada"
	case strings.Contains(e, "connection reset"):
		return "conexão reiniciada (reset)"
	case strings.Contains(e, "no such host"):
		return "host não encontrado"
	case strings.Contains(e, "EOF"):
		return "conexão encerrada sem resposta (EOF)"
	}
	if i := strings.LastIndex(e, ": "); i >= 0 && i+2 < len(e) {
		return e[i+2:]
	}
	return e
}

// ---------------------------------------------------------------------------
// Saída no terminal

func (p *prober) ticker(ctx context.Context) {
	t := time.NewTicker(time.Second)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case now := <-t.C:
			p.mu.Lock()
			lanes := append([]*lane(nil), p.lanes...)
			p.mu.Unlock()
			var parts []string
			for _, l := range lanes {
				parts = append(parts, l.secondLine())
			}
			fmt.Printf("%s%s%s │ %s\n", dim, clock(now), reset, strings.Join(parts, " │ "))
		}
	}
}

func (l *lane) secondLine() string {
	l.mu.Lock()
	defer l.mu.Unlock()
	total, ok := l.secTotal, l.secOK
	vers := make([]string, 0, len(l.secVersions))
	for v, n := range l.secVersions {
		vers = append(vers, fmt.Sprintf("%s:%d", v, n))
	}
	sort.Strings(vers)
	pods := len(l.secPods)
	errMsg := l.secErr
	l.secTotal, l.secOK, l.secErr = 0, 0, ""
	l.secVersions = map[string]int{}
	l.secPods = map[string]bool{}

	col, sym := green, "✔"
	switch {
	case total == 0:
		col, sym = dim, "·"
	case ok == 0:
		col, sym = red, "✘"
	case ok < total:
		col, sym = yellow, "!"
	}
	s := fmt.Sprintf("%s%s %s %2d/%-2d%s", col, l.name, sym, ok, total, reset)
	if l.name == "app" && len(vers) > 0 {
		s += fmt.Sprintf(" %s %d pods", strings.Join(vers, " "), pods)
	}
	if ok < total && errMsg != "" {
		s += fmt.Sprintf(" %s(%s)%s", col, errMsg, reset)
	}
	return s
}

// ---------------------------------------------------------------------------
// CSV

func (p *prober) openOutput() error {
	if p.cfg.outDir == "" {
		return nil
	}
	if err := os.MkdirAll(p.cfg.outDir, 0o755); err != nil {
		return err
	}
	name := fmt.Sprintf("%s_%s.csv", p.cfg.label, p.started.Format("20060102-150405"))
	p.csvPath = filepath.Join(p.cfg.outDir, name)
	f, err := os.Create(p.csvPath)
	if err != nil {
		return err
	}
	p.csvFile = f
	p.csvW = csv.NewWriter(bufio.NewWriter(f))
	_ = p.csvW.Write([]string{"ts_ms", "ts", "lane", "ok", "code", "latency_ms", "version", "pod", "node", "detail"})
	return nil
}

func (p *prober) writeCSV(s sample) {
	if p.csvW == nil {
		return
	}
	p.csvMu.Lock()
	defer p.csvMu.Unlock()
	_ = p.csvW.Write([]string{
		strconv.FormatInt(s.T.UnixMilli(), 10),
		s.T.Format("2006-01-02T15:04:05.000Z07:00"),
		s.Lane,
		strconv.FormatBool(s.OK),
		strconv.Itoa(s.Code),
		strconv.FormatFloat(ms(s.Latency), 'f', 2, 64),
		s.Version, s.Pod, s.Node, s.Detail,
	})
}

func (p *prober) flusher(ctx context.Context) {
	t := time.NewTicker(time.Second)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			p.flush()
		}
	}
}

func (p *prober) flush() {
	if p.csvW == nil {
		return
	}
	p.csvMu.Lock()
	defer p.csvMu.Unlock()
	p.csvW.Flush()
}

// ---------------------------------------------------------------------------
// Resumo final

func (p *prober) finish() {
	p.flush()
	summary := p.summary()
	fmt.Println()
	fmt.Println(summary)
	if p.csvPath != "" {
		path := strings.TrimSuffix(p.csvPath, ".csv") + "_resumo.txt"
		if err := os.WriteFile(path, []byte(summary+"\n"), 0o644); err == nil {
			fmt.Printf("Resumo salvo em %s\n", path)
		}
		_ = p.csvFile.Close()
	}
}

func (p *prober) summary() string {
	var b strings.Builder
	now := time.Now()
	fmt.Fprintf(&b, "══ Resumo da sonda ══ início %s, duração %s\n", p.started.Format("2006-01-02 15:04:05"), now.Sub(p.started).Round(time.Second))
	p.mu.Lock()
	lanes := append([]*lane(nil), p.lanes...)
	marks := append([]mark(nil), p.marks...)
	p.mu.Unlock()

	// No resumo, os incidentes são recalculados com as amostras ordenadas pelo
	// instante de envio (ao vivo, a ordem é a de chegada das respostas).
	incs := map[string][]*incident{}
	for _, l := range lanes {
		l.mu.Lock()
		incs[l.name] = computeIncidents(l.history, p.cfg.recovery)
		l.mu.Unlock()
	}

	for _, l := range lanes {
		l.mu.Lock()
		fmt.Fprintf(&b, "\n[%s] %s — alvo %s\n", l.name, l.title, l.target)
		avail := 0.0
		if l.total > 0 {
			avail = 100 * float64(l.ok) / float64(l.total)
		}
		fmt.Fprintf(&b, "  requisições: %d   ok: %d   falhas: %d   disponibilidade: %.3f%%\n", l.total, l.ok, l.total-l.ok, avail)
		if len(l.latencies) > 0 {
			q := quantiles(l.latencies, 0.5, 0.95, 0.99, 1)
			fmt.Fprintf(&b, "  latência das respostas ok (ms): p50 %.1f   p95 %.1f   p99 %.1f   máx %.1f\n", q[0], q[1], q[2], q[3])
		}
		fmt.Fprintf(&b, "  incidentes (encerrados após %s sem falhas): %d\n", p.cfg.recovery, len(incs[l.name]))
		for i, inc := range incs[l.name] {
			end := "em aberto"
			if !inc.End.IsZero() {
				end = clock(inc.End)
			}
			fmt.Fprintf(&b, "   %2d) %s → %s  duração %.2f s  falhas %d de %d requisições\n",
				i+1, clock(inc.Start), end, inc.duration(now).Seconds(), inc.Fails, inc.Total)
		}
		l.mu.Unlock()
	}

	if len(marks) > 0 {
		fmt.Fprintf(&b, "\nMarcas (falhas injetadas) e efeito observado:\n")
		for i, m := range marks {
			limit := now
			if i+1 < len(marks) {
				limit = marks[i+1].T
			}
			fmt.Fprintf(&b, "  %s  %s\n", clock(m.T), m.Label)
			for _, l := range lanes {
				l.mu.Lock()
				// incidente que começa depois da marca (antes da próxima) ou que
				// já estava em andamento quando a marca foi registrada
				var hit *incident
				ongoing := false
				for _, inc := range incs[l.name] {
					if inc.Start.Before(m.T) && (inc.End.IsZero() || inc.End.After(m.T)) {
						hit, ongoing = inc, true
						break
					}
					if !inc.Start.Before(m.T) && inc.Start.Before(limit) {
						hit = inc
						break
					}
				}
				if hit == nil {
					fmt.Fprintf(&b, "      [%s] nenhuma falha até a próxima marca\n", l.name)
				} else {
					rec := "ainda sem recuperação"
					if !hit.End.IsZero() {
						rec = fmt.Sprintf("recuperado em +%.2f s (incidente de %.2f s, %d falhas)", hit.End.Sub(m.T).Seconds(), hit.duration(now).Seconds(), hit.Fails)
					}
					if ongoing {
						fmt.Fprintf(&b, "      [%s] já havia falhas em andamento (desde %s); %s\n", l.name, clock(hit.Start), rec)
					} else {
						fmt.Fprintf(&b, "      [%s] primeira falha em +%.2f s; %s\n", l.name, hit.Start.Sub(m.T).Seconds(), rec)
					}
				}
				l.mu.Unlock()
			}
		}
	}
	return strings.TrimRight(b.String(), "\n")
}

func computeIncidents(samples []sample, recovery time.Duration) []*incident {
	ss := append([]sample(nil), samples...)
	sort.SliceStable(ss, func(i, j int) bool { return ss[i].T.Before(ss[j].T) })
	var out []*incident
	var cur *incident
	var okSince time.Time
	for _, s := range ss {
		if !s.OK {
			okSince = time.Time{}
			if cur == nil {
				cur = &incident{Start: s.T}
				out = append(out, cur)
			}
			cur.Fails++
			cur.Total++
			continue
		}
		if cur == nil {
			continue
		}
		cur.Total++
		if okSince.IsZero() {
			okSince = s.T
		}
		if s.T.Sub(okSince) >= recovery {
			cur.End = okSince
			cur, okSince = nil, time.Time{}
		}
	}
	return out
}

// ---------------------------------------------------------------------------
// Painel web

type jsonSample struct {
	T    int64   `json:"t"`
	OK   bool    `json:"ok"`
	Code int     `json:"code"`
	Lat  float64 `json:"lat"`
	V    string  `json:"v,omitempty"`
	Pod  string  `json:"pod,omitempty"`
	Node string  `json:"node,omitempty"`
	Err  string  `json:"err,omitempty"`
}

type jsonIncident struct {
	Start int64   `json:"start"`
	End   int64   `json:"end,omitempty"`
	Dur   float64 `json:"dur"`
	Fails int     `json:"fails"`
	Total int     `json:"total"`
	Open  bool    `json:"open"`
}

type jsonPod struct {
	Pod     string `json:"pod"`
	Node    string `json:"node"`
	Version string `json:"version"`
	Count   int    `json:"count"`
	Errors  int    `json:"errors"`
}

type jsonLane struct {
	Name         string         `json:"name"`
	Title        string         `json:"title"`
	Target       string         `json:"target"`
	Status       string         `json:"status"`
	Total        int            `json:"total"`
	OK           int            `json:"ok"`
	Availability float64        `json:"availability"`
	P50          float64        `json:"p50"`
	P95          float64        `json:"p95"`
	P99          float64        `json:"p99"`
	Recent       []jsonSample   `json:"recent"`
	Pods         []jsonPod      `json:"pods"`
	Incidents    []jsonIncident `json:"incidents"`
}

type jsonMark struct {
	T     int64  `json:"t"`
	Label string `json:"label"`
}

type jsonState struct {
	Now     int64      `json:"now"`
	Started int64      `json:"started"`
	Window  int64      `json:"window_ms"`
	Lanes   []jsonLane `json:"lanes"`
	Marks   []jsonMark `json:"marks"`
	Nodes   *jsonNodes `json:"nodes,omitempty"`
}

func (p *prober) state() jsonState {
	now := time.Now()
	st := jsonState{Now: now.UnixMilli(), Started: p.started.UnixMilli(), Window: p.cfg.window.Milliseconds()}
	p.mu.Lock()
	lanes := append([]*lane(nil), p.lanes...)
	for _, m := range p.marks {
		if now.Sub(m.T) <= p.cfg.window {
			st.Marks = append(st.Marks, jsonMark{T: m.T.UnixMilli(), Label: m.Label})
		}
	}
	p.mu.Unlock()

	for _, l := range lanes {
		l.mu.Lock()
		jl := jsonLane{Name: l.name, Title: l.title, Target: l.target, Total: l.total, OK: l.ok}
		if l.total > 0 {
			jl.Availability = 100 * float64(l.ok) / float64(l.total)
		}
		// percentis das últimas respostas ok da janela
		var lats []float64
		pods := map[string]*jsonPod{}
		okRecent, totRecent := 0, 0
		for _, s := range l.recent {
			jl.Recent = append(jl.Recent, jsonSample{T: s.T.UnixMilli(), OK: s.OK, Code: s.Code, Lat: round2(ms(s.Latency)), V: s.Version, Pod: s.Pod, Node: s.Node, Err: s.Detail})
			if s.OK {
				lats = append(lats, ms(s.Latency))
			}
			if now.Sub(s.T) <= 2*time.Second {
				totRecent++
				if s.OK {
					okRecent++
				}
			}
			if s.Pod != "" && now.Sub(s.T) <= 5*time.Second {
				jp := pods[s.Pod]
				if jp == nil {
					jp = &jsonPod{Pod: s.Pod, Node: s.Node, Version: s.Version}
					pods[s.Pod] = jp
				}
				jp.Count++
				if !s.OK {
					jp.Errors++
				}
			}
		}
		if len(lats) > 0 {
			q := quantiles(lats, 0.5, 0.95, 0.99)
			jl.P50, jl.P95, jl.P99 = round2(q[0]), round2(q[1]), round2(q[2])
		}
		switch {
		case totRecent == 0:
			jl.Status = "unknown"
		case okRecent == totRecent:
			jl.Status = "up"
		case okRecent == 0:
			jl.Status = "down"
		default:
			jl.Status = "degraded"
		}
		for _, jp := range pods {
			jl.Pods = append(jl.Pods, *jp)
		}
		sort.Slice(jl.Pods, func(i, j int) bool { return jl.Pods[i].Pod < jl.Pods[j].Pod })
		start := 0
		if len(l.incidents) > 8 {
			start = len(l.incidents) - 8
		}
		for _, inc := range l.incidents[start:] {
			ji := jsonIncident{Start: inc.Start.UnixMilli(), Dur: round2(inc.duration(now).Seconds()), Fails: inc.Fails, Total: inc.Total, Open: inc.End.IsZero()}
			if !ji.Open {
				ji.End = inc.End.UnixMilli()
			}
			jl.Incidents = append(jl.Incidents, ji)
		}
		l.mu.Unlock()
		st.Lanes = append(st.Lanes, jl)
	}
	if p.nodes != nil {
		st.Nodes = p.nodes.state()
	}
	return st
}

func (p *prober) serve(addr string) {
	mux := http.NewServeMux()
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/" {
			http.NotFound(w, r)
			return
		}
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		_, _ = w.Write(dashboardHTML)
	})
	mux.HandleFunc("/api/state", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Cache-Control", "no-store")
		_ = json.NewEncoder(w).Encode(p.state())
	})
	mux.HandleFunc("/api/mark", func(w http.ResponseWriter, r *http.Request) {
		_ = r.ParseForm()
		label := strings.TrimSpace(r.Form.Get("label"))
		if label == "" {
			http.Error(w, "informe ?label=...", http.StatusBadRequest)
			return
		}
		m := p.addMark(label)
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(jsonMark{T: m.T.UnixMilli(), Label: m.Label})
	})
	mux.HandleFunc("/api/summary", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		_, _ = io.WriteString(w, p.summary()+"\n")
	})
	if err := http.ListenAndServe(addr, mux); err != nil {
		log.Printf("painel web desligado: %v", err)
	}
}

// ---------------------------------------------------------------------------
// Utilidades

func quantiles(xs []float64, qs ...float64) []float64 {
	s := append([]float64(nil), xs...)
	sort.Float64s(s)
	out := make([]float64, len(qs))
	for i, q := range qs {
		idx := int(q*float64(len(s)-1) + 0.5)
		if idx >= len(s) {
			idx = len(s) - 1
		}
		out[i] = s[idx]
	}
	return out
}

func ms(d time.Duration) float64 { return float64(d.Microseconds()) / 1000 }
func round2(f float64) float64   { return float64(int64(f*100+0.5)) / 100 }
func clock(t time.Time) string   { return t.Format("15:04:05.000") }
func portOf(listen string) string {
	if i := strings.LastIndex(listen, ":"); i >= 0 {
		return listen[i:]
	}
	return listen
}

func isTerminal() bool {
	fi, err := os.Stdout.Stat()
	return err == nil && fi.Mode()&os.ModeCharDevice != 0
}

var (
	reset  = "\033[0m"
	bold   = "\033[1m"
	dim    = "\033[2m"
	red    = "\033[31m"
	green  = "\033[32m"
	yellow = "\033[33m"
	cyan   = "\033[36m"
)

func colorsOff() { reset, bold, dim, red, green, yellow, cyan = "", "", "", "", "", "", "" }
