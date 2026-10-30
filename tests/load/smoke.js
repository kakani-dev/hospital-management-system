// #79: k6 smoke against the live edge. Light on purpose (2 VUs, 30 s, ~1 req/s each): health is not
// rate-limited, and the few unauthenticated calls stay far under the 300/min per-IP limit.
// Uses no credentials and creates no data.
import http from 'k6/http';
import { check, sleep } from 'k6';

const EDGE = __ENV.EDGE_URL || 'https://ca-hms-edge.whiteisland-88abe7bd.centralindia.azurecontainerapps.io';

export const options = {
  vus: 2,
  duration: '30s',
  thresholds: {
    checks: ['rate>0.99'],
    'http_req_duration{kind:health}': ['p(95)<800'],
  },
};

export default function () {
  const live = http.get(`${EDGE}/health/live`, { tags: { kind: 'health' } });
  check(live, { 'health/live is 200': (r) => r.status === 200 });
  if (__ITER % 10 === 0) {
    const anon = http.get(`${EDGE}/api/v1/inventory/pharmacy/queue`, { tags: { kind: 'auth' } });
    check(anon, { 'protected API without sign-in is 401': (r) => r.status === 401 });
  }
  sleep(1);
}
