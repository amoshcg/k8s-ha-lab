package main

// Monitor de nós: mostra no painel o estado de TODOS os nós do cluster, não só
// do nó de entrada. Cada nó é observado de dois jeitos:
//
//	visto de fora  — a sonda fala diretamente com o nó, sem passar pela API:
//	                 handshake TLS no kubelet (:10250) de todos os nós e, nos
//	                 control planes, GET /readyz?verbose no kube-apiserver
//	                 daquele nó (:6443), que inclui a saúde do etcd local;
//	segundo a API  — o que o cluster acha do nó (pelo HAProxy da API):
//	                 condição Ready, static pods do plano de controle
//	                 (etcd, apiserver, scheduler, controller-manager) e quem
//	                 detém as Leases de liderança.
//
// A diferença entre as duas visões é didática: um nó congelado some "de fora"
// em ~1 s, mas a API só o marca NotReady depois do node-monitor-grace-period.

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"sort"
	"strings"
	"sync"
	"time"
)

type nodeProbe struct {
	OK      bool
	Latency time.Duration
	Detail  string
	Checks  []string // /readyz: verificações que falharam
}

type nodeTick struct {
	T       time.Time
	Kubelet bool
	API     *bool // nil em workers
	Ready   string
}

type compStatus struct {
	Name     string `json:"name"`
	Ready    bool   `json:"ready"`
	Phase    string `json:"phase"`
	Restarts int    `json:"restarts"`
}

type apiNode struct {
	Ready         string // True / False / Unknown
	Reason        string
	Heartbeat     time.Time
	Transition    time.Time
	Roles         []string
	Version       string
	Unschedulable bool
}

type nodeState struct {
	name         string
	controlPlane bool
	kubelet      nodeProbe
	apiserver    nodeProbe
	etcd         nodeProbe
	history      []nodeTick
	lastKey      string
}

type nodeMonitor struct {
	p        *prober
	every    time.Duration
	kubeHTTP *http.Client // para os apiservers de cada nó
	lbURL    string
	auth     string

	mu      sync.Mutex
	nodes   map[string]*nodeState
	order   []string
	api     map[string]apiNode
	comps   map[string][]compStatus // nó → componentes
	leaders map[string]string       // componente → nó
	renewed map[string]time.Time    // componente → última renovação da Lease
	apiAt   time.Time               // última leitura bem-sucedida da API
	apiErr  string
}

func newNodeMonitor(p *prober, names []string, every time.Duration) (*nodeMonitor, error) {
	m := &nodeMonitor{p: p, every: every, nodes: map[string]*nodeState{}}
	for _, n := range names {
		m.ensure(n, strings.Contains(n, "control-plane"))
	}
	if p.cfg.apiURL != "" {
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
		m.kubeHTTP = &http.Client{
			Timeout: 1500 * time.Millisecond,
			Transport: &http.Transport{
				TLSClientConfig:   &tls.Config{RootCAs: pool, MinVersion: tls.VersionTLS12},
				DisableKeepAlives: true,
				Proxy:             nil,
			},
		}
		m.lbURL = strings.TrimRight(p.cfg.apiURL, "/")
		m.auth = "Bearer " + strings.TrimSpace(string(token))
	}
	return m, nil
}

func (m *nodeMonitor) ensure(name string, cp bool) *nodeState {
	n := m.nodes[name]
	if n == nil {
		n = &nodeState{name: name, controlPlane: cp}
		m.nodes[name] = n
		m.order = append(m.order, name)
		sort.Slice(m.order, func(i, j int) bool {
			a, b := m.nodes[m.order[i]], m.nodes[m.order[j]]
			if a.controlPlane != b.controlPlane {
				return a.controlPlane
			}
			return a.name < b.name
		})
	}
	if cp {
		n.controlPlane = true
	}
	return n
}

func (m *nodeMonitor) run(ctx context.Context) {
	t := time.NewTicker(m.every)
	defer t.Stop()
	for {
		m.cycle(ctx)
		select {
		case <-ctx.Done():
			return
		case <-t.C:
		}
	}
}

