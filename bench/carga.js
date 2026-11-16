// Teste de carga com k6: mede vazão (requisições/s) e latência da aplicação.
// Rodado por scripts/carga.sh dentro de um contêiner na rede "kind".
//   VUS=20 DURACAO=60s scripts/carga.sh
import http from "k6/http";
import { check } from "k6";

export const options = {
  vus: parseInt(__ENV.VUS || "20"),
  duration: __ENV.DURACAO || "60s",
  // conexão nova por requisição, como a sonda: o Service rebalanceia a cada uma
  noConnectionReuse: true,
  summaryTrendStats: ["avg", "min", "med", "p(90)", "p(95)", "p(99)", "max"],
};

export default function () {
  const r = http.get(__ENV.ALVO || "http://k8slab-control-plane:30080/", { timeout: "2s" });
  check(r, { "status 200": (x) => x.status === 200 });
}
