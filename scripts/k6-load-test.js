/**
 * CloudCommerce Load Test — k6
 *
 * Simulates real shopping traffic against the Online Boutique:
 * homepage → product page → add to cart → view cart
 *
 * Runs with Prometheus remote write so metrics appear in Grafana:
 *
 *   K6_PROMETHEUS_RW_SERVER_URL=http://63.184.235.88:30090/api/v1/write \
 *   k6 run --out experimental-prometheus-rw scripts/k6-load-test.js
 *
 * Watch in Grafana:
 *   - Grafana dashboard 18030 (k6 Prometheus) — load test metrics
 *   - Kubernetes / Compute Resources / Namespace — CPU climbing
 *   - kubectl get hpa -n online-boutique -w   — replicas ticking up
 */

import http from 'k6/http';
import { check, sleep, group } from 'k6';
import { randomItem } from 'https://jslib.k6.io/k6-utils/1.2.0/index.js';

const BASE_URL = 'http://63.184.235.88';

// All product IDs from the Online Boutique product catalogue
const PRODUCTS = [
  'OLJCESPC7Z',  // Sunglasses
  '66VCHSJNUP',  // Tank Top
  '1YMWWN1N4O',  // Watch
  'L9ECAV7KIM',  // Loafers
  '2ZYFJ3GM2N',  // Hairdryer
  '0PUK6V6EKW',  // Candle Holder
  'LS4PSXUNUM',  // Salt & Pepper Shakers
  '9SIQT8TOJO',  // Bamboo Glass Jar
  '6E92ZMYYFZ',  // Mug
];

// Load test stages
// Watch these stages in Grafana + k9s simultaneously:
// Stage 1: Warm up — cluster adjusts, baseline CPU visible
// Stage 2: Ramp up — frontend CPU crosses 50% → HPA fires → replica 1→2
// Stage 3: Full load — sustained pressure → cartservice HPA may fire too
// Stage 4: Cooldown — load drops, HPA waits 60s stabilisation → scales down
export const options = {
  stages: [
    { duration: '30s', target: 5  },   // warm up — 5 virtual users
    { duration: '60s', target: 20 },   // ramp up — crosses HPA threshold
    { duration: '90s', target: 40 },   // full load — maximum pressure
    { duration: '30s', target: 20 },   // partial cooldown
    { duration: '60s', target: 0  },   // ramp down — watch scale-down
  ],

  // These thresholds mark the test as PASS or FAIL in k6 output
  thresholds: {
    http_req_failed:   ['rate<0.05'],    // less than 5% of requests fail
    http_req_duration: ['p(95)<3000'],   // 95% of requests complete under 3s
    'http_req_duration{group:::browse}': ['p(95)<2000'],  // browse under 2s
    'http_req_duration{group:::cart}':   ['p(95)<3000'],  // cart ops under 3s
  },
};

export default function () {

  // --- Browse flow ---
  // Hits: frontend, productcatalogservice, currencyservice, recommendationservice
  group('browse', function () {

    // Homepage — loads product list, currencies, recommendations
    let res = http.get(`${BASE_URL}/`);
    check(res, {
      'homepage status 200': (r) => r.status === 200,
      'homepage has products': (r) => r.body.includes('Hot Products'),
    });
    sleep(1);

    // Product detail page — loads image, description, recommendations
    const product = randomItem(PRODUCTS);
    res = http.get(`${BASE_URL}/product/${product}`);
    check(res, {
      'product page status 200': (r) => r.status === 200,
    });
    sleep(1);

  });

  // --- Cart flow ---
  // Hits: frontend, cartservice, Redis
  group('cart', function () {

    // Add a random product to cart
    const product = randomItem(PRODUCTS);
    let res = http.post(
      `${BASE_URL}/cart`,
      { product_id: product, quantity: '1' },
    );
    check(res, {
      'add to cart status 200': (r) => r.status === 200,
    });
    sleep(1);

    // View cart — reads from cartservice → Redis
    res = http.get(`${BASE_URL}/cart`);
    check(res, {
      'cart view status 200': (r) => r.status === 200,
    });
    sleep(1);

  });
}

// Summary printed at the end of the test
export function handleSummary(data) {
  console.log('\n=== CloudCommerce Load Test Summary ===');
  console.log(`Total requests:    ${data.metrics.http_reqs.values.count}`);
  console.log(`Failed requests:   ${(data.metrics.http_req_failed.values.rate * 100).toFixed(2)}%`);
  console.log(`Avg response time: ${data.metrics.http_req_duration.values.avg.toFixed(0)}ms`);
  console.log(`p95 response time: ${data.metrics.http_req_duration.values['p(95)'].toFixed(0)}ms`);
  console.log(`Peak RPS:          ${data.metrics.http_reqs.values.rate.toFixed(1)} req/s`);
  return {};
}