func (m *nodeMonitor) cycle(ctx context.Context) {
	m.mu.Lock()
	targets := make([]*nodeState, 0, len(m.order))
	for _, name := range m.order {
		targets = append(targets, m.nodes[name])
	}
	m.mu.Unlock()

	type result struct {
		n                  *nodeState
		kubelet, api, etcd nodeProbe
	}
	results := make([]result, len(targets))
	var wg sync.WaitGroup
	for i, n := range targets {
		wg.Add(1)
		go func(i int, n *nodeState) {
			defer wg.Done()
			r := result{n: n, kubelet: probeTLS(ctx, n.name, "10250")}
			if n.controlPlane {
				r.etcd = probeTLS(ctx, n.name, "2379")
			}
			if n.controlPlane && m.kubeHTTP != nil {
				r.api = m.probeAPIServer(ctx, n.name)
			}
			results[i] = r
		}(i, n)
	}
	wg.Add(1)
	go func() { defer wg.Done(); m.readAPI(ctx) }()
	wg.Wait()
	if ctx.Err() != nil {
		return
	}

	now := time.Now()
	var events []string
	m.mu.Lock()
	for _, r := range results {
		n := r.n
		n.kubelet = r.kubelet
		n.etcd = r.etcd
		tick := nodeTick{T: now, Kubelet: r.kubelet.OK, Ready: m.api[n.name].Ready}
		if n.controlPlane && m.kubeHTTP != nil {
			n.apiserver = r.api
			ok := r.api.OK
			tick.API = &ok
		}
		n.history = append(n.history, tick)
		cut := now.Add(-m.p.cfg.window)
		i := 0
		for i < len(n.history) && n.history[i].T.Before(cut) {
			i++
		}
		n.history = n.history[i:]

		key, desc := m.summarize(n)
		if n.lastKey != "" && key != n.lastKey {
			events = append(events, fmt.Sprintf("%s: %s", n.name, desc))
		}
		n.lastKey = key
	}
	m.mu.Unlock()
	for _, e := range events {
		fmt.Printf("%s%s ◆ [nó] %s%s\n", yellow, clock(now), e, reset)
	}
}

// summarize devolve uma chave estável do estado (para detectar mudanças) e uma
// descrição curta para o terminal. Chamada com m.mu travado.
func (m *nodeMonitor) summarize(n *nodeState) (string, string) {
	var parts []string
	if n.kubelet.OK {
		parts = append(parts, "kubelet responde")
	} else {
		parts = append(parts, "kubelet sem resposta")
	}
	if n.controlPlane && m.kubeHTTP != nil {
		switch {
		case n.apiserver.OK:
			parts = append(parts, "apiserver pronto")
		case len(n.apiserver.Checks) > 0:
			parts = append(parts, "apiserver com falha em "+strings.Join(n.apiserver.Checks, ","))
		default:
			parts = append(parts, "apiserver sem resposta")
		}
	}
	if r := m.api[n.name].Ready; r != "" {
		parts = append(parts, "Ready="+r)
	}
	s := strings.Join(parts, ", ")
	return s, s
}

// probeTLS verifica se o processo atrás de host:port está vivo tentando um
// handshake TLS. Só timeout e falha ao conectar contam como falha: um processo
// congelado (SIGSTOP, nó pausado) deixa o kernel aceitar a conexão TCP, mas
// nunca responde ao handshake; já um alerta TLS (o etcd exige certificado de
// cliente) prova que o processo está respondendo.
func probeTLS(ctx context.Context, host, port string) nodeProbe {
	start := time.Now()
	d := &tls.Dialer{
		NetDialer: &net.Dialer{Timeout: time.Second},
		// nenhum dado é enviado, então não validamos o certificado.
		Config: &tls.Config{InsecureSkipVerify: true}, //nolint:gosec
	}
	cctx, cancel := context.WithTimeout(ctx, time.Second)
	defer cancel()
	c, err := d.DialContext(cctx, "tcp", net.JoinHostPort(host, port))
	r := nodeProbe{Latency: time.Since(start)}
	if err != nil {
		var ne net.Error
		var op *net.OpError
		if (errors.As(err, &ne) && ne.Timeout()) || cctx.Err() != nil ||
			(errors.As(err, &op) && op.Op == "dial") {
			r.Detail = shortErr(err)
			return r
		}
	} else {
		_ = c.Close()
	}
	r.OK = true
	return r
}

func (m *nodeMonitor) probeAPIServer(ctx context.Context, host string) nodeProbe {
	start := time.Now()
	req, _ := http.NewRequestWithContext(ctx, http.MethodGet, "https://"+net.JoinHostPort(host, "6443")+"/readyz?verbose", nil)
	req.Header.Set("Authorization", m.auth)
	resp, err := m.kubeHTTP.Do(req)
	r := nodeProbe{Latency: time.Since(start)}
	if err != nil {
		r.Detail = shortErr(err)
		return r
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 64<<10))
	r.OK = resp.StatusCode == http.StatusOK
	for _, line := range strings.Split(string(body), "\n") {
		line = strings.TrimSpace(line)
		if strings.HasPrefix(line, "[-]") {
			name := strings.TrimPrefix(line, "[-]")
			if i := strings.IndexAny(name, " "); i >= 0 {
				name = name[:i]
			}
			r.Checks = append(r.Checks, name)
		}
	}
	if !r.OK {
		r.Detail = fmt.Sprintf("HTTP %d", resp.StatusCode)
		if len(r.Checks) > 0 {
			r.Detail += ": " + strings.Join(r.Checks, ", ")
		}
	}
	return r
}

// ---------------------------------------------------------------------------
// Leitura da API (pelo balanceador)

func (m *nodeMonitor) get(ctx context.Context, path string, out any) error {
	req, _ := http.NewRequestWithContext(ctx, http.MethodGet, m.lbURL+path, nil)
	req.Header.Set("Authorization", m.auth)
	req.Header.Set("Accept", "application/json")
	resp, err := m.kubeHTTP.Do(req)
	if err != nil {
		return fmt.Errorf("%s", shortErr(err))
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 4<<20))
	if resp.StatusCode == http.StatusForbidden {
		return errForbidden
	}
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("HTTP %d", resp.StatusCode)
	}
	return json.Unmarshal(body, out)
}

var errForbidden = fmt.Errorf("sem permissão (rode: make deploy)")

func (m *nodeMonitor) readAPI(ctx context.Context) {
	if m.kubeHTTP == nil {
		return
	}
	var nodes struct {
		Items []struct {
			Metadata struct {
				Name   string            `json:"name"`
				Labels map[string]string `json:"labels"`
			} `json:"metadata"`
			Spec struct {
				Unschedulable bool `json:"unschedulable"`
			} `json:"spec"`
			Status struct {
				Conditions []struct {
					Type               string    `json:"type"`
					Status             string    `json:"status"`
					Reason             string    `json:"reason"`
					LastHeartbeatTime  time.Time `json:"lastHeartbeatTime"`
					LastTransitionTime time.Time `json:"lastTransitionTime"`
				} `json:"conditions"`
				NodeInfo struct {
					KubeletVersion string `json:"kubeletVersion"`
				} `json:"nodeInfo"`
			} `json:"status"`
		} `json:"items"`
	}
	if err := m.get(ctx, "/api/v1/nodes", &nodes); err != nil {
		m.mu.Lock()
		m.apiErr = err.Error()
		m.mu.Unlock()
		return
	}

	var pods struct {
		Items []struct {
			Metadata struct {
				Labels map[string]string `json:"labels"`
			} `json:"metadata"`
			Spec struct {
				NodeName string `json:"nodeName"`
			} `json:"spec"`
			Status struct {
				Phase      string `json:"phase"`
				Conditions []struct {
					Type   string `json:"type"`
					Status string `json:"status"`
				} `json:"conditions"`
				ContainerStatuses []struct {
					RestartCount int `json:"restartCount"`
				} `json:"containerStatuses"`
			} `json:"status"`
		} `json:"items"`
	}
	podsErr := m.get(ctx, "/api/v1/namespaces/kube-system/pods?labelSelector=tier%3Dcontrol-plane", &pods)

	leaders := map[string]string{}
	renewed := map[string]time.Time{}
	for _, comp := range []string{"kube-scheduler", "kube-controller-manager"} {
		var lease struct {
			Spec struct {
				HolderIdentity string    `json:"holderIdentity"`
				RenewTime      time.Time `json:"renewTime"`
			} `json:"spec"`
		}
		if err := m.get(ctx, "/apis/coordination.k8s.io/v1/namespaces/kube-system/leases/"+comp, &lease); err == nil {
			h := lease.Spec.HolderIdentity
			if i := strings.Index(h, "_"); i >= 0 {
				h = h[:i]
			}
			leaders[comp] = h
			renewed[comp] = lease.Spec.RenewTime
		}
	}

	apiNodes := map[string]apiNode{}
	m.mu.Lock()
	defer m.mu.Unlock()
	for _, it := range nodes.Items {
		an := apiNode{Version: it.Status.NodeInfo.KubeletVersion, Unschedulable: it.Spec.Unschedulable, Ready: "Unknown"}
		for k := range it.Metadata.Labels {
			if strings.HasPrefix(k, "node-role.kubernetes.io/") {
				an.Roles = append(an.Roles, strings.TrimPrefix(k, "node-role.kubernetes.io/"))
			}
		}
		for _, c := range it.Status.Conditions {
			if c.Type == "Ready" {
				an.Ready, an.Reason, an.Heartbeat, an.Transition = c.Status, c.Reason, c.LastHeartbeatTime, c.LastTransitionTime
			}
		}
		apiNodes[it.Metadata.Name] = an
		cp := false
		for _, r := range an.Roles {
			cp = cp || r == "control-plane"
		}
		m.ensure(it.Metadata.Name, cp)
	}
	m.api = apiNodes
	m.leaders = leaders
	m.renewed = renewed
	if podsErr == nil {
		comps := map[string][]compStatus{}
		for _, it := range pods.Items {
			cs := compStatus{Name: it.Metadata.Labels["component"], Phase: it.Status.Phase}
			for _, c := range it.Status.Conditions {
				if c.Type == "Ready" {
					cs.Ready = c.Status == "True"
				}
			}
			for _, c := range it.Status.ContainerStatuses {
				cs.Restarts += c.RestartCount
			}
			comps[it.Spec.NodeName] = append(comps[it.Spec.NodeName], cs)
		}
		for _, list := range comps {
			sort.Slice(list, func(i, j int) bool { return compOrder(list[i].Name) < compOrder(list[j].Name) })
		}
		m.comps = comps
	}
	m.apiAt = time.Now()
	m.apiErr = ""
}

func compOrder(name string) int {
	switch name {
	case "etcd":
		return 0
	case "kube-apiserver":
		return 1
	case "kube-scheduler":
		return 2
	case "kube-controller-manager":
		return 3
	}
	return 9
}

// ---------------------------------------------------------------------------
// JSON do painel

type jsonProbe struct {
	OK     bool     `json:"ok"`
	Lat    float64  `json:"lat"`
	Detail string   `json:"detail,omitempty"`
	Checks []string `json:"checks,omitempty"`
}

type jsonTick struct {
	T       int64  `json:"t"`
	Kubelet bool   `json:"k"`
	API     *bool  `json:"a,omitempty"`
	Ready   string `json:"r,omitempty"`
}

type jsonNode struct {
	Name          string     `json:"name"`
	ControlPlane  bool       `json:"control_plane"`
	Entry         bool       `json:"entry"`
	Status        string     `json:"status"`
	Kubelet       jsonProbe  `json:"kubelet"`
	APIServer     *jsonProbe `json:"apiserver,omitempty"`
	Ready         string     `json:"ready,omitempty"`
	Reason        string     `json:"reason,omitempty"`
	Heartbeat     int64      `json:"heartbeat,omitempty"`
	Transition    int64      `json:"transition,omitempty"`
	Version       string     `json:"version,omitempty"`
	Unschedulable bool       `json:"unschedulable,omitempty"`
	Components    []jsonComp `json:"components,omitempty"`
	Leads         []string   `json:"leads,omitempty"`
	History       []jsonTick `json:"history"`
}

type jsonComp struct {
	Name     string `json:"name"`
	State    string `json:"state"` // ok, bad, unknown
	Detail   string `json:"detail,omitempty"`
	Restarts int    `json:"restarts,omitempty"`
}

type jsonNodes struct {
	APIAt  int64      `json:"api_at,omitempty"`
	APIErr string     `json:"api_err,omitempty"`
	Nodes  []jsonNode `json:"nodes"`
}

func (m *nodeMonitor) state() *jsonNodes {
	m.mu.Lock()
	defer m.mu.Unlock()
	out := &jsonNodes{APIErr: m.apiErr}
	if !m.apiAt.IsZero() {
		out.APIAt = m.apiAt.UnixMilli()
	}
	entry := hostOf(m.p.cfg.target)
	for _, name := range m.order {
		n := m.nodes[name]
		an := m.api[name]
		jn := jsonNode{
			Name: name, ControlPlane: n.controlPlane, Entry: name == entry,
			Kubelet: jsonProbe{OK: n.kubelet.OK, Lat: round2(ms(n.kubelet.Latency)), Detail: n.kubelet.Detail},
			Ready:   an.Ready, Reason: an.Reason, Version: an.Version, Unschedulable: an.Unschedulable,
		}
		if n.controlPlane {
			jn.Components = m.components(n)
		}
		if !an.Heartbeat.IsZero() {
			jn.Heartbeat = an.Heartbeat.UnixMilli()
		}
		if !an.Transition.IsZero() {
			jn.Transition = an.Transition.UnixMilli()
		}
		if n.controlPlane && m.kubeHTTP != nil {
			jn.APIServer = &jsonProbe{OK: n.apiserver.OK, Lat: round2(ms(n.apiserver.Latency)), Detail: n.apiserver.Detail, Checks: n.apiserver.Checks}
		}
		for _, comp := range []string{"kube-scheduler", "kube-controller-manager"} {
			if m.leaders[comp] == name {
				jn.Leads = append(jn.Leads, comp)
			}
		}
		for _, h := range n.history {
			jn.History = append(jn.History, jsonTick{T: h.T.UnixMilli(), Kubelet: h.Kubelet, API: h.API, Ready: h.Ready})
		}
		switch {
		case len(n.history) == 0:
			jn.Status = "unknown"
		case !n.kubelet.OK && (jn.APIServer == nil || !jn.APIServer.OK):
			jn.Status = "down"
		case !n.kubelet.OK || (jn.APIServer != nil && !jn.APIServer.OK) || (an.Ready != "" && an.Ready != "True") || anyBad(jn.Components):
			jn.Status = "degraded"
		default:
			jn.Status = "up"
		}
		out.Nodes = append(out.Nodes, jn)
	}
	return out
}

func hostOf(rawURL string) string {
	s := rawURL
	if i := strings.Index(s, "://"); i >= 0 {
		s = s[i+3:]
	}
	if i := strings.IndexAny(s, ":/"); i >= 0 {
		s = s[:i]
	}
	return s
}

func anyBad(cs []jsonComp) bool {
	for _, c := range cs {
		if c.State == "bad" {
			return true
		}
	}
	return false
}

// components combina o que a sonda vê diretamente com o que a API informa.
// A API sozinha não basta: com o nó congelado ou sem quórum no etcd, o status
// dos static pods fica parado no último valor (verde). Chamada com m.mu travado.
//
//	etcd           handshake TLS direto em :2379 + verificação "etcd" do /readyz
//	               do apiserver do mesmo nó (que só fala com o etcd local);
//	kube-apiserver GET /readyz direto em :6443;
//	scheduler e    escutam só em 127.0.0.1, então vêm da API: Ready do static
//	controller-mgr pod e, no líder, se a Lease continua sendo renovada.
func (m *nodeMonitor) components(n *nodeState) []jsonComp {
	now := time.Now()
	apiFresh := !m.apiAt.IsZero() && now.Sub(m.apiAt) < 3*time.Second
	pods := map[string]compStatus{}
	for _, c := range m.comps[n.name] {
		pods[c.Name] = c
	}
	names := []string{"etcd", "kube-apiserver", "kube-scheduler", "kube-controller-manager"}
	out := make([]jsonComp, 0, len(names))
	for _, name := range names {
		pod, hasPod := pods[name]
		c := jsonComp{Name: name, State: "ok", Restarts: pod.Restarts}
		podBad := func() {
			if apiFresh && hasPod && !pod.Ready {
				c.State, c.Detail = "bad", "static pod não está Ready ("+pod.Phase+")"
			}
		}
		switch {
		case len(n.history) == 0:
			c.State = "unknown"
		case !n.kubelet.OK:
			c.State, c.Detail = "bad", "nó sem resposta"
		case name == "etcd":
			switch {
			case !n.etcd.OK:
				c.State, c.Detail = "bad", "etcd :2379 "+n.etcd.Detail
			case contains(n.apiserver.Checks, "etcd"):
				c.State, c.Detail = "bad", "o apiserver deste nó não alcança o etcd"
			default:
				podBad()
			}
		case name == "kube-apiserver":
			switch {
			case m.kubeHTTP == nil:
				c.State = "unknown"
			case !n.apiserver.OK:
				c.State, c.Detail = "bad", "/readyz "+n.apiserver.Detail
			default:
				podBad()
			}
		default:
			switch {
			case !apiFresh:
				c.State, c.Detail = "unknown", "API sem resposta: estado desconhecido"
			case m.leaders[name] == n.name && now.Sub(m.renewed[name]) > 5*time.Second:
				c.State, c.Detail = "bad", fmt.Sprintf("líder não renova a Lease há %.0f s", now.Sub(m.renewed[name]).Seconds())
			default:
				podBad()
			}
		}
		if c.State == "ok" {
			c.Detail = "ok"
		}
		out = append(out, c)
	}
	return out
}

func contains(xs []string, x string) bool {
	for _, v := range xs {
		if v == x {
			return true
		}
	}
	return false
}
